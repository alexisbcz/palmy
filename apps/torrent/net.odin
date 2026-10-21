package main

// Sockets, and the gate that keeps this program off the internet.
//
// SAFETY GATE
//
// A BitTorrent client is, by design, a thing that connects to strangers. This
// one cannot. There are exactly three places in this program that create an
// outbound connection or send a datagram:
//
//     sock_connect        (TCP: trackers and peers)
//     udp_send_to         (UDP: BEP 15 trackers)
//     sock_listen         (inbound: binds the listening socket)
//
// All three funnel their address through `loopback_address`, which parses an
// IPv4 dotted quad and refuses anything outside 127.0.0.0/8. There is NO name
// resolution anywhere in this program: `localhost` is mapped to 127.0.0.1 by a
// string comparison and every other hostname is refused without a lookup. So
// `tracker.opentrackr.org` is not "blocked at the firewall" — it is refused
// before a DNS packet could exist, and the same is true of a routable IP that
// arrives inside a compact peer list from a tracker.
//
// `sock_listen` additionally refuses 0.0.0.0 and ::. The seeder and leecher in
// the end-to-end test bind 127.0.0.1 and are unreachable from the network.
//
// Every allowed and every refused endpoint is recorded in `net_audit`, so the
// selftest can print the complete list of addresses the process touched and a
// reader can check by eye that all of them are loopback.
//
// There is no DHT, no peer exchange, no local service discovery, no UPnP and no
// NAT-PMP in this program, and not because they were left for later: each of
// them is a way to learn an address from a stranger, and this client is not
// allowed to have one.

import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import p "palmy:."

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------

// loopback_address parses `host` as an IPv4 literal and insists on 127/8.
//
// It does not resolve names, and it never will. The two `localhost` spellings
// are special-cased by literal string comparison because a loopback service is
// routinely written that way; everything else that is not four decimal octets
// is refused.
loopback_address :: proc(host: string) -> (addr: [4]u8, err: string) {
	h := strings.trim_space(host)
	if h == "localhost" || h == "localhost.localdomain" {
		return {127, 0, 0, 1}, ""
	}
	if h == "" {
		return {}, "refusing to connect to an empty host"
	}
	// Reject anything that is not exactly four decimal octets. In particular a
	// name that merely *contains* a loopback literal — "127.0.0.1.evil.com" —
	// has more than four parts and is refused here, and an IPv6 literal has no
	// dots at all.
	parts := strings.split(h, ".", context.temp_allocator)
	if len(parts) != 4 {
		return {}, tsprint(
			"refusing to contact %q: this client speaks only to IPv4 loopback and does not resolve names",
			host,
		)
	}
	out: [4]u8
	for part, i in parts {
		if len(part) == 0 || len(part) > 3 {
			return {}, tsprint("refusing to contact %q: not an IPv4 literal", host)
		}
		for c in transmute([]u8)part {
			if c < '0' || c > '9' {
				return {}, tsprint("refusing to contact %q: not an IPv4 literal", host)
			}
		}
		v, ok := strconv.parse_int(part, 10)
		if !ok || v < 0 || v > 255 {
			return {}, tsprint("refusing to contact %q: not an IPv4 literal", host)
		}
		out[i] = u8(v)
	}
	if out[0] != 127 {
		return {}, tsprint(
			"refusing to contact %q: %d.%d.%d.%d is not loopback. This client never contacts a real tracker, peer or DHT node.",
			host,
			out[0],
			out[1],
			out[2],
			out[3],
		)
	}
	return out, ""
}

ip4_string :: proc(a: [4]u8, allocator := context.allocator) -> string {
	return asprint("%d.%d.%d.%d", a[0], a[1], a[2], a[3])
}

// ---------------------------------------------------------------------------
// The audit log
// ---------------------------------------------------------------------------

Net_Event :: struct {
	what:    string, // "tcp-connect", "udp-send", "listen", "accept"
	host:    string,
	port:    int,
	allowed: bool,
	reason:  string,
}

@(private = "file")
audit_mu: sync.Mutex
@(private = "file")
audit: [dynamic]Net_Event

net_audit_record :: proc(what, host: string, port: int, allowed: bool, reason: string) {
	sync.lock(&audit_mu)
	defer sync.unlock(&audit_mu)
	if audit == nil {
		audit = make([dynamic]Net_Event, 0, 64)
	}
	// A client announcing every 30 seconds to the same tracker for an hour
	// should not grow this without bound; collapse the repeats.
	for &e in audit {
		if e.what == what && e.host == host && e.port == port && e.allowed == allowed {
			return
		}
	}
	append(
		&audit,
		Net_Event {
			what = strings.clone(what),
			host = strings.clone(host),
			port = port,
			allowed = allowed,
			reason = strings.clone(reason),
		},
	)
}

net_audit_snapshot :: proc(allocator := context.allocator) -> []Net_Event {
	sync.lock(&audit_mu)
	defer sync.unlock(&audit_mu)
	out := make([]Net_Event, len(audit), allocator)
	copy(out, audit[:])
	return out
}

