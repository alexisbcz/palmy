/*
 * palm-browser-cef: the Blink engine host.
 *
 * Runs Chromium through CEF's off-screen ("windowless") rendering and speaks
 * the engine protocol (../proto.h) to the browser chrome over a Unix socket.
 * CEF paints each view into a CPU buffer with dirty rectangles; this process
 * copies the dirty rectangles into a shared-memory buffer the chrome maps,
 * and turns the chrome's input messages into CEF's mouse and key events.
 *
 * It never opens a window and needs no display server: `--ozone-platform=
 * headless` keeps Chromium off X11 and Wayland entirely, which is also why the
 * chrome can take real screenshots with no compositor running.
 *
 * Threads. CEF's browser-process message loop runs on the main thread
 * (cef_run_message_loop). A second thread only reads the socket and posts
 * each message to CEF's UI thread as a task, so every View is touched from
 * the UI thread alone. Writes to the socket come from the UI thread too,
 * but take a mutex anyway, because CEF calls a few handlers (downloads among
 * them) from wherever it likes.
 *
 * Reference counting. The C API hands a callee one reference to every object
 * passed in, and the callee releases it -- `rel()` below. The handler structs
 * this file implements live as long as the process, so their counts are not
 * tracked; tasks and the per-callback objects that do come and go count for
 * real.
 *
 * Process model. This binary is also its own subprocess: Chromium re-executes
 * it with `--type=renderer`, `--type=gpu-process` and so on, and
 * cef_execute_process() at the top of main() runs those and returns their
 * exit code. The sandbox is Chromium's: the zygote, user namespaces where the
 * kernel allows unprivileged ones, the setuid chrome-sandbox helper otherwise.
 * PALM_BROWSER_NO_SANDBOX=1 turns it off, and the host says so in its log.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_download_item_capi.h"
#include "include/capi/cef_find_handler_capi.h"
#include "include/capi/cef_image_capi.h"
#include "include/capi/cef_jsdialog_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_menu_model_capi.h"
#include "include/capi/cef_preference_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_render_handler_capi.h"
#include "include/capi/cef_render_process_handler_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/cef_task_capi.h"
#include "include/capi/cef_v8_capi.h"
#include "include/capi/cef_values_capi.h"
#include "include/cef_api_hash.h"
#include "include/cef_version.h"

#include "../proto.h"

#define MAX_VIEWS 256
#define MAX_DAMAGE 16
#define MAX_PENDING 64

/* ------------------------------------------------------------------------
 * small things
 * ---------------------------------------------------------------------- */

static int g_verbose;

static void logf_(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char* fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "palm-browser-cef: ");
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}
#define VLOG(...) do { if (g_verbose) logf_(__VA_ARGS__); } while (0)

#define rel(o) do { if (o) (o)->base.release(&(o)->base); } while (0)

/* Handlers that live for the whole process: no counting. */
static void CEF_CALLBACK st_add_ref(cef_base_ref_counted_t* b) { (void)b; }
static int CEF_CALLBACK st_release(cef_base_ref_counted_t* b) { (void)b; return 0; }
static int CEF_CALLBACK st_one(cef_base_ref_counted_t* b) { (void)b; return 1; }
static void init_static(cef_base_ref_counted_t* b, size_t size) {
	b->size = size;
	b->add_ref = st_add_ref;
	b->release = st_release;
	b->has_one_ref = st_one;
	b->has_at_least_one_ref = st_one;
}

/* cef_string_t (UTF-16) <-> UTF-8 */
static char* str8(const cef_string_t* s) {
	if (!s || !s->str) return strdup("");
	cef_string_utf8_t out = {0};
	cef_string_utf16_to_utf8(s->str, s->length, &out);
	char* r = strndup(out.str ? out.str : "", out.length);
	cef_string_utf8_clear(&out);
	return r;
}
static char* ustr8(cef_string_userfree_t s) {
	char* r = str8(s);
	if (s) cef_string_userfree_free(s);
	return r;
}
static void set16(cef_string_t* dst, const char* s) {
	cef_string_utf8_to_utf16(s, strlen(s), dst);
}

/* Secrets (a filled or submitted password) are zeroed before their memory
 * goes back to the allocator. Best effort: V8's heap and Chromium's IPC
 * buffers keep their own copies, which this process cannot reach. */
static void free_secret(char* s) {
	if (s) explicit_bzero(s, strlen(s));
	free(s);
}
static void clear_secret16(cef_string_t* s) {
	if (s && s->str) explicit_bzero(s->str, s->length * sizeof(s->str[0]));
	cef_string_clear(s);
}
static char* ustr8_secret(cef_string_userfree_t s) {
	char* r = str8(s);
	if (s) {
		if (s->str) explicit_bzero(s->str, s->length * sizeof(s->str[0]));
		cef_string_userfree_free(s);
	}
	return r;
}

/* The origin of an http(s) URL as a page's location.origin spells it:
 * scheme://host[:port], without a default port. "" for anything else --
 * autofill exists only for http and https pages. Chromium hands over
 * canonical URLs (lowercase scheme and host), so this is a cut, not a parse. */
static char* origin_of(const char* url) {
	const char* rest = NULL;
	int https = 0;
	if (strncmp(url, "https://", 8) == 0) {
		rest = url + 8;
		https = 1;
	} else if (strncmp(url, "http://", 7) == 0) {
		rest = url + 7;
	}
	if (!rest || !rest[0]) return strdup("");
	size_t n = strcspn(rest, "/?#");
	if (memchr(rest, '@', n)) return strdup(""); /* credentials in the URL: never */
	char host[512];
	if (n == 0 || n >= sizeof host) return strdup("");
	memcpy(host, rest, n);
	host[n] = 0;
	size_t hl = strlen(host);
	if (https && hl > 4 && strcmp(host + hl - 4, ":443") == 0) host[hl - 4] = 0;
	if (!https && hl > 3 && strcmp(host + hl - 3, ":80") == 0) host[hl - 3] = 0;
	char out[600];
	snprintf(out, sizeof out, "%s://%s", https ? "https" : "http", host);
	return strdup(out);
}

/* The page half of autofill, the same file the Gecko host loads. */
static const char AUTOFILL_JS[] = {
#embed "../autofill.js"
	, 0
};

/* ------------------------------------------------------------------------
 * the socket
 * ---------------------------------------------------------------------- */

static int g_sock = -1;
static pthread_mutex_t g_wlock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
	uint8_t* b;
	size_t n, cap;
} Buf;

static void buf_need(Buf* m, size_t more) {
	if (m->n + more <= m->cap) return;
	size_t c = m->cap ? m->cap * 2 : 256;
	while (c < m->n + more) c *= 2;
	/* grow by copy, zeroing the old block: a message may carry a password */
	uint8_t* nb = malloc(c);
	if (m->n) memcpy(nb, m->b, m->n);
	if (m->b) {
		explicit_bzero(m->b, m->cap);
		free(m->b);
	}
	m->b = nb;
	m->cap = c;
}
static void put(Buf* m, const void* p, size_t n) { buf_need(m, n); memcpy(m->b + m->n, p, n); m->n += n; }
static void put_u8(Buf* m, uint8_t v) { put(m, &v, 1); }
static void put_u32(Buf* m, uint32_t v) { put(m, &v, 4); }
static void put_i32(Buf* m, int32_t v) { put(m, &v, 4); }
static void put_i64(Buf* m, int64_t v) { put(m, &v, 8); }
static void put_f32(Buf* m, float v) { put(m, &v, 4); }
static void put_str(Buf* m, const char* s) {
	uint32_t n = s ? (uint32_t)strlen(s) : 0;
	put_u32(m, n);
	if (n) put(m, s, n);
}
static void put_bytes(Buf* m, const void* p, uint32_t n) { put_u32(m, n); if (n) put(m, p, n); }

static Buf msg_begin(uint16_t op, uint16_t view) {
	Buf m = {0};
	uint32_t z = 0;
	put_u32(&m, z);
	put(&m, &op, 2);
	put(&m, &view, 2);
	return m;
}

static int write_all(int fd, const uint8_t* p, size_t n) {
	while (n) {
		ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
		if (w < 0) {
			if (errno == EINTR) continue;
			return -1;
		}
		p += w;
		n -= (size_t)w;
	}
	return 0;
}

static void msg_send_fd(Buf* m, int fd) {
	uint32_t size = (uint32_t)m->n;
	memcpy(m->b, &size, 4);
	pthread_mutex_lock(&g_wlock);
	if (g_sock >= 0) {
		if (fd >= 0) {
			struct iovec iov = {.iov_base = m->b, .iov_len = m->n};
			char ctl[CMSG_SPACE(sizeof(int))];
			memset(ctl, 0, sizeof ctl);
			struct msghdr mh = {0};
			mh.msg_iov = &iov;
			mh.msg_iovlen = 1;
			mh.msg_control = ctl;
			mh.msg_controllen = sizeof ctl;
			struct cmsghdr* c = CMSG_FIRSTHDR(&mh);
			c->cmsg_level = SOL_SOCKET;
			c->cmsg_type = SCM_RIGHTS;
			c->cmsg_len = CMSG_LEN(sizeof(int));
			memcpy(CMSG_DATA(c), &fd, sizeof(int));
			ssize_t w;
			do { w = sendmsg(g_sock, &mh, MSG_NOSIGNAL); } while (w < 0 && errno == EINTR);
			if (w >= 0 && (size_t)w < m->n) write_all(g_sock, m->b + w, m->n - (size_t)w);
		} else {
			write_all(g_sock, m->b, m->n);
		}
	}
	pthread_mutex_unlock(&g_wlock);
	free(m->b);
	m->b = NULL;
}
static void msg_send(Buf* m) { msg_send_fd(m, -1); }
/* a message carrying a password: its buffer is zeroed, not just freed (it
 * was built by appending, so the copies left by realloc are zeroed too: see
 * buf_need) */
static void msg_send_secret(Buf* m) {
	uint32_t size = (uint32_t)m->n;
	memcpy(m->b, &size, 4);
	pthread_mutex_lock(&g_wlock);
	if (g_sock >= 0) write_all(g_sock, m->b, m->n);
	pthread_mutex_unlock(&g_wlock);
	explicit_bzero(m->b, m->cap);
	free(m->b);
	m->b = NULL;
}

static void send_str(uint16_t op, int view, const char* s) {
	Buf m = msg_begin(op, (uint16_t)view);
	put_str(&m, s);
	msg_send(&m);
}

/* reading: a cursor over one received message */
typedef struct {
	const uint8_t* p;
	size_t n, at;
	int bad;
} Rd;
static int rd_take(Rd* r, void* out, size_t n) {
	if (r->at + n > r->n) { r->bad = 1; memset(out, 0, n); return 0; }
	memcpy(out, r->p + r->at, n);
	r->at += n;
	return 1;
}
static uint8_t rd_u8(Rd* r) { uint8_t v; rd_take(r, &v, 1); return v; }
static uint32_t rd_u32(Rd* r) { uint32_t v; rd_take(r, &v, 4); return v; }
static int32_t rd_i32(Rd* r) { int32_t v; rd_take(r, &v, 4); return v; }
static float rd_f32(Rd* r) { float v; rd_take(r, &v, 4); return v; }
static char* rd_str(Rd* r) {
	uint32_t n = rd_u32(r);
	if (r->bad || r->at + n > r->n) { r->bad = 1; return strdup(""); }
	char* s = strndup((const char*)r->p + r->at, n);
	r->at += n;
	return s;
}

/* ------------------------------------------------------------------------
 * views
 * ---------------------------------------------------------------------- */

typedef struct View View;

