/*
 * The engine protocol: how the browser's chrome (apps/browser, palmy + shadcn)
 * talks to the process that actually renders web pages.
 *
 * The chrome never links an engine. It starts an *engine host* -- a separate
 * process, one per window -- and speaks this protocol to it over a Unix
 * stream socket. Two hosts implement it:
 *
 *   palm-browser-cef     Blink, through CEF's off-screen rendering (C, here)
 *   palm-browser-gecko   Gecko, by running Firefox as a client of a small
 *                        private Wayland compositor and steering it with
 *                        WebDriver BiDi (Odin, engine/gecko)
 *
 * apps/browser/proto.odin is the Odin mirror of this file; the two are kept in
 * step by hand and checked by `browser --selftest`, which round-trips every
 * message through the encoder and decoder.
 *
 * Framing. Every message is
 *
 *     u32 size     total bytes, header included
 *     u16 op       one of the constants below
 *     u16 view     the tab it concerns; 0 for the host as a whole
 *
 * followed by the payload, little-endian, packed, no padding. A string is a
 * u32 byte length followed by that many bytes of UTF-8, not terminated.
 *
 * Frames. A view's pixels live in a shared-memory buffer the *host* creates
 * (memfd) and hands over once with BUFFER, the fd riding in an SCM_RIGHTS
 * control message on that same sendmsg. Pixels are 32-bit 0xAARRGGBB words
 * (BGRA bytes), row-major, `stride` bytes per row, in device pixels -- the
 * same format palmy's rasterizer writes, so the chrome blits rows without
 * converting. FRAME then says which rectangles changed. The chrome copies
 * them out and answers FRAME_ACK; until it does, the host must not touch the
 * buffer, and keeps accumulating damage instead. One frame in flight, no
 * tearing, no locks.
 */
#ifndef PALM_BROWSER_PROTO_H
#define PALM_BROWSER_PROTO_H

#define PB_VERSION 1

/* chrome -> host */
enum {
	PB_HELLO_APP = 1,      /* u32 version, str profile_dir, str downloads_dir, str keymap */
	PB_CREATE = 2,         /* i32 w, i32 h, f32 scale, str url */
	PB_CLOSE = 3,          /* - */
	PB_NAVIGATE = 4,       /* str url */
	PB_HISTORY = 5,        /* i32 delta (-1 back, +1 forward) */
	PB_RELOAD = 6,         /* u8 bypass_cache */
	PB_STOP = 7,           /* - */
	PB_RESIZE = 8,         /* i32 w, i32 h, f32 scale */
	PB_SHOW = 9,           /* u8 visible */
	PB_FOCUS = 10,         /* u8 focused */
	PB_MOUSE = 11,         /* u8 kind, u8 button, u8 clicks, u8 pad, u32 mods, f32 x, f32 y */
	PB_WHEEL = 12,         /* u32 mods, f32 x, f32 y, f32 dx, f32 dy */
	PB_KEY = 13,           /* u8 kind, u8 pad[3], u32 mods, u32 keysym, u32 codepoint */
	PB_FRAME_ACK = 14,     /* - */
	PB_ZOOM = 15,          /* f32 factor (1.0 = 100%) */
	PB_DIALOG_REPLY = 16,  /* u32 id, u8 ok, str text */
	PB_FIND = 17,          /* u8 forward, u8 next, str text (empty: stop) */
	PB_DOWNLOAD_CANCEL = 18, /* u32 id */
	PB_QUIT = 19,          /* - */
	PB_MENU_REPLY = 20,    /* u32 id, i32 command (-1 dismissed) */
	PB_EDIT = 21,          /* u8 action (PB_EDIT_*), str text (for INSERT) */
};

/* host -> chrome */
enum {
	PB_HELLO = 100,        /* str engine, str version */
	PB_BUFFER = 101,       /* i32 w, i32 h, i32 stride  + one fd (SCM_RIGHTS) */
	PB_FRAME = 102,        /* u32 n, then n x (i32 x, i32 y, i32 w, i32 h) */
	PB_TITLE = 103,        /* str */
	PB_URL = 104,          /* str */
	PB_FAVICON = 105,      /* str url, u32 n, n bytes of PNG (n may be 0) */
	PB_LOAD = 106,         /* u8 loading, u8 can_back, u8 can_forward */
	PB_PROGRESS = 107,     /* f32 0..1 */
	PB_CURSOR = 108,       /* u8 PB_CURSOR_* */
	PB_OPEN_TAB = 109,     /* u8 foreground, str url */
	PB_DIALOG = 110,       /* u32 id, u8 kind, str message, str default_text */
	PB_DOWNLOAD = 111,     /* u32 id, u8 state, i64 received, i64 total, str url, str path, str mime */
	PB_STATUS = 112,       /* str (hovered link, "" to clear) */
	PB_CRASHED = 113,      /* str reason */
	PB_FIND_RESULT = 114,  /* i32 count, i32 active */
	PB_READY = 115,        /* - the view exists */
	PB_LOG = 116,          /* str */
	PB_CLOSED = 117,       /* - the page closed itself (window.close) */
	PB_LOAD_ERROR = 118,   /* i32 code, str text, str url */
	PB_MENU = 119,         /* u32 id, f32 x, f32 y, str link, str selection, str src, u8 editable,
	                          u32 n, n x (i32 command, u8 kind, u8 enabled, str label) */
	PB_SELECTION = 120,    /* str: the page's current text selection */
};

enum { PB_MOUSE_MOVE = 0, PB_MOUSE_DOWN = 1, PB_MOUSE_UP = 2, PB_MOUSE_LEAVE = 3 };
enum { PB_BUTTON_LEFT = 0, PB_BUTTON_MIDDLE = 1, PB_BUTTON_RIGHT = 2 };
enum { PB_KEY_DOWN = 0, PB_KEY_UP = 1, PB_KEY_CHAR = 2 };

/* modifier bits, as palmy's Modifier enum orders them */
enum { PB_MOD_SHIFT = 1, PB_MOD_CTRL = 2, PB_MOD_ALT = 4, PB_MOD_SUPER = 8 };

enum { PB_DIALOG_ALERT = 0, PB_DIALOG_CONFIRM = 1, PB_DIALOG_PROMPT = 2, PB_DIALOG_BEFOREUNLOAD = 3 };
enum { PB_DL_PROGRESS = 0, PB_DL_DONE = 1, PB_DL_CANCELLED = 2, PB_DL_FAILED = 3 };
enum { PB_MENU_ITEM = 0, PB_MENU_SEPARATOR = 1, PB_MENU_CHECKED = 2 };
enum { PB_EDIT_UNDO = 0, PB_EDIT_REDO = 1, PB_EDIT_CUT = 2, PB_EDIT_COPY = 3, PB_EDIT_PASTE = 4,
       PB_EDIT_SELECT_ALL = 5, PB_EDIT_INSERT = 6 };

enum {
	PB_CURSOR_DEFAULT = 0,
	PB_CURSOR_POINTER = 1,
	PB_CURSOR_TEXT = 2,
	PB_CURSOR_WAIT = 3,
	PB_CURSOR_CROSSHAIR = 4,
	PB_CURSOR_MOVE = 5,
	PB_CURSOR_NOT_ALLOWED = 6,
	PB_CURSOR_GRAB = 7,
	PB_CURSOR_EW_RESIZE = 8,
	PB_CURSOR_NS_RESIZE = 9,
	PB_CURSOR_NONE = 10,
};

#endif
