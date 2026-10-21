package palmy_tests

import "core:sys/kqueue"
import "core:sys/linux"
import "core:sys/posix"
import "core:testing"

// frame_loop_test.odin's descriptor on macOS. There is no eventfd; a kqueue
// with one EVFILT_USER event is what palmy's own wake descriptor is there
// (palmy/window_darwin.odin), and poll(2) reports a kqueue readable while an
// event is pending, which is the property both the tests and the frame loop
// stand on.

eventfd :: proc(t: ^testing.T) -> linux.Fd {
	kq, err := kqueue.kqueue()
	testing.expect_value(t, err, posix.Errno.NONE)
	ch := [1]kqueue.KEvent{{ident = 1, filter = .User, flags = {.Add, .Clear}}}
	_, kerr := kqueue.kevent(kq, ch[:], nil, nil)
	testing.expect_value(t, kerr, posix.Errno.NONE)
	return linux.Fd(kq)
}

poke :: proc(fd: linux.Fd) {
	ch := [1]kqueue.KEvent{{ident = 1, filter = .User}}
	ch[0].fflags.user = {.Trigger}
	kqueue.kevent(posix.FD(fd), ch[:], nil, nil)
}

close_fd :: proc(fd: linux.Fd) {
	posix.close(posix.FD(fd))
}