typedef struct {
	cef_client_t client;
	View* v;
} Client;
typedef struct { cef_render_handler_t h; View* v; } Render;
typedef struct { cef_display_handler_t h; View* v; } Display;
typedef struct { cef_load_handler_t h; View* v; } Load;
typedef struct { cef_life_span_handler_t h; View* v; } Life;
typedef struct { cef_jsdialog_handler_t h; View* v; } JsDialog;
typedef struct { cef_download_handler_t h; View* v; } Download;
typedef struct { cef_context_menu_handler_t h; View* v; } Menu;
typedef struct { cef_request_handler_t h; View* v; } Request;
typedef struct { cef_find_handler_t h; View* v; } Find;

struct View {
	int id;
	int alive;
	cef_browser_t* browser; /* one reference, held from after_created to before_close */

	int w, h;     /* logical */
	float scale;
	float zoom; /* the page zoom factor, 1 = 100%: CSS pixels times this are view pixels */
	int visible;
	int focused;

	/* what CEF painted, in device pixels */
	uint32_t* backing;
	int bw, bh;

	/* the <select> dropdown and friends: painted separately, composited here */
	int popup_shown;
	cef_rect_t popup_rect; /* logical */
	uint32_t* popup;
	int pw, ph;

	/* the buffer the chrome maps */
	int shm_fd;
	uint32_t* shm;
	int sw, sh;

	cef_rect_t damage[MAX_DAMAGE];
	int ndamage;
	int inflight;

	char* pending_url;

	Client client;
	Render render;
	Display display;
	Load load;
	Life life;
	JsDialog jsdialog;
	Download download;
	Menu menu;
	Request request;
	Find find;
};

static View* g_views[MAX_VIEWS];
static int g_dark = -1; /* -1: follow whatever the system says */
static int g_open_browsers;
static int g_quitting;
static char* g_profile;
static char* g_downloads;

static View* view_get(int id) {
	if (id <= 0 || id >= MAX_VIEWS) return NULL;
	return g_views[id];
}

static cef_browser_host_t* host_of(View* v) {
	if (!v || !v->browser) return NULL;
	return v->browser->get_host(v->browser);
}

/* damage bookkeeping: a short list, collapsed to its bounds when it fills */
static void rect_union(cef_rect_t* a, const cef_rect_t* b) {
	int x0 = a->x < b->x ? a->x : b->x;
	int y0 = a->y < b->y ? a->y : b->y;
	int x1 = (a->x + a->width) > (b->x + b->width) ? (a->x + a->width) : (b->x + b->width);
	int y1 = (a->y + a->height) > (b->y + b->height) ? (a->y + a->height) : (b->y + b->height);
	a->x = x0; a->y = y0; a->width = x1 - x0; a->height = y1 - y0;
}
static int rect_clip(cef_rect_t* r, int w, int h) {
	int x0 = r->x < 0 ? 0 : r->x, y0 = r->y < 0 ? 0 : r->y;
	int x1 = r->x + r->width, y1 = r->y + r->height;
	if (x1 > w) x1 = w;
	if (y1 > h) y1 = h;
	if (x1 <= x0 || y1 <= y0) return 0;
	r->x = x0; r->y = y0; r->width = x1 - x0; r->height = y1 - y0;
	return 1;
}
static void damage_add(View* v, cef_rect_t r) {
	if (!rect_clip(&r, v->bw, v->bh)) return;
	for (int i = 0; i < v->ndamage; i++) {
		cef_rect_t d = v->damage[i];
		if (r.x >= d.x && r.y >= d.y && r.x + r.width <= d.x + d.width && r.y + r.height <= d.y + d.height) return;
	}
	if (v->ndamage == MAX_DAMAGE) {
		for (int i = 1; i < v->ndamage; i++) rect_union(&v->damage[0], &v->damage[i]);
		rect_union(&v->damage[0], &r);
		v->ndamage = 1;
		return;
	}
	v->damage[v->ndamage++] = r;
}

static cef_rect_t popup_device_rect(View* v) {
	cef_rect_t r = {
		(int)(v->popup_rect.x * v->scale), (int)(v->popup_rect.y * v->scale),
		v->pw, v->ph,
	};
	return r;
}

static int shm_ensure(View* v) {
	if (v->shm && v->sw == v->bw && v->sh == v->bh) return 1;
	if (v->shm) munmap(v->shm, (size_t)v->sw * v->sh * 4);
	if (v->shm_fd >= 0) close(v->shm_fd);
	v->shm = NULL;
	v->shm_fd = -1;
	size_t size = (size_t)v->bw * v->bh * 4;
	if (!size) return 0;
	int fd = memfd_create("palm-browser-view", MFD_CLOEXEC);
	if (fd < 0 || ftruncate(fd, (off_t)size) < 0) {
		logf_("memfd: %s", strerror(errno));
		if (fd >= 0) close(fd);
		return 0;
	}
	void* p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		close(fd);
		return 0;
	}
	v->shm = p;
	v->shm_fd = fd;
	v->sw = v->bw;
	v->sh = v->bh;
	memcpy(v->shm, v->backing, size);
	Buf m = msg_begin(PB_BUFFER, (uint16_t)v->id);
	put_i32(&m, v->sw);
	put_i32(&m, v->sh);
	put_i32(&m, v->sw * 4);
	msg_send_fd(&m, fd);
	/* the whole buffer is new to the chrome */
	v->ndamage = 0;
	cef_rect_t all = {0, 0, v->bw, v->bh};
	damage_add(v, all);
	return 1;
}

static void flush(View* v) {
	if (!v || v->inflight || !v->ndamage || !v->backing) return;
	if (!shm_ensure(v)) return;
	cef_rect_t pr = popup_device_rect(v);
	int popup = v->popup_shown && v->popup && rect_clip(&pr, v->bw, v->bh);
	for (int i = 0; i < v->ndamage; i++) {
		cef_rect_t r = v->damage[i];
		for (int y = r.y; y < r.y + r.height; y++) {
			memcpy(v->shm + (size_t)y * v->sw + r.x, v->backing + (size_t)y * v->bw + r.x, (size_t)r.width * 4);
		}
	}
	if (popup) {
		int ox = (int)(v->popup_rect.x * v->scale), oy = (int)(v->popup_rect.y * v->scale);
		for (int y = pr.y; y < pr.y + pr.height; y++) {
			int sy = y - oy;
			if (sy < 0 || sy >= v->ph) continue;
			int sx = pr.x - ox;
			memcpy(v->shm + (size_t)y * v->sw + pr.x, v->popup + (size_t)sy * v->pw + sx, (size_t)pr.width * 4);
		}
		damage_add(v, pr);
	}
	Buf m = msg_begin(PB_FRAME, (uint16_t)v->id);
	put_u32(&m, (uint32_t)v->ndamage);
	for (int i = 0; i < v->ndamage; i++) {
		put_i32(&m, v->damage[i].x);
		put_i32(&m, v->damage[i].y);
		put_i32(&m, v->damage[i].width);
		put_i32(&m, v->damage[i].height);
	}
	msg_send(&m);
	v->ndamage = 0;
	v->inflight = 1;
}

/* ------------------------------------------------------------------------
 * keys: X keysyms (what palmy reports) to Windows virtual-key codes (what
 * Blink's key events carry)
 * ---------------------------------------------------------------------- */

static int vk_of(uint32_t sym) {
	if (sym >= 'a' && sym <= 'z') return (int)(sym - 'a' + 'A');
	if (sym >= 'A' && sym <= 'Z') return (int)sym;
	if (sym >= '0' && sym <= '9') return (int)sym;
	if (sym >= 0xffbe && sym <= 0xffd5) return 0x70 + (int)(sym - 0xffbe); /* F1..F24 */
	if (sym >= 0xffb0 && sym <= 0xffb9) return 0x60 + (int)(sym - 0xffb0); /* keypad digits */
	switch (sym) {
	case 0xff08: return 0x08; /* BackSpace */
	case 0xff09: case 0xfe20: return 0x09; /* Tab, ISO_Left_Tab */
	case 0xff0d: case 0xff8d: return 0x0d; /* Return, KP_Enter */
	case 0xff1b: return 0x1b; /* Escape */
	case 0x20: return 0x20;
	case 0xff55: return 0x21; /* Prior */
	case 0xff56: return 0x22; /* Next */
	case 0xff57: return 0x23; /* End */
	case 0xff50: return 0x24; /* Home */
	case 0xff51: return 0x25; /* Left */
	case 0xff52: return 0x26; /* Up */
	case 0xff53: return 0x27; /* Right */
	case 0xff54: return 0x28; /* Down */
	case 0xff63: return 0x2d; /* Insert */
	case 0xffff: return 0x2e; /* Delete */
	case 0xffe1: case 0xffe2: return 0x10; /* Shift */
	case 0xffe3: case 0xffe4: return 0x11; /* Control */
	case 0xffe9: case 0xffea: return 0x12; /* Alt */
	case 0xffeb: case 0xffec: return 0x5b; /* Super */
	case 0xff67: return 0x5d; /* Menu */
	case 0xffaa: return 0x6a; case 0xffab: return 0x6b; case 0xffad: return 0x6d;
	case 0xffae: return 0x6e; case 0xffaf: return 0x6f;
	case ';': case ':': return 0xba;
	case '=': case '+': return 0xbb;
	case ',': case '<': return 0xbc;
	case '-': case '_': return 0xbd;
	case '.': case '>': return 0xbe;
	case '/': case '?': return 0xbf;
	case '`': case '~': return 0xc0;
	case '[': case '{': return 0xdb;
	case '\\': case '|': return 0xdc;
	case ']': case '}': return 0xdd;
	case '\'': case '"': return 0xde;
	}
	return 0;
}

static uint32_t cef_mods(uint32_t m) {
	uint32_t f = 0;
	if (m & PB_MOD_SHIFT) f |= EVENTFLAG_SHIFT_DOWN;
	if (m & PB_MOD_CTRL) f |= EVENTFLAG_CONTROL_DOWN;
	if (m & PB_MOD_ALT) f |= EVENTFLAG_ALT_DOWN;
	if (m & PB_MOD_SUPER) f |= EVENTFLAG_COMMAND_DOWN;
	return f;
}

/* ------------------------------------------------------------------------
 * render handler
 * ---------------------------------------------------------------------- */

#define VIEW_OF(T, self) (((T*)(self))->v)