// net_audit_all_loopback is the property the whole task rests on: every
// endpoint this process ever touched was in 127/8.
net_audit_all_loopback :: proc() -> (ok: bool, offender: string) {
	sync.lock(&audit_mu)
	defer sync.unlock(&audit_mu)
	for e in audit {
		if !e.allowed {
			continue // refused, so nothing was contacted
		}
		a, err := loopback_address(e.host)
		if err != "" || a[0] != 127 {
			return false, e.host
		}
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Sockets
// ---------------------------------------------------------------------------

AF_INET :: linux.Address_Family(linux.Protocol_Family.INET)

Sock :: distinct linux.Fd

SOCK_INVALID :: Sock(-1)

@(private = "file")
sockaddr_in :: proc(addr: [4]u8, port: int) -> linux.Sock_Addr_In {
	return linux.Sock_Addr_In {
		sin_family = AF_INET,
		sin_port = u16be(u16(port)),
		sin_addr = addr,
	}
}

sock_set_nonblocking :: proc(s: Sock) {
	flags, _ := linux.fcntl_getfl(linux.Fd(s), .GETFL)
	flags += {.NONBLOCK}
	linux.fcntl_setfl(linux.Fd(s), .SETFL, flags)
}

sock_set_nodelay :: proc(s: Sock) {
	one: i32 = 1
	// Nagle on a request/piece protocol adds latency for no benefit: the
	// messages are already batched into one write.
	linux.setsockopt_base(linux.Fd(s), 6 /* SOL_TCP */, 1 /* TCP_NODELAY */, &one)
}

// sock_connect is the ONLY outbound TCP call site in this program.
//
// It is synchronous, which is correct here and only here: the only addresses it
// will accept are on the loopback interface, where `connect` either completes
// in the kernel immediately or fails immediately. The socket is switched to
// non-blocking afterwards, because the peer protocol is driven from `poll`.
sock_connect :: proc(host: string, port: int) -> (s: Sock, err: string) {
	addr, gate := loopback_address(host)
	if gate != "" {
		net_audit_record("tcp-connect", host, port, false, gate)
		return SOCK_INVALID, gate
	}
	if port <= 0 || port > 65535 {
		return SOCK_INVALID, tsprint("implausible port %d", port)
	}
	net_audit_record("tcp-connect", host, port, true, "")

	fd, serr := linux.socket(AF_INET, .STREAM, {.CLOEXEC}, .TCP)
	if serr != .NONE {
		return SOCK_INVALID, tsprint("socket: %v", serr)
	}
	sa := sockaddr_in(addr, port)
	if cerr := linux.connect(linux.Fd(fd), &sa); cerr != .NONE {
		linux.close(fd)
		return SOCK_INVALID, tsprint("connect %s:%d: %v", host, port, cerr)
	}
	s = Sock(fd)
	sock_set_nonblocking(s)
	sock_set_nodelay(s)
	return s, ""
}

// sock_listen binds a listening socket. It refuses to bind anything but
// loopback, so `0.0.0.0` — the default every other client uses — is an error
// here. `port == 0` asks the kernel for an ephemeral port, which is returned.
sock_listen :: proc(host: string, port: int, backlog: i32 = 64) -> (s: Sock, bound: int, err: string) {
	addr, gate := loopback_address(host)
	if gate != "" {
		net_audit_record("listen", host, port, false, gate)
		return SOCK_INVALID, 0, tsprint("refusing to listen on %q: %s", host, gate)
	}
	if port < 0 || port > 65535 {
		return SOCK_INVALID, 0, tsprint("implausible port %d", port)
	}

	fd, serr := linux.socket(AF_INET, .STREAM, {.CLOEXEC}, .TCP)
	if serr != .NONE {
		return SOCK_INVALID, 0, tsprint("socket: %v", serr)
	}
	one: i32 = 1
	linux.setsockopt_base(fd, 1 /* SOL_SOCKET */, 2 /* SO_REUSEADDR */, &one)

	sa := sockaddr_in(addr, port)
	if berr := linux.bind(fd, &sa); berr != .NONE {
		linux.close(fd)
		return SOCK_INVALID, 0, tsprint("bind %s:%d: %v", host, port, berr)
	}
	if lerr := linux.listen(fd, backlog); lerr != .NONE {
		linux.close(fd)
		return SOCK_INVALID, 0, tsprint("listen: %v", lerr)
	}
	got: linux.Sock_Addr_Any
	if linux.getsockname(fd, &got) == .NONE {
		bound = int(u16(got.ipv4.sin_port))
	} else {
		bound = port
	}
	net_audit_record("listen", host, bound, true, "")
	s = Sock(fd)
	sock_set_nonblocking(s)
	return s, bound, ""
}

// sock_accept takes one pending connection. The kernel hands back the peer's
// address; it is on the loopback interface by construction, because that is the
// only interface the listening socket is bound to, and it is checked anyway.
sock_accept :: proc(l: Sock) -> (s: Sock, host: string, port: int, ok: bool) {
	sa: linux.Sock_Addr_In
	fd, aerr := linux.accept(linux.Fd(l), &sa, {.CLOEXEC})
	if aerr != .NONE {
		return SOCK_INVALID, "", 0, false
	}
	h := ip4_string(sa.sin_addr)
	p := int(u16(sa.sin_port))
	if _, gate := loopback_address(h); gate != "" {
		// Cannot happen while the listener is bound to 127.0.0.1, and is
		// dropped rather than trusted if it ever does.
		net_audit_record("accept", h, p, false, gate)
		linux.close(fd)
		return SOCK_INVALID, "", 0, false
	}
	net_audit_record("accept", h, p, true, "")
	s = Sock(fd)
	sock_set_nonblocking(s)
	sock_set_nodelay(s)
	return s, h, p, true
}

sock_close :: proc(s: Sock) {
	if s != SOCK_INVALID {
		linux.close(linux.Fd(s))
	}
}

Io_Status :: enum {
	Ok, // bytes moved
	Again, // would block; try when poll says so
	Closed, // orderly shutdown by the peer
	Error,
}

sock_read :: proc(s: Sock, buf: []u8) -> (n: int, st: Io_Status) {
	if len(buf) == 0 {
		return 0, .Ok
	}
	got, err := linux.read(linux.Fd(s), buf)
	if err == .EAGAIN || err == .EINTR {
		return 0, .Again
	}
	if err != .NONE {
		return 0, .Error
	}
	if got == 0 {
		return 0, .Closed
	}
	return got, .Ok
}

sock_write :: proc(s: Sock, buf: []u8) -> (n: int, st: Io_Status) {
	if len(buf) == 0 {
		return 0, .Ok
	}
	// MSG_NOSIGNAL (0x4000) so a peer that vanished mid-write does not kill the
	// process with SIGPIPE.
	put, err := linux.send(linux.Fd(s), buf, {.NOSIGNAL})
	if err == .EAGAIN || err == .EINTR {
		return 0, .Again
	}
	if err != .NONE {
		return 0, .Error
	}
	return put, .Ok
}

// ---------------------------------------------------------------------------
// UDP, for the BEP 15 tracker protocol
// ---------------------------------------------------------------------------

Udp :: struct {
	fd:    linux.Fd,
	bound: int,
}

udp_open :: proc(u: ^Udp, host := "127.0.0.1", port := 0) -> (err: string) {
	addr, gate := loopback_address(host)
	if gate != "" {
		net_audit_record("udp-bind", host, port, false, gate)
		return tsprint("refusing to bind UDP on %q: %s", host, gate)
	}
	fd, serr := linux.socket(AF_INET, .DGRAM, {.CLOEXEC}, .UDP)
	if serr != .NONE {
		return tsprint("udp socket: %v", serr)
	}
	sa := sockaddr_in(addr, port)
	if berr := linux.bind(fd, &sa); berr != .NONE {
		linux.close(fd)
		return tsprint("udp bind %s:%d: %v", host, port, berr)
	}
	got: linux.Sock_Addr_Any
	if linux.getsockname(fd, &got) == .NONE {
		u.bound = int(u16(got.ipv4.sin_port))
	} else {
		u.bound = port
	}
	u.fd = fd
	net_audit_record("udp-bind", host, u.bound, true, "")
	return ""
}

udp_close :: proc(u: ^Udp) {
	if u.fd != 0 {
		linux.close(u.fd)
		u.fd = 0
	}
}

// udp_send_to is the ONLY outbound datagram call site in this program.
udp_send_to :: proc(u: ^Udp, host: string, port: int, data: []u8) -> (err: string) {
	addr, gate := loopback_address(host)
	if gate != "" {
		net_audit_record("udp-send", host, port, false, gate)
		return gate
	}
	if port <= 0 || port > 65535 {
		return tsprint("implausible port %d", port)
	}
	net_audit_record("udp-send", host, port, true, "")
	sa := sockaddr_in(addr, port)
	_, serr := linux.sendto(u.fd, data, {}, &sa)
	if serr != .NONE {
		return tsprint("udp sendto %s:%d: %v", host, port, serr)
	}
	return ""
}

udp_recv :: proc(
	u: ^Udp,
	buf: []u8,
	timeout_ms: i32,
) -> (
	n: int,
	host: string,
	port: int,
	ok: bool,
) {
	if timeout_ms >= 0 {
		fds := [1]linux.Poll_Fd{{fd = u.fd, events = {.IN}}}
		got, perr := linux.poll(fds[:], timeout_ms)
		if perr != .NONE || got <= 0 {
			return 0, "", 0, false
		}
	}
	sa: linux.Sock_Addr_In
	rn, rerr := linux.recvfrom(u.fd, buf, {}, &sa)
	if rerr != .NONE || rn <= 0 {
		return 0, "", 0, false
	}
	return rn, ip4_string(sa.sin_addr), int(u16(sa.sin_port)), true
}

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------

// p.poll_fds rather than linux.poll, whose arm64/riscv64 build fails a
// negative timeout with EINVAL instead of waiting forever.
poll_wait :: proc(fds: []linux.Poll_Fd, timeout_ms: i32) -> int {
	n, err := p.poll_fds(fds, int(timeout_ms))
	if err != .NONE {
		return 0
	}
	return int(n)
}
