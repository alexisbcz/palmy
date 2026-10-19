// The socket under the protocol: blocking sends (with an optional descriptor
// riding in SCM_RIGHTS), and a reader that turns the byte stream back into
// whole messages and pairs each BUFFER with the descriptor that came with it.
package pb

import "core:sync"
import "core:sys/linux"

SOL_SOCKET :: 1
SCM_RIGHTS :: 1

Cmsg_Hdr :: struct {
	len:   uint,
	level: i32,
	type:  i32,
}

Conn :: struct {
	fd:     linux.Fd,
	wlock:  sync.Mutex,
	rx:     [dynamic]u8,
	rx_fds: [dynamic]linux.Fd,
	closed: bool,
}

// send writes one finished message; it is safe from any thread.
send :: proc(c: ^Conn, m: ^Msg, fd: linux.Fd = -1) -> bool {
	bytes := msg_bytes(m)
	defer delete(m.b)
	sync.mutex_lock(&c.wlock)
	defer sync.mutex_unlock(&c.wlock)
	if c.closed {
		return false
	}
	off := 0
	if fd >= 0 {
		ctrl: [size_of(Cmsg_Hdr) + 8]u8
		h := (^Cmsg_Hdr)(&ctrl[0])
		h.len = size_of(Cmsg_Hdr) + 4
		h.level = SOL_SOCKET
		h.type = SCM_RIGHTS
		(^i32)(&ctrl[size_of(Cmsg_Hdr)])^ = i32(fd)
		iov := [1]linux.IO_Vec{{base = raw_data(bytes), len = uint(len(bytes))}}
		hdr := linux.Msg_Hdr {
			iov     = iov[:],
			control = ctrl[:],
		}
		for {
			n, err := linux.sendmsg(c.fd, &hdr, {.NOSIGNAL})
			if err == .EINTR {
				continue
			}
			if err != .NONE {
				c.closed = true
				return false
			}
			off = int(n)
			break
		}
	}
	for off < len(bytes) {
		n, err := linux.send(c.fd, bytes[off:], {.NOSIGNAL})
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			c.closed = true
			return false
		}
		off += int(n)
	}
	return true
}

// recv_one blocks until one whole message has arrived and returns it (header
// included, owned by the caller) with the descriptor that accompanied it, if
// any. ok is false when the peer hung up.
recv_one :: proc(c: ^Conn, allocator := context.allocator) -> (raw: []u8, fd: int, ok: bool) {
	fd = -1
	for {
		if len(c.rx) >= 8 {
			size := int((^u32)(raw_data(c.rx))^)
			if size < 8 || size > 64 << 20 {
				return nil, -1, false
			}
			if len(c.rx) >= size {
				raw = make([]u8, size, allocator)
				copy(raw, c.rx[:size])
				remove_range(&c.rx, 0, size)
				op := Op((^u16)(&raw[4])^)
				if op == .Buffer && len(c.rx_fds) > 0 {
					fd = int(c.rx_fds[0])
					ordered_remove(&c.rx_fds, 0)
				}
				return raw, fd, true
			}
		}
		staging: [65536]u8
		ctrl: [256]u8
		iov := [1]linux.IO_Vec{{base = &staging[0], len = len(staging)}}
		hdr := linux.Msg_Hdr {
			iov     = iov[:],
			control = ctrl[:],
		}
		n, err := linux.recvmsg(c.fd, &hdr, {.CMSG_CLOEXEC})
		if err == .EINTR {
			continue
		}
		if err != .NONE || n == 0 {
			c.closed = true
			return nil, -1, false
		}
		append(&c.rx, ..staging[:n])
		off := 0
		for off + size_of(Cmsg_Hdr) <= len(hdr.control) {
			cm := (^Cmsg_Hdr)(raw_data(hdr.control[off:]))
			if cm.len < size_of(Cmsg_Hdr) || off + int(cm.len) > len(hdr.control) {
				break
			}
			if cm.level == SOL_SOCKET && cm.type == SCM_RIGHTS {
				count := (int(cm.len) - size_of(Cmsg_Hdr)) / 4
				for i in 0 ..< count {
					got := (^i32)(raw_data(hdr.control[off + size_of(Cmsg_Hdr) + i * 4:]))^
					append(&c.rx_fds, linux.Fd(got))
				}
			}
			off += (int(cm.len) + 7) & ~int(7)
		}
	}
}

conn_close :: proc(c: ^Conn) {
	sync.mutex_lock(&c.wlock)
	if !c.closed {
		linux.shutdown(c.fd, .RDWR)
	}
	c.closed = true
	sync.mutex_unlock(&c.wlock)
	linux.close(c.fd)
	for f in c.rx_fds {
		linux.close(f)
	}
	delete(c.rx)
	delete(c.rx_fds)
}

// listen_unix makes a listening socket at `path`, replacing a stale one.
listen_unix :: proc(path: string) -> (fd: linux.Fd, ok: bool) {
	sock, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, linux.Protocol(0))
	if err != .NONE {
		return -1, false
	}
	addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	if len(path) >= len(addr.sun_path) {
		linux.close(sock)
		return -1, false
	}
	copy(addr.sun_path[:], path)
	{
		cpath: [256]u8
		copy(cpath[:], path)
		linux.unlink(cstring(&cpath[0]))
	}
	if linux.bind(sock, &addr) != .NONE || linux.listen(sock, 4) != .NONE {
		linux.close(sock)
		return -1, false
	}
	return sock, true
}

connect_unix :: proc(path: string) -> (fd: linux.Fd, ok: bool) {
	sock, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, linux.Protocol(0))
	if err != .NONE {
		return -1, false
	}
	addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	if len(path) >= len(addr.sun_path) {
		linux.close(sock)
		return -1, false
	}
	copy(addr.sun_path[:], path)
	if linux.connect(sock, &addr) != .NONE {
		linux.close(sock)
		return -1, false
	}
	return sock, true
}