static void CEF_CALLBACK rh_get_view_rect(cef_render_handler_t* self, cef_browser_t* b, cef_rect_t* r) {
	View* v = VIEW_OF(Render, self);
	r->x = 0;
	r->y = 0;
	r->width = v->w > 0 ? v->w : 1;
	r->height = v->h > 0 ? v->h : 1;
	rel(b);
}
static int CEF_CALLBACK rh_get_screen_info(cef_render_handler_t* self, cef_browser_t* b, cef_screen_info_t* si) {
	View* v = VIEW_OF(Render, self);
	si->device_scale_factor = v->scale;
	si->depth = 24;
	si->depth_per_component = 8;
	si->rect.width = si->available_rect.width = v->w;
	si->rect.height = si->available_rect.height = v->h;
	rel(b);
	return 1;
}
static int CEF_CALLBACK rh_get_screen_point(cef_render_handler_t* self, cef_browser_t* b, int x, int y, int* sx, int* sy) {
	(void)self;
	*sx = x;
	*sy = y;
	rel(b);
	return 1;
}
static void CEF_CALLBACK rh_on_popup_show(cef_render_handler_t* self, cef_browser_t* b, int show) {
	View* v = VIEW_OF(Render, self);
	if (!show && v->popup_shown) {
		cef_rect_t pr = popup_device_rect(v);
		damage_add(v, pr); /* uncover what was beneath */
		free(v->popup);
		v->popup = NULL;
		v->pw = v->ph = 0;
	}
	v->popup_shown = show;
	flush(v);
	rel(b);
}
static void CEF_CALLBACK rh_on_popup_size(cef_render_handler_t* self, cef_browser_t* b, const cef_rect_t* r) {
	View* v = VIEW_OF(Render, self);
	if (v->popup_shown) damage_add(v, popup_device_rect(v));
	v->popup_rect = *r;
	rel(b);
}
static void CEF_CALLBACK rh_on_paint(cef_render_handler_t* self, cef_browser_t* b, cef_paint_element_type_t type,
                                     size_t nrects, cef_rect_t const* rects, const void* buffer, int width, int height) {
	View* v = VIEW_OF(Render, self);
	const uint32_t* src = buffer;
	if (type == PET_VIEW) {
		if (v->bw != width || v->bh != height) {
			free(v->backing);
			v->backing = calloc((size_t)width * height, 4);
			v->bw = width;
			v->bh = height;
			v->ndamage = 0;
			memcpy(v->backing, src, (size_t)width * height * 4);
			cef_rect_t all = {0, 0, width, height};
			damage_add(v, all);
		} else {
			for (size_t i = 0; i < nrects; i++) {
				cef_rect_t r = rects[i];
				if (!rect_clip(&r, width, height)) continue;
				for (int y = r.y; y < r.y + r.height; y++)
					memcpy(v->backing + (size_t)y * width + r.x, src + (size_t)y * width + r.x, (size_t)r.width * 4);
				damage_add(v, r);
			}
		}
	} else if (type == PET_POPUP) {
		if (v->pw != width || v->ph != height) {
			free(v->popup);
			v->popup = malloc((size_t)width * height * 4);
			v->pw = width;
			v->ph = height;
		}
		memcpy(v->popup, src, (size_t)width * height * 4);
		damage_add(v, popup_device_rect(v));
	}
	flush(v);
	rel(b);
}
static void CEF_CALLBACK rh_on_text_selection_changed(cef_render_handler_t* self, cef_browser_t* b,
                                                      const cef_string_t* text, const cef_range_t* range) {
	(void)range;
	View* v = VIEW_OF(Render, self);
	char* s = str8(text);
	send_str(PB_SELECTION, v->id, s);
	free(s);
	rel(b);
}

/* ------------------------------------------------------------------------
 * display handler
 * ---------------------------------------------------------------------- */

static void CEF_CALLBACK dh_on_address_change(cef_display_handler_t* self, cef_browser_t* b, cef_frame_t* f, const cef_string_t* url) {
	View* v = VIEW_OF(Display, self);
	if (f->is_main(f)) {
		char* s = str8(url);
		send_str(PB_URL, v->id, s);
		free(s);
	}
	rel(f);
	rel(b);
}
static void CEF_CALLBACK dh_on_title_change(cef_display_handler_t* self, cef_browser_t* b, const cef_string_t* t) {
	View* v = VIEW_OF(Display, self);
	char* s = str8(t);
	send_str(PB_TITLE, v->id, s);
	free(s);
	rel(b);
}

typedef struct {
	cef_download_image_callback_t cb;
	atomic_int refs;
	int view;
	char* url;
} FavCb;
static void CEF_CALLBACK fav_add_ref(cef_base_ref_counted_t* b) { atomic_fetch_add(&((FavCb*)b)->refs, 1); }
static int CEF_CALLBACK fav_release(cef_base_ref_counted_t* b) {
	FavCb* c = (FavCb*)b;
	if (atomic_fetch_sub(&c->refs, 1) == 1) {
		free(c->url);
		free(c);
		return 1;
	}
	return 0;
}
static int CEF_CALLBACK fav_has_one(cef_base_ref_counted_t* b) { return atomic_load(&((FavCb*)b)->refs) == 1; }
static int CEF_CALLBACK fav_has_any(cef_base_ref_counted_t* b) { return atomic_load(&((FavCb*)b)->refs) >= 1; }
static void CEF_CALLBACK fav_done(cef_download_image_callback_t* self, const cef_string_t* url, int status, cef_image_t* img) {
	(void)url;
	(void)status;
	FavCb* c = (FavCb*)self;
	Buf m = msg_begin(PB_FAVICON, (uint16_t)c->view);
	put_str(&m, c->url);
	cef_binary_value_t* png = NULL;
	if (img && !img->is_empty(img)) {
		int pw = 0, ph = 0;
		png = img->get_as_png(img, 1.0f, 1, &pw, &ph);
	}
	if (png) {
		size_t n = png->get_size(png);
		void* data = malloc(n);
		png->get_data(png, data, n, 0);
		put_bytes(&m, data, (uint32_t)n);
		free(data);
		rel(png);
	} else {
		put_u32(&m, 0);
	}
	msg_send(&m);
	rel(img);
}

static void CEF_CALLBACK dh_on_favicon_urlchange(cef_display_handler_t* self, cef_browser_t* b, cef_string_list_t urls) {
	View* v = VIEW_OF(Display, self);
	if (cef_string_list_size(urls) > 0) {
		cef_string_t u = {0};
		cef_string_list_value(urls, 0, &u);
		FavCb* c = calloc(1, sizeof *c);
		c->cb.base.size = sizeof(cef_download_image_callback_t);
		c->cb.base.add_ref = fav_add_ref;
		c->cb.base.release = fav_release;
		c->cb.base.has_one_ref = fav_has_one;
		c->cb.base.has_at_least_one_ref = fav_has_any;
		c->cb.on_download_image_finished = fav_done;
		atomic_store(&c->refs, 1);
		c->view = v->id;
		c->url = str8(&u);
		cef_browser_host_t* h = b->get_host(b);
		/* the host takes our one reference */
		h->download_image(h, &u, 1, 32, 0, &c->cb);
		rel(h);
		cef_string_clear(&u);
	}
	rel(b);
}
static void CEF_CALLBACK dh_on_status_message(cef_display_handler_t* self, cef_browser_t* b, const cef_string_t* s) {
	View* v = VIEW_OF(Display, self);
	char* t = str8(s);
	send_str(PB_STATUS, v->id, t);
	free(t);
	rel(b);
}
static void CEF_CALLBACK dh_on_loading_progress_change(cef_display_handler_t* self, cef_browser_t* b, double p) {
	View* v = VIEW_OF(Display, self);
	Buf m = msg_begin(PB_PROGRESS, (uint16_t)v->id);
	put_f32(&m, (float)p);
	msg_send(&m);
	rel(b);
}
static int CEF_CALLBACK dh_on_cursor_change(cef_display_handler_t* self, cef_browser_t* b, cef_cursor_handle_t h,
                                            cef_cursor_type_t type, const cef_cursor_info_t* info) {
	(void)h;
	(void)info;
	View* v = VIEW_OF(Display, self);
	uint8_t c = PB_CURSOR_DEFAULT;
	switch (type) {
	case CT_HAND: c = PB_CURSOR_POINTER; break;
	case CT_IBEAM: c = PB_CURSOR_TEXT; break;
	case CT_WAIT: case CT_PROGRESS: c = PB_CURSOR_WAIT; break;
	case CT_CROSS: c = PB_CURSOR_CROSSHAIR; break;
	case CT_MOVE: c = PB_CURSOR_MOVE; break;
	case CT_NOTALLOWED: c = PB_CURSOR_NOT_ALLOWED; break;
	case CT_GRAB: case CT_GRABBING: c = PB_CURSOR_GRAB; break;
	case CT_EASTWESTRESIZE: case CT_COLUMNRESIZE: c = PB_CURSOR_EW_RESIZE; break;
	case CT_NORTHSOUTHRESIZE: case CT_ROWRESIZE: c = PB_CURSOR_NS_RESIZE; break;
	case CT_NONE: c = PB_CURSOR_NONE; break;
	default: break;
	}
	Buf m = msg_begin(PB_CURSOR, (uint16_t)v->id);
	put_u8(&m, c);
	msg_send(&m);
	rel(b);
	return 1;
}
static int CEF_CALLBACK dh_on_console_message(cef_display_handler_t* self, cef_browser_t* b, cef_log_severity_t lvl,
                                             const cef_string_t* msg, const cef_string_t* src, int line) {
	(void)self;
	(void)lvl;
	(void)src;
	(void)line;
	if (g_verbose) {
		char* s = str8(msg);
		logf_("console: %s", s);
		free(s);
	}
	rel(b);
	return 1; /* do not also print it to the host's stderr */
}

/* ------------------------------------------------------------------------
 * load, life span, requests
 * ---------------------------------------------------------------------- */

static void CEF_CALLBACK lh_on_loading_state_change(cef_load_handler_t* self, cef_browser_t* b, int loading, int back, int fwd) {
	View* v = VIEW_OF(Load, self);
	Buf m = msg_begin(PB_LOAD, (uint16_t)v->id);
	put_u8(&m, (uint8_t)loading);
	put_u8(&m, (uint8_t)back);
	put_u8(&m, (uint8_t)fwd);
	msg_send(&m);
	rel(b);
}
/* Blink creates a document's script context lazily, when the page first
 * runs script, and a login page with no script of its own never gets one --
 * so never gets autofill.js. Running an empty statement in the top-level
 * frame as it starts loading creates the context; OnContextCreated installs
 * autofill.js there, which also looks at the field already focused (an
 * autofocus that happened first). */
static void CEF_CALLBACK lh_on_load_start(cef_load_handler_t* self, cef_browser_t* b, cef_frame_t* f, cef_transition_type_t t) {
	(void)self; (void)t;
	if (f->is_main(f)) {
		cef_string_t code = {0}, url = {0};
		set16(&code, "void 0");
		set16(&url, "palm-autofill:");
		f->execute_java_script(f, &code, &url, 0);
		cef_string_clear(&code);
		cef_string_clear(&url);
	}
	rel(f);
	rel(b);
}
static void CEF_CALLBACK lh_on_load_end(cef_load_handler_t* self, cef_browser_t* b, cef_frame_t* f, int status) {
	(void)status;
	lh_on_load_start(self, b, f, 0);
}
static void CEF_CALLBACK lh_on_load_error(cef_load_handler_t* self, cef_browser_t* b, cef_frame_t* f, cef_errorcode_t code,
                                          const cef_string_t* text, const cef_string_t* url) {
	View* v = VIEW_OF(Load, self);
	if (f->is_main(f) && code != ERR_ABORTED) {
		char* t = str8(text);
		char* u = str8(url);
		Buf m = msg_begin(PB_LOAD_ERROR, (uint16_t)v->id);
		put_i32(&m, (int32_t)code);
		put_str(&m, t);
		put_str(&m, u);
		msg_send(&m);
		free(t);
		free(u);
	}
	rel(f);
	rel(b);
}

static int CEF_CALLBACK ls_on_before_popup(cef_life_span_handler_t* self, cef_browser_t* b, cef_frame_t* f, int popup_id,
                                           const cef_string_t* url, const cef_string_t* name,
                                           cef_window_open_disposition_t disp, int gesture,
                                           const cef_popup_features_t* feat, cef_window_info_t* wi, cef_client_t** client,
                                           cef_browser_settings_t* settings, cef_dictionary_value_t** extra, int* no_js) {
	(void)popup_id; (void)name; (void)gesture; (void)feat; (void)wi; (void)client; (void)settings; (void)extra; (void)no_js;
	View* v = VIEW_OF(Life, self);
	/* Every new window becomes a tab in the chrome, which owns tabs. */
	char* u = str8(url);
	Buf m = msg_begin(PB_OPEN_TAB, (uint16_t)v->id);
	put_u8(&m, disp != CEF_WOD_NEW_BACKGROUND_TAB);
	put_str(&m, u);
	msg_send(&m);
	free(u);
	rel(f);
	rel(b);
	return 1; /* cancel CEF's own popup */
}
/* prefers-color-scheme follows the chrome's theme. CEF's
 * set_chrome_color_scheme() only reaches Chrome-style browsers, and these are
 * Alloy-style (windowless), so ask DevTools to emulate the media feature. */
static void apply_theme(View* v) {
	if (g_dark < 0 || !v || !v->browser) return;
	cef_browser_host_t* h = v->browser->get_host(v->browser);
	cef_dictionary_value_t* feature = cef_dictionary_value_create();
	cef_string_t k = {0}, val = {0};
	set16(&k, "name");
	set16(&val, "prefers-color-scheme");
	feature->set_string(feature, &k, &val);
	set16(&k, "value");
	set16(&val, g_dark ? "dark" : "light");
	feature->set_string(feature, &k, &val);
	cef_list_value_t* list = cef_list_value_create();
	list->set_dictionary(list, 0, feature);
	cef_dictionary_value_t* params = cef_dictionary_value_create();
	set16(&k, "features");
	params->set_list(params, &k, list);
	cef_string_t method = {0};
	set16(&method, "Emulation.setEmulatedMedia");
	h->execute_dev_tools_method(h, 0, &method, params);
	cef_string_clear(&method);
	cef_string_clear(&k);
	cef_string_clear(&val);
	rel(h);
}

static void CEF_CALLBACK ls_on_after_created(cef_life_span_handler_t* self, cef_browser_t* b) {
	View* v = VIEW_OF(Life, self);
	v->browser = b; /* keep the reference we were given */
	g_open_browsers++;
	Buf m = msg_begin(PB_READY, (uint16_t)v->id);
	msg_send(&m);
	cef_browser_host_t* h = b->get_host(b);
	if (!v->visible) h->was_hidden(h, 1);
	if (v->focused) h->set_focus(h, 1);
	rel(h);
	apply_theme(v);
	if (v->pending_url) {
		cef_frame_t* f = b->get_main_frame(b);
		cef_string_t s = {0};
		set16(&s, v->pending_url);
		f->load_url(f, &s);
		cef_string_clear(&s);
		rel(f);
		free(v->pending_url);
		v->pending_url = NULL;
	}
}
static int CEF_CALLBACK ls_do_close(cef_life_span_handler_t* self, cef_browser_t* b) {
	View* v = VIEW_OF(Life, self);
	if (!g_quitting && v->alive) {
		/* window.close() from the page: tell the chrome, which closes the tab */
		Buf m = msg_begin(PB_CLOSED, (uint16_t)v->id);
		msg_send(&m);
	}
	rel(b);
	return 0;
}
static void CEF_CALLBACK ls_on_before_close(cef_life_span_handler_t* self, cef_browser_t* b) {
	View* v = VIEW_OF(Life, self);
	rel(b);
	if (v->browser) {
		cef_browser_t* held = v->browser;
		v->browser = NULL;
		rel(held);
	}
	v->alive = 0;
	if (v->id > 0 && v->id < MAX_VIEWS && g_views[v->id] == v) g_views[v->id] = NULL;
	if (v->shm) munmap(v->shm, (size_t)v->sw * v->sh * 4);
	if (v->shm_fd >= 0) close(v->shm_fd);
	free(v->backing);
	free(v->popup);
	v->shm = NULL;
	v->backing = v->popup = NULL;
	/* the View struct itself is not freed: CEF may still hold its handlers */
	g_open_browsers--;
	if (g_quitting && g_open_browsers <= 0) cef_quit_message_loop();
}

static void CEF_CALLBACK rq_on_render_process_terminated(cef_request_handler_t* self, cef_browser_t* b,
                                                         cef_termination_status_t st, int code, const cef_string_t* text) {
	View* v = VIEW_OF(Request, self);
	char* t = str8(text);
	char reason[256];
	snprintf(reason, sizeof reason, "%s (status %d, code %d)", t[0] ? t : "the page's process ended", (int)st, code);
	send_str(PB_CRASHED, v->id, reason);
	free(t);
	rel(b);
}

/* ------------------------------------------------------------------------
 * dialogs, downloads, context menus: held callbacks keyed by an id the
 * chrome echoes back
 * ---------------------------------------------------------------------- */

typedef struct {
	uint32_t id;
	int kind; /* 0 js dialog, 1 context menu */
	cef_jsdialog_callback_t* js;
	cef_run_context_menu_callback_t* menu;
} Pending;
static Pending g_pending[MAX_PENDING];
static uint32_t g_next_id = 1;

static uint32_t pending_add(Pending p) {
	for (int i = 0; i < MAX_PENDING; i++) {
		if (!g_pending[i].id) {
			p.id = g_next_id++;
			g_pending[i] = p;
			return p.id;
		}
	}
	return 0;
}
static Pending* pending_find(uint32_t id) {
	for (int i = 0; i < MAX_PENDING; i++)
		if (g_pending[i].id == id) return &g_pending[i];
	return NULL;
}

static int CEF_CALLBACK jd_on_jsdialog(cef_jsdialog_handler_t* self, cef_browser_t* b, const cef_string_t* origin,
                                       cef_jsdialog_type_t type, const cef_string_t* text, const cef_string_t* def,
                                       cef_jsdialog_callback_t* cb, int* suppress) {
	(void)origin;
	View* v = VIEW_OF(JsDialog, self);
	*suppress = 0;
	Pending p = {.kind = 0, .js = cb};
	uint32_t id = pending_add(p);
	if (!id) {
		rel(cb);
		rel(b);
		*suppress = 1;
		return 0;
	}
	char* t = str8(text);
	char* d = str8(def);
	Buf m = msg_begin(PB_DIALOG, (uint16_t)v->id);
	put_u32(&m, id);
	put_u8(&m, type == JSDIALOGTYPE_ALERT ? PB_DIALOG_ALERT : type == JSDIALOGTYPE_CONFIRM ? PB_DIALOG_CONFIRM : PB_DIALOG_PROMPT);
	put_str(&m, t);
	put_str(&m, d);
	msg_send(&m);
	free(t);
	free(d);
	rel(b);
	return 1;
}
static int CEF_CALLBACK jd_on_before_unload(cef_jsdialog_handler_t* self, cef_browser_t* b, const cef_string_t* text,
                                            int is_reload, cef_jsdialog_callback_t* cb) {
	(void)is_reload;
	View* v = VIEW_OF(JsDialog, self);
	Pending p = {.kind = 0, .js = cb};
	uint32_t id = pending_add(p);
	if (!id) {
		rel(cb);
		rel(b);
		return 0;
	}
	char* t = str8(text);
	Buf m = msg_begin(PB_DIALOG, (uint16_t)v->id);
	put_u32(&m, id);
	put_u8(&m, PB_DIALOG_BEFOREUNLOAD);
	put_str(&m, t);
	put_str(&m, "");
	msg_send(&m);
	free(t);
	rel(b);
	return 1;
}
static void CEF_CALLBACK jd_on_reset(cef_jsdialog_handler_t* self, cef_browser_t* b) { (void)self; rel(b); }
static void CEF_CALLBACK jd_on_closed(cef_jsdialog_handler_t* self, cef_browser_t* b) { (void)self; rel(b); }

/* downloads */
typedef struct {
	uint32_t cef_id;
	cef_download_item_callback_t* cb;
} DlCb;
static DlCb g_dls[256];
static pthread_mutex_t g_dl_lock = PTHREAD_MUTEX_INITIALIZER;

static char* unique_path(const char* dir, const char* name) {
	char path[PATH_MAX];
	const char* base = (name && name[0]) ? name : "download";
	snprintf(path, sizeof path, "%s/%s", dir, base);
	struct stat st;
	if (stat(path, &st) != 0) return strdup(path);
	const char* dot = strrchr(base, '.');
	size_t stem = dot && dot != base ? (size_t)(dot - base) : strlen(base);
	for (int i = 1; i < 1000; i++) {
		snprintf(path, sizeof path, "%s/%.*s (%d)%s", dir, (int)stem, base, i, dot && dot != base ? dot : "");
		if (stat(path, &st) != 0) return strdup(path);
	}
	return strdup(path);
}

static int CEF_CALLBACK dl_can_download(cef_download_handler_t* self, cef_browser_t* b, const cef_string_t* url, const cef_string_t* method) {
	(void)self; (void)url; (void)method;
	rel(b);
	return 1;
}
static int CEF_CALLBACK dl_on_before(cef_download_handler_t* self, cef_browser_t* b, cef_download_item_t* item,
                                     const cef_string_t* suggested, cef_before_download_callback_t* cb) {
	(void)self;
	char* name = str8(suggested);
	mkdir(g_downloads, 0700);
	char* path = unique_path(g_downloads, name);
	cef_string_t p = {0};
	set16(&p, path);
	cb->cont(cb, &p, 0);
	cef_string_clear(&p);
	free(path);
	free(name);
	rel(cb);
	rel(item);
	rel(b);
	return 1;
}
static void CEF_CALLBACK dl_on_updated(cef_download_handler_t* self, cef_browser_t* b, cef_download_item_t* item,
                                       cef_download_item_callback_t* cb) {
	View* v = VIEW_OF(Download, self);
	uint32_t id = item->get_id(item);
	uint8_t state = PB_DL_PROGRESS;
	if (item->is_complete(item)) state = PB_DL_DONE;
	else if (item->is_canceled(item)) state = PB_DL_CANCELLED;
	else if (item->is_interrupted(item)) state = PB_DL_FAILED;

	pthread_mutex_lock(&g_dl_lock);
	DlCb* slot = &g_dls[id % 256];
	if (state == PB_DL_PROGRESS) {
		if (slot->cb && slot->cef_id != id) rel(slot->cb);
		if (slot->cef_id != id || !slot->cb) {
			slot->cef_id = id;
			slot->cb = cb;
			cb = NULL; /* keep this reference for cancel */
		}
	} else if (slot->cef_id == id && slot->cb) {
		rel(slot->cb);
		slot->cb = NULL;
	}
	pthread_mutex_unlock(&g_dl_lock);

	char* url = ustr8(item->get_url(item));
	char* path = ustr8(item->get_full_path(item));
	char* mime = ustr8(item->get_mime_type(item));
	Buf m = msg_begin(PB_DOWNLOAD, (uint16_t)v->id);
	put_u32(&m, id);
	put_u8(&m, state);
	put_i64(&m, item->get_received_bytes(item));
	put_i64(&m, item->get_total_bytes(item));
	put_str(&m, url);
	put_str(&m, path);
	put_str(&m, mime);
	msg_send(&m);
	free(url);
	free(path);
	free(mime);
	rel(cb);
	rel(item);
	rel(b);
}

/* context menu: the chrome draws it, with shadcn, and answers with a command */
static int CEF_CALLBACK cm_run(cef_context_menu_handler_t* self, cef_browser_t* b, cef_frame_t* f,
                               cef_context_menu_params_t* params, cef_menu_model_t* model,
                               cef_run_context_menu_callback_t* cb) {
	View* v = VIEW_OF(Menu, self);
	Pending p = {.kind = 1, .menu = cb};
	uint32_t id = pending_add(p);
	if (!id) {
		cb->cancel(cb);
		rel(cb);
		rel(params);
		rel(model);
		rel(f);
		rel(b);
		return 1;
	}
	char* link = ustr8(params->get_link_url(params));
	char* sel = ustr8(params->get_selection_text(params));
	char* src = ustr8(params->get_source_url(params));
	Buf m = msg_begin(PB_MENU, (uint16_t)v->id);
	put_u32(&m, id);
	put_f32(&m, (float)params->get_xcoord(params));
	put_f32(&m, (float)params->get_ycoord(params));
	put_str(&m, link);
	put_str(&m, sel);
	put_str(&m, params->has_image_contents(params) ? src : "");
	put_u8(&m, (uint8_t)params->is_editable(params));
	size_t n = model->get_count(model);
	put_u32(&m, (uint32_t)n);
	for (size_t i = 0; i < n; i++) {
		cef_menu_item_type_t t = model->get_type_at(model, i);
		put_i32(&m, model->get_command_id_at(model, i));
		uint8_t kind = t == MENUITEMTYPE_SEPARATOR ? PB_MENU_SEPARATOR
		             : (t == MENUITEMTYPE_CHECK && model->is_checked_at(model, i)) ? PB_MENU_CHECKED
		             : PB_MENU_ITEM;
		put_u8(&m, kind);
		put_u8(&m, (uint8_t)model->is_enabled_at(model, i));
		char* label = ustr8(model->get_label_at(model, i));
		/* menu labels carry '&' accelerators */
		char* w = label;
		for (char* r = label; *r; r++) {
			if (*r == '&' && r[1] != '&') continue;
			if (*r == '&') r++;
			*w++ = *r;
		}
		*w = 0;
		put_str(&m, label);
		free(label);
	}
	msg_send(&m);
	free(link);
	free(sel);
	free(src);
	rel(params);
	rel(model);
	rel(f);
	rel(b);
	return 1;
}

static void CEF_CALLBACK fh_on_find_result(cef_find_handler_t* self, cef_browser_t* b, int ident, int count,
                                           const cef_rect_t* sel, int active, int final) {
	(void)ident; (void)sel;
	View* v = VIEW_OF(Find, self);
	if (final) {
		Buf m = msg_begin(PB_FIND_RESULT, (uint16_t)v->id);
		put_i32(&m, count);
		put_i32(&m, active);
		msg_send(&m);
	}
	rel(b);
}

/* ------------------------------------------------------------------------
 * client: one per view, so every handler knows its view without a lookup
 * ---------------------------------------------------------------------- */

#define CLIENT_GET(name, field, T)                                                    \
	static T* CEF_CALLBACK cl_##name(cef_client_t* self) {                           \
		View* v = ((Client*)self)->v;                                                  \
		return &v->field.h;                                                            \
	}
CLIENT_GET(get_render_handler, render, cef_render_handler_t)
CLIENT_GET(get_display_handler, display, cef_display_handler_t)
CLIENT_GET(get_load_handler, load, cef_load_handler_t)
CLIENT_GET(get_life_span_handler, life, cef_life_span_handler_t)
CLIENT_GET(get_jsdialog_handler, jsdialog, cef_jsdialog_handler_t)
CLIENT_GET(get_download_handler, download, cef_download_handler_t)
CLIENT_GET(get_context_menu_handler, menu, cef_context_menu_handler_t)
CLIENT_GET(get_request_handler, request, cef_request_handler_t)
CLIENT_GET(get_find_handler, find, cef_find_handler_t)

/* ------------------------------------------------------------------------
 * autofill, browser side: what the renderer reports, checked against what
 * this process knows about the view
 * ---------------------------------------------------------------------- */

/* the view's top-level origin, as the browser process knows it */
static char* top_origin(cef_browser_t* b) {
	cef_frame_t* main = b->get_main_frame(b);
	if (!main) return strdup("");
	char* url = ustr8(main->get_url(main));
	char* o = origin_of(url);
	free(url);
	rel(main);
	return o;
}

static char* list_str(cef_list_value_t* l, size_t i) {
	if (l->get_type(l, i) != VTYPE_STRING) return strdup("");
	return ustr8_secret(l->get_string(l, i));
}
static double list_num(cef_list_value_t* l, size_t i) {
	cef_value_type_t t = l->get_type(l, i);
	if (t == VTYPE_DOUBLE) return l->get_double(l, i);
	if (t == VTYPE_INT) return l->get_int(l, i);
	return 0;
}

static int CEF_CALLBACK cl_on_process_message_received(cef_client_t* self, cef_browser_t* b, cef_frame_t* f,
                                                       cef_process_id_t src, cef_process_message_t* msg) {
	View* v = ((Client*)self)->v;
	char* name = ustr8(msg->get_name(msg));
	cef_list_value_t* args = msg->get_argument_list(msg);
	int handled = 0;
	/* Only the top-level frame's script is ever installed, but the frame that
	 * sent this is the browser process's own record, not the renderer's
	 * word: a report from any other frame is dropped here as well. */
	int main = f && f->is_main(f);
	if (src == PID_RENDERER && strcmp(name, "palm-af") == 0 && main && args && args->get_size(args) >= 1) {
		handled = 1;
		char* kind = list_str(args, 0);
		char* top = top_origin(b);
		if (strcmp(kind, "focus") == 0 && args->get_size(args) >= 7) {
			char* said = list_str(args, 6);
			/* the page's location.origin and the browser's must agree */
			if (top[0] && strcmp(said, top) == 0) {
				float z = v->zoom > 0 ? v->zoom : 1;
				Buf m = msg_begin(PB_FIELD_FOCUS, (uint16_t)v->id);
				int k = (int)list_num(args, 1);
				put_u8(&m, (uint8_t)(k >= 0 && k <= PB_FIELD_OTP ? k : 0));
				put_f32(&m, (float)list_num(args, 2) * z);
				put_f32(&m, (float)list_num(args, 3) * z);
				put_f32(&m, (float)list_num(args, 4) * z);
				put_f32(&m, (float)list_num(args, 5) * z);
				put_str(&m, top);
				msg_send(&m);
			} else {
				VLOG("autofill: focus report from %s on a view at %s dropped", said, top);
			}
			free(said);
		} else if (strcmp(kind, "submit") == 0 && args->get_size(args) >= 5) {
			char* said = list_str(args, 1);
			char* user = list_str(args, 2);
			char* pass = list_str(args, 3);
			char* old = list_str(args, 4);
			if (top[0] && strcmp(said, top) == 0 && pass[0]) {
				Buf m = msg_begin(PB_FORM_SUBMIT, (uint16_t)v->id);
				put_str(&m, top);
				put_str(&m, user);
				put_str(&m, pass);
				put_str(&m, old);
				msg_send_secret(&m);
			}
			free(said);
			free_secret(user);
			free_secret(pass);
			free_secret(old);
		}
		free(top);
		free(kind);
	} else if (src == PID_RENDERER && strcmp(name, "palm-af-result") == 0 && args && args->get_size(args) >= 1) {
		handled = 1;
		Buf m = msg_begin(PB_FILL_RESULT, (uint16_t)v->id);
		put_u8(&m, (uint8_t)list_num(args, 0));
		msg_send(&m);
	}
	rel(args);
	free(name);
	rel(msg);
	rel(f);
	rel(b);
	return handled;
}


static View* view_new(int id) {
	View* v = calloc(1, sizeof *v);
	v->id = id;
	v->alive = 1;
	v->shm_fd = -1;
	v->scale = 1;
	v->zoom = 1;
	v->visible = 1;

	v->client.v = v;
	init_static(&v->client.client.base, sizeof(cef_client_t));
	v->client.client.get_render_handler = cl_get_render_handler;
	v->client.client.get_display_handler = cl_get_display_handler;
	v->client.client.get_load_handler = cl_get_load_handler;
	v->client.client.get_life_span_handler = cl_get_life_span_handler;
	v->client.client.get_jsdialog_handler = cl_get_jsdialog_handler;
	v->client.client.get_download_handler = cl_get_download_handler;
	v->client.client.get_context_menu_handler = cl_get_context_menu_handler;
	v->client.client.get_request_handler = cl_get_request_handler;
	v->client.client.get_find_handler = cl_get_find_handler;
	v->client.client.on_process_message_received = cl_on_process_message_received;

	v->render.v = v;
	init_static(&v->render.h.base, sizeof(cef_render_handler_t));
	v->render.h.get_view_rect = rh_get_view_rect;
	v->render.h.get_screen_info = rh_get_screen_info;
	v->render.h.get_screen_point = rh_get_screen_point;
	v->render.h.on_popup_show = rh_on_popup_show;
	v->render.h.on_popup_size = rh_on_popup_size;
	v->render.h.on_paint = rh_on_paint;
	v->render.h.on_text_selection_changed = rh_on_text_selection_changed;

	v->display.v = v;
	init_static(&v->display.h.base, sizeof(cef_display_handler_t));
	v->display.h.on_address_change = dh_on_address_change;
	v->display.h.on_title_change = dh_on_title_change;
	v->display.h.on_favicon_urlchange = dh_on_favicon_urlchange;
	v->display.h.on_status_message = dh_on_status_message;
	v->display.h.on_loading_progress_change = dh_on_loading_progress_change;
	v->display.h.on_cursor_change = dh_on_cursor_change;
	v->display.h.on_console_message = dh_on_console_message;

	v->load.v = v;
	init_static(&v->load.h.base, sizeof(cef_load_handler_t));
	v->load.h.on_loading_state_change = lh_on_loading_state_change;
	v->load.h.on_load_error = lh_on_load_error;
	v->load.h.on_load_start = lh_on_load_start;
	v->load.h.on_load_end = lh_on_load_end;

	v->life.v = v;
	init_static(&v->life.h.base, sizeof(cef_life_span_handler_t));
	v->life.h.on_before_popup = ls_on_before_popup;
	v->life.h.on_after_created = ls_on_after_created;
	v->life.h.do_close = ls_do_close;
	v->life.h.on_before_close = ls_on_before_close;

	v->jsdialog.v = v;
	init_static(&v->jsdialog.h.base, sizeof(cef_jsdialog_handler_t));
	v->jsdialog.h.on_jsdialog = jd_on_jsdialog;
	v->jsdialog.h.on_before_unload_dialog = jd_on_before_unload;
	v->jsdialog.h.on_reset_dialog_state = jd_on_reset;
	v->jsdialog.h.on_dialog_closed = jd_on_closed;

	v->download.v = v;
	init_static(&v->download.h.base, sizeof(cef_download_handler_t));
	v->download.h.can_download = dl_can_download;
	v->download.h.on_before_download = dl_on_before;
	v->download.h.on_download_updated = dl_on_updated;

	v->menu.v = v;
	init_static(&v->menu.h.base, sizeof(cef_context_menu_handler_t));
	v->menu.h.run_context_menu = cm_run;

	v->request.v = v;
	init_static(&v->request.h.base, sizeof(cef_request_handler_t));
	v->request.h.on_render_process_terminated = rq_on_render_process_terminated;

	v->find.v = v;
	init_static(&v->find.h.base, sizeof(cef_find_handler_t));
	v->find.h.on_find_result = fh_on_find_result;
	return v;
}

/* ------------------------------------------------------------------------
 * dispatch: runs on the UI thread, one message at a time
 * ---------------------------------------------------------------------- */

static void close_all(void) {
	g_quitting = 1;
	for (int i = 1; i < MAX_VIEWS; i++) {
		View* v = g_views[i];
		if (v && v->browser) {
			cef_browser_host_t* h = host_of(v);
			h->close_browser(h, 1);
			rel(h);
		}
	}
	if (g_open_browsers <= 0) cef_quit_message_loop();
}

static void handle(uint16_t op, uint16_t view, Rd* r) {
	View* v = view_get(view);
	cef_browser_host_t* h = NULL;
	switch (op) {
	case PB_CREATE: {
		int w = rd_i32(r), hh = rd_i32(r);
		float scale = rd_f32(r);
		char* url = rd_str(r);
		if (view <= 0 || view >= MAX_VIEWS || g_views[view]) {
			logf_("create: bad or duplicate view %d", view);
			free(url);
			break;
		}
		v = view_new(view);
		v->w = w;
		v->h = hh;
		v->scale = scale > 0 ? scale : 1;
		g_views[view] = v;
		cef_window_info_t wi = {0};
		wi.size = sizeof wi;
		wi.windowless_rendering_enabled = 1;
		wi.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
		cef_browser_settings_t bs = {0};
		bs.size = sizeof bs;
		bs.windowless_frame_rate = 60;
		bs.background_color = 0xffffffff;
		cef_string_t u = {0};
		set16(&u, url[0] ? url : "about:blank");
		if (!cef_browser_host_create_browser(&wi, &v->client.client, &u, &bs, NULL, NULL))
			logf_("create_browser failed for view %d", view);
		cef_string_clear(&u);
		free(url);
		break;
	}
	case PB_CLOSE:
		if (v && v->browser) {
			v->alive = 0;
			h = host_of(v);
			h->close_browser(h, 1);
		}
		break;
	case PB_NAVIGATE: {
		char* url = rd_str(r);
		if (v && v->browser) {
			cef_frame_t* f = v->browser->get_main_frame(v->browser);
			cef_string_t u = {0};
			set16(&u, url);
			f->load_url(f, &u);
			cef_string_clear(&u);
			rel(f);
		} else if (v) {
			free(v->pending_url);
			v->pending_url = strdup(url);
		}
		free(url);
		break;
	}
	case PB_HISTORY: {
		int d = rd_i32(r);
		if (v && v->browser) {
			if (d < 0) v->browser->go_back(v->browser);
			else if (d > 0) v->browser->go_forward(v->browser);
		}
		break;
	}
	case PB_RELOAD: {
		int bypass = rd_u8(r);
		if (v && v->browser) {
			if (bypass) v->browser->reload_ignore_cache(v->browser);
			else v->browser->reload(v->browser);
		}
		break;
	}
	case PB_STOP:
		if (v && v->browser) v->browser->stop_load(v->browser);
		break;
	case PB_RESIZE: {
		int w = rd_i32(r), hh = rd_i32(r);
		float scale = rd_f32(r);
		if (!v) break;
		int scale_changed = scale > 0 && scale != v->scale;
		v->w = w;
		v->h = hh;
		if (scale > 0) v->scale = scale;
		if (v->browser) {
			h = host_of(v);
			if (scale_changed) h->notify_screen_info_changed(h);
			h->was_resized(h);
		}
		break;
	}
	case PB_SHOW: {
		int vis = rd_u8(r);
		if (!v) break;
		v->visible = vis;
		if (v->browser) {
			h = host_of(v);
			h->was_hidden(h, !vis);
			if (vis) h->invalidate(h, PET_VIEW);
		}
		break;
	}
	case PB_FOCUS: {
		int foc = rd_u8(r);
		if (!v) break;
		v->focused = foc;
		if (v->browser) {
			h = host_of(v);
			h->set_focus(h, foc);
		}
		break;
	}
	case PB_MOUSE: {
		int kind = rd_u8(r), button = rd_u8(r), clicks = rd_u8(r);
		rd_u8(r);
		uint32_t mods = rd_u32(r);
		float x = rd_f32(r), y = rd_f32(r);
		if (!v || !v->browser) break;
		h = host_of(v);
		cef_mouse_event_t e = {(int)x, (int)y, cef_mods(mods)};
		if (kind == PB_MOUSE_MOVE || kind == PB_MOUSE_LEAVE) {
			h->send_mouse_move_event(h, &e, kind == PB_MOUSE_LEAVE);
		} else {
			cef_mouse_button_type_t bt = button == PB_BUTTON_RIGHT ? MBT_RIGHT : button == PB_BUTTON_MIDDLE ? MBT_MIDDLE : MBT_LEFT;
			if (kind == PB_MOUSE_DOWN) {
				e.modifiers |= bt == MBT_LEFT ? EVENTFLAG_LEFT_MOUSE_BUTTON : bt == MBT_RIGHT ? EVENTFLAG_RIGHT_MOUSE_BUTTON : EVENTFLAG_MIDDLE_MOUSE_BUTTON;
				if (!v->focused) {
					v->focused = 1;
					h->set_focus(h, 1);
				}
			}
			h->send_mouse_click_event(h, &e, bt, kind == PB_MOUSE_UP, clicks ? clicks : 1);
		}
		break;
	}
	case PB_WHEEL: {
		uint32_t mods = rd_u32(r);
		float x = rd_f32(r), y = rd_f32(r), dx = rd_f32(r), dy = rd_f32(r);
		if (!v || !v->browser) break;
		h = host_of(v);
		cef_mouse_event_t e = {(int)x, (int)y, cef_mods(mods)};
		h->send_mouse_wheel_event(h, &e, (int)dx, (int)dy);
		break;
	}
	case PB_KEY: {
		int kind = rd_u8(r);
		rd_u8(r); rd_u8(r); rd_u8(r);
		uint32_t mods = rd_u32(r), sym = rd_u32(r), cp = rd_u32(r);
		if (!v || !v->browser) break;
		h = host_of(v);
		cef_key_event_t e = {0};
		e.size = sizeof e;
		e.modifiers = cef_mods(mods);
		e.windows_key_code = vk_of(sym);
		e.native_key_code = (int)sym;
		e.character = (char16_t)(cp < 0x10000 ? cp : 0);
		e.unmodified_character = e.character;
		if (kind == PB_KEY_DOWN) {
			e.type = KEYEVENT_RAWKEYDOWN;
			h->send_key_event(h, &e);
			/* Enter, Tab and Backspace are control characters that Blink also
			 * wants as a CHAR; printable text arrives as its own CHAR. */
			int ctl = sym == 0xff0d || sym == 0xff8d || sym == 0xff09 || sym == 0xff08;
			if ((cp >= 0x20 || ctl) && !(mods & (PB_MOD_CTRL | PB_MOD_ALT | PB_MOD_SUPER))) {
				e.type = KEYEVENT_CHAR;
				if (ctl) e.character = e.unmodified_character = (char16_t)(sym == 0xff09 ? 9 : sym == 0xff08 ? 8 : 13);
				e.windows_key_code = e.character;
				h->send_key_event(h, &e);
			}
		} else if (kind == PB_KEY_UP) {
			e.type = KEYEVENT_KEYUP;
			h->send_key_event(h, &e);
		} else {
			e.type = KEYEVENT_CHAR;
			e.windows_key_code = e.character;
			h->send_key_event(h, &e);
		}
		break;
	}
	case PB_FRAME_ACK:
		if (v) {
			v->inflight = 0;
			flush(v);
		}
		break;
	case PB_ZOOM: {
		float f = rd_f32(r);
		if (v && v->browser && f > 0) {
			h = host_of(v);
			/* Chromium's zoom level is log base 1.2 of the factor */
			h->set_zoom_level(h, log((double)f) / log(1.2));
			v->zoom = f;
		}
		break;
	}
	case PB_DIALOG_REPLY: {
		uint32_t id = rd_u32(r);
		int ok = rd_u8(r);
		char* text = rd_str(r);
		Pending* p = pending_find(id);
		if (p && p->kind == 0 && p->js) {
			cef_string_t t = {0};
			set16(&t, text);
			p->js->cont(p->js, ok, &t);
			cef_string_clear(&t);
			rel(p->js);
			memset(p, 0, sizeof *p);
		}
		free(text);
		break;
	}
	case PB_MENU_REPLY: {
		uint32_t id = rd_u32(r);
		int cmd = rd_i32(r);
		Pending* p = pending_find(id);
		if (p && p->kind == 1 && p->menu) {
			if (cmd >= 0) p->menu->cont(p->menu, cmd, EVENTFLAG_NONE);
			else p->menu->cancel(p->menu);
			rel(p->menu);
			memset(p, 0, sizeof *p);
		}
		break;
	}
	case PB_FIND: {
		int fwd = rd_u8(r), next = rd_u8(r);
		char* text = rd_str(r);
		if (v && v->browser) {
			h = host_of(v);
			if (!text[0]) {
				h->stop_finding(h, 1);
			} else {
				cef_string_t t = {0};
				set16(&t, text);
				h->find(h, &t, fwd, 0, next);
				cef_string_clear(&t);
			}
		}
		free(text);
		break;
	}
	case PB_DOWNLOAD_CANCEL: {
		uint32_t id = rd_u32(r);
		pthread_mutex_lock(&g_dl_lock);
		DlCb* slot = &g_dls[id % 256];
		if (slot->cef_id == id && slot->cb) slot->cb->cancel(slot->cb);
		pthread_mutex_unlock(&g_dl_lock);
		break;
	}
	case PB_EDIT: {
		int action = rd_u8(r);
		char* text = rd_str(r);
		if (v && v->browser) {
			cef_frame_t* f = v->browser->get_focused_frame(v->browser);
			if (!f) f = v->browser->get_main_frame(v->browser);
			switch (action) {
			case PB_EDIT_UNDO: f->undo(f); break;
			case PB_EDIT_REDO: f->redo(f); break;
			case PB_EDIT_CUT: f->cut(f); break;
			case PB_EDIT_COPY: f->copy(f); break;
			case PB_EDIT_PASTE: f->paste(f); break;
			case PB_EDIT_SELECT_ALL: f->select_all(f); break;
			case PB_EDIT_INSERT: {
				/* the chrome owns the system clipboard; it pastes by inserting */
				h = host_of(v);
				cef_string_t t = {0};
				set16(&t, text);
				h->ime_commit_text(h, &t, NULL, 0);
				cef_string_clear(&t);
				break;
			}
			}
			rel(f);
		}
		free(text);
		break;
	}
	case PB_THEME: {
		g_dark = rd_u8(r);
		for (int i = 1; i < MAX_VIEWS; i++)
			if (g_views[i]) apply_theme(g_views[i]);
		break;
	}
	case PB_FILL: {
		char* want = rd_str(r);
		char* user = rd_str(r);
		char* pass = rd_str(r);
		char* otp = rd_str(r);
		uint8_t status = PB_FILL_FAILED;
		if (v && v->browser && !r->bad) {
			/* The person chose this login for `want`. If the view is
			 * somewhere else now -- it navigated while the vault asked --
			 * the fill is dropped here, before anything reaches a renderer. */
			char* top = top_origin(v->browser);
			if (!top[0] || strcmp(top, want) != 0) {
				status = PB_FILL_ORIGIN_CHANGED;
				logf_("autofill: dropped a fill for %s: the view is at %s", want, top[0] ? top : "a non-web page");
			} else {
				cef_frame_t* f = v->browser->get_main_frame(v->browser);
				cef_string_t n = {0};
				set16(&n, "palm-af-fill");
				cef_process_message_t* m = cef_process_message_create(&n);
				cef_string_clear(&n);
				cef_list_value_t* l = m->get_argument_list(m);
				const char* vals[4] = {want, user, pass, otp};
				for (int i = 0; i < 4; i++) {
					cef_string_t s16 = {0};
					set16(&s16, vals[i]);
					l->set_string(l, (size_t)i, &s16);
					clear_secret16(&s16);
				}
				rel(l);
				f->send_process_message(f, PID_RENDERER, m); /* takes our reference */
				rel(f);
				status = 255; /* the renderer answers */
			}
			free(top);
		}
		if (status != 255) {
			Buf m = msg_begin(PB_FILL_RESULT, (uint16_t)view);
			put_u8(&m, status);
			msg_send(&m);
		}
		free(want);
		free_secret(user);
		free_secret(pass);
		free_secret(otp);
		break;
	}
	case PB_QUIT:
		close_all();
		break;
	default:
		VLOG("unknown op %u", op);
	}
	rel(h);
}

/* a received message, carried to the UI thread */
typedef struct {
	cef_task_t task;
	atomic_int refs;
	uint8_t* data;
	uint32_t size;
} Task;
static void CEF_CALLBACK task_add_ref(cef_base_ref_counted_t* b) { atomic_fetch_add(&((Task*)b)->refs, 1); }
static int CEF_CALLBACK task_release(cef_base_ref_counted_t* b) {
	Task* t = (Task*)b;
	if (atomic_fetch_sub(&t->refs, 1) == 1) {
		free(t->data);
		free(t);
		return 1;
	}
	return 0;
}
static int CEF_CALLBACK task_has_one(cef_base_ref_counted_t* b) { return atomic_load(&((Task*)b)->refs) == 1; }
static int CEF_CALLBACK task_has_any(cef_base_ref_counted_t* b) { return atomic_load(&((Task*)b)->refs) >= 1; }
static void CEF_CALLBACK task_execute(cef_task_t* self) {
	Task* t = (Task*)self;
	uint16_t op, view;
	memcpy(&op, t->data + 4, 2);
	memcpy(&view, t->data + 6, 2);
	Rd r = {t->data + 8, t->size - 8, 0, 0};
	handle(op, view, &r);
	if (r.bad) logf_("message %u for view %u was short", op, view);
	if (op == PB_FILL) explicit_bzero(t->data, t->size); /* it carried a password */
}
static void post(uint8_t* data, uint32_t size) {
	Task* t = calloc(1, sizeof *t);
	t->task.base.size = sizeof(cef_task_t);
	t->task.base.add_ref = task_add_ref;
	t->task.base.release = task_release;
	t->task.base.has_one_ref = task_has_one;
	t->task.base.has_at_least_one_ref = task_has_any;
	t->task.execute = task_execute;
	atomic_store(&t->refs, 1);
	t->data = data;
	t->size = size;
	cef_post_task(TID_UI, &t->task);
}

/* ------------------------------------------------------------------------
 * the app: command-line switches for every process
 * ---------------------------------------------------------------------- */

static cef_app_t g_app;

/* ------------------------------------------------------------------------
 * autofill, renderer side. This code runs in the renderer processes (this
 * binary, re-executed with --type=renderer, inside Chromium's sandbox).
 *
 * When a top-level frame's V8 context is created -- before any page script
 * runs -- autofill.js is evaluated and called with a native `report`
 * function and the name of a wake-up event, 128 random bits chosen here.
 * Nothing is put on a global, and no reference to the page's script world is
 * kept: holding one stalls the next same-site navigation of the frame
 * (found the hard way; the old document never finished unloading).
 *
 * A fill ("palm-af-fill" from the browser process) is parked in this
 * process, the origin checked once more against the frame's URL, and the
 * wake-up event dispatched; the listener autofill.js registered asks
 * `report('pull')` for the parked values -- they travel from here to the
 * listener as V8 strings returned by a native function, never as source
 * text -- fills, and answers with `report('result', status)`. The parked
 * values are wiped as soon as they are pulled, and in any case when the
 * dispatch returns, so a page that learns the event's name (by replacing
 * dispatchEvent, say) can wake the listener whenever it likes and get
 * nothing: there is nothing parked.
 * ---------------------------------------------------------------------- */

typedef struct {
	int browser;
	char wake[48]; /* the wake-up event's name */
	char* parked[4]; /* origin, username, password, otp: only during a fill */
	int status;
} AfSlot;
static AfSlot g_af[64];

static AfSlot* af_slot(int browser) {
	for (int i = 0; i < 64; i++)
		if (g_af[i].wake[0] && g_af[i].browser == browser) return &g_af[i];
	return NULL;
}
static void af_unpark(AfSlot* s) {
	for (int i = 0; i < 4; i++) {
		free_secret(s->parked[i]);
		s->parked[i] = NULL;
	}
}

static AfSlot* af_slot_of_current(void) {
	cef_v8_context_t* c = cef_v8_context_get_current_context();
	if (!c) return NULL;
	cef_browser_t* b = c->get_browser(c);
	AfSlot* s = b ? af_slot(b->get_identifier(b)) : NULL;
	rel(b);
	rel(c);
	return s;
}

static int CEF_CALLBACK af_report(cef_v8_handler_t* self, const cef_string_t* name, cef_v8_value_t* object,
                                  size_t argc, cef_v8_value_t* const* argv, cef_v8_value_t** retval,
                                  cef_string_t* exception) {
	(void)self; (void)name; (void)exception;
	char* kind = NULL;
	if (argc >= 1 && argv[0]->is_string(argv[0])) kind = ustr8(argv[0]->get_string_value(argv[0]));
	if (kind && strcmp(kind, "pull") == 0) {
		/* the parked fill, once */
		AfSlot* s = af_slot_of_current();
		if (s && s->parked[0]) {
			cef_v8_value_t* arr = cef_v8_value_create_array(4);
			for (int i = 0; i < 4; i++) {
				cef_string_t v = {0};
				set16(&v, s->parked[i] ? s->parked[i] : "");
				arr->set_value_byindex(arr, i, cef_v8_value_create_string(&v));
				clear_secret16(&v);
			}
			*retval = arr;
			af_unpark(s);
		}
	} else if (kind && strcmp(kind, "result") == 0) {
		AfSlot* s = af_slot_of_current();
		if (s && argc >= 2 && (argv[1]->is_int(argv[1]) || argv[1]->is_double(argv[1]))) s->status = (int)argv[1]->get_double_value(argv[1]);
	} else if (kind) {
		/* "focus" and "submit": to the browser process, which checks them */
		cef_v8_context_t* c = cef_v8_context_get_current_context();
		cef_frame_t* f = c ? c->get_frame(c) : NULL;
		if (f && f->is_main(f) && argc <= 8) {
			cef_string_t n = {0};
			set16(&n, "palm-af");
			cef_process_message_t* m = cef_process_message_create(&n);
			cef_string_clear(&n);
			cef_list_value_t* l = m->get_argument_list(m);
			for (size_t i = 0; i < argc; i++) {
				cef_v8_value_t* a = argv[i];
				if (a->is_string(a)) {
					cef_string_userfree_t s = a->get_string_value(a);
					l->set_string(l, i, s);
					if (s) {
						if (s->str) explicit_bzero(s->str, s->length * sizeof(s->str[0]));
						cef_string_userfree_free(s);
					}
				} else if (a->is_int(a) || a->is_double(a)) {
					l->set_double(l, i, a->get_double_value(a));
				} else {
					l->set_null(l, i);
				}
			}
			rel(l);
			f->send_process_message(f, PID_BROWSER, m);
		}
		rel(f);
		rel(c);
	}
	free(kind);
	for (size_t i = 0; i < argc; i++) rel(argv[i]);
	rel(object);
	return 1;
}
static cef_v8_handler_t g_af_report;

static void CEF_CALLBACK rp_on_context_created(cef_render_process_handler_t* self, cef_browser_t* b, cef_frame_t* f,
                                               cef_v8_context_t* ctx) {
	(void)self;
	if (f->is_main(f)) {
		int id = b->get_identifier(b);
		AfSlot* s = af_slot(id);
		if (!s) {
			/* a free slot, or the oldest: a slot outlives its browser here
			 * (CEF reports browsers going away in processes that still hold
			 * their next document), so slots are recycled, not freed */
			static int next;
			for (int i = 0; i < 64 && !s; i++)
				if (!g_af[i].wake[0]) s = &g_af[i];
			if (!s) s = &g_af[next++ % 64];
		}
		if (s) {
			af_unpark(s);
			memset(s, 0, sizeof *s);
			s->browser = id;
			unsigned char rnd[16];
			if (getrandom(rnd, sizeof rnd, 0) != (ssize_t)sizeof rnd) memset(rnd, 0, sizeof rnd);
			char* w = s->wake + sprintf(s->wake, "palm-af-");
			for (int i = 0; i < 16; i++) w += sprintf(w, "%02x", rnd[i]);
			cef_string_t code = {0}, url = {0}, fname = {0}, wake = {0};
			set16(&code, AUTOFILL_JS);
			set16(&url, "palm-autofill.js");
			cef_v8_value_t* init = NULL;
			cef_v8_exception_t* ex = NULL;
			int evok = ctx->eval(ctx, &code, &url, 1, &init, &ex);
			if (evok && init && init->is_function(init)) {
				ctx->enter(ctx);
				set16(&fname, "report");
				set16(&wake, s->wake);
				cef_v8_value_t* args[2] = {cef_v8_value_create_function(&fname, &g_af_report), cef_v8_value_create_string(&wake)};
				cef_v8_value_t* fill = init->execute_function(init, NULL, 2, args);
				ctx->exit(ctx);
				rel(fill);
			}
			rel(ex);
			rel(init);
			cef_string_clear(&code);
			cef_string_clear(&url);
			cef_string_clear(&fname);
			cef_string_clear(&wake);
		}
	}
	rel(ctx);
	rel(f);
	rel(b);
}

static void af_answer(cef_frame_t* f, int status) {
	cef_string_t n = {0};
	set16(&n, "palm-af-result");
	cef_process_message_t* m = cef_process_message_create(&n);
	cef_string_clear(&n);
	cef_list_value_t* l = m->get_argument_list(m);
	l->set_int(l, 0, status);
	rel(l);
	f->send_process_message(f, PID_BROWSER, m);
}

static int CEF_CALLBACK rp_on_process_message_received(cef_render_process_handler_t* self, cef_browser_t* b,
                                                       cef_frame_t* f, cef_process_id_t src, cef_process_message_t* msg) {
	(void)self;
	char* name = ustr8(msg->get_name(msg));
	int handled = 0;
	if (src == PID_BROWSER && strcmp(name, "palm-af-fill") == 0) {
		handled = 1;
		cef_list_value_t* l = msg->get_argument_list(msg);
		AfSlot* s = af_slot(b->get_identifier(b));
		int status = PB_FILL_FAILED;
		char* url = ustr8(f->get_url(f));
		char* here = origin_of(url);
		char* want = l->get_size(l) >= 4 ? list_str(l, 0) : strdup("");
		if (!f->is_main(f) || !here[0] || strcmp(here, want) != 0) {
			/* the second check, in the renderer that would run it */
			status = PB_FILL_ORIGIN_CHANGED;
		} else if (s && l->get_size(l) >= 4) {
			af_unpark(s);
			for (int i = 0; i < 4; i++) s->parked[i] = list_str(l, (size_t)i);
			s->status = PB_FILL_FAILED;
			cef_v8_context_t* ctx = f->get_v8_context(f);
			if (ctx && ctx->is_valid(ctx)) {
				char js[160];
				snprintf(js, sizeof js, "dispatchEvent(new Event('%s'))", s->wake);
				cef_string_t code = {0}, src_url = {0};
				set16(&code, js);
				set16(&src_url, "palm-autofill:");
				cef_v8_value_t* ret = NULL;
				cef_v8_exception_t* ex = NULL;
				ctx->eval(ctx, &code, &src_url, 1, &ret, &ex);
				rel(ret);
				rel(ex);
				cef_string_clear(&code);
				cef_string_clear(&src_url);
				status = s->status;
			}
			rel(ctx);
			af_unpark(s);
		}
		af_answer(f, status);
		free(url);
		free(here);
		free(want);
		rel(l);
	}
	free(name);
	rel(msg);
	rel(f);
	rel(b);
	return handled;
}

static cef_render_process_handler_t g_rph;
static cef_render_process_handler_t* CEF_CALLBACK app_get_render_process_handler(cef_app_t* self) {
	(void)self;
	return &g_rph;
}
static void init_render_side(void) {
	init_static(&g_af_report.base, sizeof g_af_report);
	g_af_report.execute = af_report;
	init_static(&g_rph.base, sizeof g_rph);
	g_rph.on_context_created = rp_on_context_created;
	g_rph.on_process_message_received = rp_on_process_message_received;
}

/* Chromium's own password manager and form autofill are off: the vault is
 * the only place a password is kept. These are the profile preferences
 * Chromium's PasswordManagerClient and autofill read (not just the UI), set
 * on the global request context, which persists them in the profile's
 * Preferences file. The tests grep the profile afterwards for every
 * credential they used. */
static void disable_password_storage(void) {
	cef_request_context_t* rc = cef_request_context_get_global_context();
	if (!rc) return;
	cef_preference_manager_t* pm = &rc->base;
	const char* names[] = {
		"credentials_enable_service",     /* the password manager saves and fills */
		"credentials_enable_autosignin",  /* ... and signs in on its own */
		"profile.password_manager_enabled",
		"autofill.profile_enabled",       /* addresses, and the single-field form history */
		"autofill.credit_card_enabled",
	};
	for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
		cef_string_t n = {0}, err = {0};
		set16(&n, names[i]);
		if (pm->has_preference(pm, &n) && pm->can_set_preference(pm, &n)) {
			cef_value_t* val = cef_value_create();
			val->set_bool(val, 0);
			if (!pm->set_preference(pm, &n, val, &err)) {
				char* e = str8(&err);
				logf_("could not turn off %s: %s", names[i], e);
				free(e);
			} else {
				VLOG("turned off %s", names[i]);
			}
		} else {
			VLOG("preference %s is not here", names[i]);
		}
		cef_string_clear(&n);
		cef_string_clear(&err);
	}
	pm->base.release(&pm->base);
}

static void add_switch(cef_command_line_t* cl, const char* name, const char* value) {
	cef_string_t n = {0};
	set16(&n, name);
	if (value) {
		cef_string_t v = {0};
		set16(&v, value);
		cl->append_switch_with_value(cl, &n, &v);
		cef_string_clear(&v);
	} else {
		cl->append_switch(cl, &n);
	}
	cef_string_clear(&n);
}

static void CEF_CALLBACK app_on_before_command_line_processing(cef_app_t* self, const cef_string_t* type, cef_command_line_t* cl) {
	(void)self;
	if (!type || type->length == 0) {
		/* No X11, no Wayland: CEF draws into memory and we ship the pixels. */
		const char* oz = getenv("PALM_BROWSER_OZONE");
		if (!oz) oz = "headless";
		if (oz[0]) add_switch(cl, "ozone-platform", oz);
		/* Chromium's password manager is off (disable_password_storage) and
		 * the vault keeps passwords. "basic" keeps Chromium from looking for a
		 * GNOME keyring or KWallet for anything else it would encrypt (the
		 * cookie key): Palmy has neither. */
		add_switch(cl, "password-store", "basic");
		/* Test mode for the autofill tests' local HTTPS site: trust exactly
		 * the certificate whose public key hash is named (base64 SHA-256 of
		 * its SubjectPublicKeyInfo), nothing else. */
		const char* spki = getenv("PALM_BROWSER_TEST_SPKI");
		if (spki && spki[0]) {
			logf_("TEST MODE: trusting the certificate with SPKI hash %s (PALM_BROWSER_TEST_SPKI)", spki);
			add_switch(cl, "ignore-certificate-errors-spki-list", spki);
		}
		/* On a new profile Chromium's first-run code shows an EULA dialog and
		 * waits for it in a nested message loop; with no window system that
		 * dialog never appears and cef_initialize() never returns. Found with
		 * gdb against the unstripped libcef: ShowEulaDialog() under
		 * PreMainMessageLoopRun. */
		add_switch(cl, "no-first-run", NULL);
		add_switch(cl, "no-default-browser-check", NULL);
		add_switch(cl, "use-mock-keychain", NULL);
		/* Without dmabuf there is nothing to gain from GPU compositing in an
		 * off-screen view; WebGL still runs, on SwiftShader if need be. */
		add_switch(cl, "disable-gpu-compositing", NULL);
		const char* gpu = getenv("PALM_BROWSER_GPU");
		if (!gpu || strcmp(gpu, "1") != 0) add_switch(cl, "disable-gpu", NULL);
		const char* extra = getenv("PALM_BROWSER_CEF_LANG");
		if (extra && extra[0]) add_switch(cl, "lang", extra);
	}
	rel(cl);
}

/* ------------------------------------------------------------------------
 * main
 * ---------------------------------------------------------------------- */

static const char* arg_value(int argc, char** argv, const char* name) {
	size_t n = strlen(name);
	for (int i = 1; i < argc; i++) {
		if (strncmp(argv[i], name, n) == 0 && argv[i][n] == '=') return argv[i] + n + 1;
		if (strcmp(argv[i], name) == 0 && i + 1 < argc) return argv[i + 1];
	}
	return NULL;
}

static char* exe_dir(void) {
	char buf[PATH_MAX];
	ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
	if (n <= 0) return strdup(".");
	buf[n] = 0;
	char* slash = strrchr(buf, '/');
	if (slash) *slash = 0;
	return strdup(buf);
}

static int dir_exists(const char* p) {
	struct stat st;
	return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

/* The socket reader: everything it receives runs later on the UI thread. On
 * hang-up it asks the UI thread to close every browser, and gives that four
 * seconds before leaving regardless -- a host must never outlive its chrome. */
static void* reader(void* arg) {
	(void)arg;
	for (;;) {
		uint32_t size;
		uint8_t hdr[8];
		size_t got = 0;
		while (got < 8) {
			ssize_t n = recv(g_sock, hdr + got, 8 - got, 0);
			if (n <= 0) {
				if (n < 0 && errno == EINTR) continue;
				goto done;
			}
			got += (size_t)n;
		}
		memcpy(&size, hdr, 4);
		if (size < 8 || size > (64u << 20)) {
			logf_("bad message size %u", size);
			goto done;
		}
		uint8_t* data = malloc(size);
		memcpy(data, hdr, 8);
		while (got < size) {
			ssize_t n = recv(g_sock, data + got, size - got, 0);
			if (n <= 0) {
				if (n < 0 && errno == EINTR) continue;
				free(data);
				goto done;
			}
			got += (size_t)n;
		}
		uint16_t op;
		memcpy(&op, data + 4, 2);
		post(data, size);
		if (op == PB_QUIT) break;
	}
done:
	{
		uint8_t* q = malloc(8);
		uint32_t sz = 8;
		uint16_t op = PB_QUIT, view = 0;
		memcpy(q, &sz, 4);
		memcpy(q + 4, &op, 2);
		memcpy(q + 6, &view, 2);
		post(q, 8);
	}
	sleep(4);
	logf_("browsers did not close in time; leaving without cef_shutdown");
	_exit(0);
	return NULL;
}

int main(int argc, char** argv) {
	/* The API version this file was written against; CEF checks it. */
	cef_api_hash(CEF_API_VERSION, 0);

	/* No session bus. Nothing an off-screen view needs lives there --
	 * Palmy does not run one -- and on a desktop that does, Chromium
	 * would read the colour scheme and other settings from the desktop's
	 * portal instead of from the chrome. PALM_BROWSER_KEEP_DBUS=1 keeps it
	 * (MPRIS media keys, notifications). */
	if (!getenv("PALM_BROWSER_KEEP_DBUS")) unsetenv("DBUS_SESSION_BUS_ADDRESS");

	/* Without a system fontconfig, use the package's own (a Palmy image
	 * has fonts but, so far, no /etc/fonts). */
	if (access("/etc/fonts/fonts.conf", R_OK) != 0 && !getenv("FONTCONFIG_FILE")) {
		char* d = exe_dir();
		char fc[PATH_MAX];
		snprintf(fc, sizeof fc, "%s/fonts.conf", d);
		if (access(fc, R_OK) == 0) setenv("FONTCONFIG_FILE", fc, 1);
		free(d);
	}

	/* A parent may start us with stdin closed. Then our socket would be fd 0,
	 * and Chromium, which points the standard descriptors at /dev/null during
	 * startup, would quietly replace it. Fill 0..2 first. */
	for (;;) {
		int fd = open("/dev/null", O_RDWR | O_CLOEXEC);
		if (fd < 0) break;
		if (fd > 2) {
			close(fd);
			break;
		}
		/* keep it: it now occupies a standard slot (without CLOEXEC there) */
		fcntl(fd, F_SETFD, 0);
	}

	memset(&g_app, 0, sizeof g_app);
	init_static(&g_app.base, sizeof g_app);
	g_app.on_before_command_line_processing = app_on_before_command_line_processing;
	g_app.get_render_process_handler = app_get_render_process_handler;
	init_render_side();

	cef_main_args_t args = {argc, argv};
	int code = cef_execute_process(&args, &g_app, NULL);
	if (code >= 0) return code; /* a renderer, GPU or utility process finished */

	g_verbose = getenv("PALM_BROWSER_VERBOSE") != NULL;
	const char* sock = arg_value(argc, argv, "--socket");
	const char* profile = arg_value(argc, argv, "--profile");
	const char* downloads = arg_value(argc, argv, "--downloads");
	if (arg_value(argc, argv, "--version") || (argc > 1 && strcmp(argv[1], "--version") == 0)) {
		printf("palm-browser-cef %s (chromium %d.%d.%d.%d)\n", CEF_VERSION, CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR,
		       CHROME_VERSION_BUILD, CHROME_VERSION_PATCH);
		return 0;
	}
	if (!sock || !profile) {
		fprintf(stderr, "usage: palm-browser-cef --socket PATH --profile DIR [--downloads DIR]\n");
		return 2;
	}
	g_profile = strdup(profile);
	if (downloads) {
		g_downloads = strdup(downloads);
	} else {
		char p[PATH_MAX];
		snprintf(p, sizeof p, "%s/Downloads", getenv("HOME") ? getenv("HOME") : "/tmp");
		g_downloads = strdup(p);
	}

	g_sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	struct sockaddr_un sa = {.sun_family = AF_UNIX};
	snprintf(sa.sun_path, sizeof sa.sun_path, "%s", sock);
	if (connect(g_sock, (struct sockaddr*)&sa, sizeof sa) < 0) {
		logf_("cannot connect to %s: %s", sock, strerror(errno));
		return 6;
	}

	char* dir = exe_dir();
	char path[PATH_MAX];
	cef_settings_t s = {0};
	s.size = sizeof s;
	s.windowless_rendering_enabled = 1;
	s.persist_session_cookies = 1;
	s.log_severity = g_verbose ? LOGSEVERITY_INFO : LOGSEVERITY_ERROR;
	s.background_color = 0xffffffff;
	const char* nosb = getenv("PALM_BROWSER_NO_SANDBOX");
	s.no_sandbox = nosb && strcmp(nosb, "1") == 0;
	if (s.no_sandbox) logf_("running WITHOUT Chromium's sandbox (PALM_BROWSER_NO_SANDBOX=1)");
	mkdir(profile, 0700);
	snprintf(path, sizeof path, "%s/cef", profile);
	mkdir(path, 0700);
	set16(&s.root_cache_path, path);
	set16(&s.cache_path, path);
	snprintf(path, sizeof path, "%s/cef.log", profile);
	set16(&s.log_file, path);
	/* resources sit next to the binary (the package layout), or in CEF's own
	 * Resources directory when running from an unpacked distribution */
	const char* res = getenv("PALM_BROWSER_CEF_RESOURCES");
	if (!res) {
		snprintf(path, sizeof path, "%s/locales", dir);
		res = dir_exists(path) ? dir : NULL;
	}
	if (res) {
		set16(&s.resources_dir_path, res);
		snprintf(path, sizeof path, "%s/locales", res);
		set16(&s.locales_dir_path, path);
	}
	set16(&s.accept_language_list, getenv("PALM_BROWSER_LANGS") ? getenv("PALM_BROWSER_LANGS") : "en-US,en");

	VLOG("initializing CEF");
	if (!cef_initialize(&args, &s, &g_app, NULL)) {
		logf_("cef_initialize failed (see %s/cef.log)", profile);
		return 7;
	}

	VLOG("initialized; socket fd %d", g_sock);
	disable_password_storage();
	Buf hello = msg_begin(PB_HELLO, 0);
	put_str(&hello, "chromium");
	char ver[128];
	snprintf(ver, sizeof ver, "%d.%d.%d.%d (CEF %s)", CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR, CHROME_VERSION_BUILD,
	         CHROME_VERSION_PATCH, CEF_VERSION);
	put_str(&hello, ver);
	msg_send(&hello);
	VLOG("hello sent");

	/* CEF's message loop runs on this thread; a second one reads the socket */
	pthread_t rt;
	pthread_create(&rt, NULL, reader, NULL);
	pthread_detach(rt);
	cef_run_message_loop();
	VLOG("message loop ended");
	cef_shutdown();
	return 0;
}
