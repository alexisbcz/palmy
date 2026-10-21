// Drag and drop on Wayland, both ends, against a fake compositor: the requests
// palmy sends are decoded and checked, and the bytes really travel through
// pipes passed over SCM_RIGHTS. The live run (two palmy windows on headless
// sway, a virtual pointer dragging from one to the other) is in the commit
// that added palmy/dnd.odin.
package palmy_tests

import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import p "../palmy"

@(private = "file")
OFFER :: u32(0xff00_0001)
@(private = "file")
TEXT :: "text/plain;charset=utf-8"

@(private = "file")
Rig :: struct {
	app: ^p.App,
	f:   ^Fake_Wl,
	ui:  ^p.Ctx,
}

@(private = "file")
rig_open :: proc() -> Rig {
	app := new(p.App)
	f := fake_wl_open(&app.win)
	w := &app.win
	c := &w.conn
	w.wl.seat = p.new_id(c, .Seat)
	w.wl.surface = p.new_id(c, .Surface)
	w.clip.ddm = p.new_id(c, .Data_Device_Manager)
	w.clip.ddm_ver = 3
	w.clip.device = p.new_id(c, .Data_Device)
	app.ctx.app = app
	app.ctx.alloc = context.allocator
	return {app, f, &app.ctx}
}

@(private = "file")
rig_close :: proc(r: Rig) {
	p.window_close(&r.app.win)
	fake_wl_close(r.f, owns_window = false)
	free(r.app)
}

@(private = "file")
find :: proc(reqs: []Fake_Request, id: u32, opcode: u16) -> (Fake_Request, bool) {
	for r in reqs {
		if r.id == id && r.opcode == opcode {
			return r, true
		}
	}
	return {}, false
}

@(private = "file")
fx :: proc(v: f32) -> p.Fixed {
	return p.Fixed(i32(v * 256))
}

// offer_drag announces an offer with two types and enters the window with it.
@(private = "file")
offer_drag :: proc(r: Rig, x, y: f32) {
	dev := r.app.win.clip.device
	fake_send(r.f, dev, 0, p.Obj(OFFER)) // data_offer
	fake_send(r.f, OFFER, 0, "text/html") // offer
	fake_send(r.f, OFFER, 0, TEXT)
	fake_send(r.f, dev, 1, u32(5), p.Obj(r.app.win.wl.surface), fx(x), fx(y), p.Obj(OFFER)) // enter
	p.window_pump(&r.app.win)
}

// What the compositor would do with a receive: write into the pipe it carried.
@(private = "file")
Server :: struct {
	f:       ^Fake_Wl,
	payload: string,
	mime:    string,
	served:  bool,
}

@(private = "file")
serve_receive :: proc(data: rawptr) {
	s := (^Server)(data)
	deadline := time.time_add(time.now(), 3 * time.Second)
	for time.since(deadline) < 0 && !s.served {
		pfd := [1]linux.Poll_Fd{{fd = s.f.peer.fd, events = {.IN}}}
		p.poll_fds(pfd[:], 50)
		p.conn_read(&s.f.peer)
		rx := &s.f.peer.rx
		at := 0
		for at + 8 <= len(rx) {
			id := (^u32)(raw_data(rx[at:]))^
			hdr := (^u32)(raw_data(rx[at + 4:]))^
			size := int(hdr >> 16)
			if size < 8 || at + size > len(rx) {
				break
			}
			if id == OFFER && hdr & 0xffff == 1 { // receive(mime, fd)
				n := int((^u32)(raw_data(rx[at + 8:]))^)
				s.mime = string(rx[at + 12:][:n - 1])
				if fd, ok := p.take_fd(&s.f.peer); ok {
					linux.write(fd, transmute([]u8)s.payload)
					linux.close(fd)
					s.served = true
				}
			}
			at += size
		}
	}
}

@(test)
test_drop_is_accepted_read_and_finished :: proc(t: ^testing.T) {
	r := rig_open()
	defer rig_close(r)
	p.drop_accept(r.ui, {"image/png", TEXT})

	offer_drag(r, 10, 20)
	reqs := fake_requests(r.f)
	acts, has_acts := find(reqs, OFFER, 4)
	testing.expect(t, has_acts, "set_actions on enter")
	testing.expect_value(t, fake_arg(acts, 0), 3) // copy | move
	acc, has_acc := find(reqs, OFFER, 0)
	testing.expect(t, has_acc, "accept on enter")
	testing.expect_value(t, fake_arg(acc, 0), 5) // the enter's serial
	testing.expect_value(t, fake_arg_string(acc, 1), TEXT)

	pos, types, over := p.drag_over(r.ui)
	testing.expect(t, over)
	testing.expect_value(t, pos, [2]f32{10, 20})
	testing.expect_value(t, len(types), 2)

	fake_send(r.f, r.app.win.clip.device, 3, u32(0), fx(30), fx(40)) // motion
	p.window_pump(&r.app.win)
	pos, _, _ = p.drag_over(r.ui)
	testing.expect_value(t, pos, [2]f32{30, 40})
	_, again := find(fake_requests(r.f), OFFER, 0)
	testing.expect(t, again, "accept again on motion")

	srv := Server{f = r.f, payload = "dropped across windows"}
	th := thread.create_and_start_with_data(&srv, serve_receive)
	fake_send(r.f, r.app.win.clip.device, 4) // drop
	p.window_pump(&r.app.win)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, srv.served, "the drop asked for the bytes")
	testing.expect_value(t, srv.mime, TEXT)

	d, ok := p.dropped(r.ui)
	testing.expect(t, ok, "the drop is handed over")
	testing.expect_value(t, d.data, "dropped across windows")
	testing.expect_value(t, d.mime, TEXT)
	testing.expect_value(t, d.pos, [2]f32{30, 40})
	delete(d.mime)
	delete(d.data)
	_, twice := p.dropped(r.ui)
	testing.expect(t, !twice, "once")

	reqs = fake_requests(r.f)
	_, finished := find(reqs, OFFER, 3)
	testing.expect(t, finished, "finish after reading")
	_, destroyed := find(reqs, OFFER, 2)
	testing.expect(t, destroyed, "and the offer destroyed")
	_, _, over = p.drag_over(r.ui)
	testing.expect(t, !over)
}

// A window that takes nothing says so with a null accept, and a drop on it
// reads nothing.
@(test)
test_drop_refused_without_accepted_types :: proc(t: ^testing.T) {
	r := rig_open()
	defer rig_close(r)
	p.drop_accept(r.ui, {"image/png"})

	offer_drag(r, 5, 5)
	acc, has := find(fake_requests(r.f), OFFER, 0)
	testing.expect(t, has)
	testing.expect_value(t, fake_arg(acc, 1), 0) // a null mime type
	fake_send(r.f, r.app.win.clip.device, 4) // drop
	p.window_pump(&r.app.win)
	_, received := find(fake_requests(r.f), OFFER, 1)
	testing.expect(t, !received, "no receive")
	_, ok := p.dropped(r.ui)
	testing.expect(t, !ok)
}

@(test)
test_drag_source_serves_and_reports :: proc(t: ^testing.T) {
	r := rig_open()
	defer rig_close(r)
	w := &r.app.win

	testing.expect(t, !p.drag_start(r.ui, {TEXT}, {"x"}), "no press, no drag")
	w.wl.press_serial = 9
	testing.expect(t, p.drag_start(r.ui, {TEXT, "text/plain"}, {"payload one", "payload two"}))
	testing.expect(t, p.drag_active(r.ui))
	testing.expect(t, !p.drag_start(r.ui, {TEXT}, {"x"}), "one drag at a time")

	reqs := fake_requests(r.f)
	create, has_create := find(reqs, w.clip.ddm, 0)
	testing.expect(t, has_create)
	src := fake_arg(create, 0)
	start, has_start := find(reqs, w.clip.device, 0)
	testing.expect(t, has_start, "start_drag")
	testing.expect_value(t, fake_arg(start, 0), src)
	testing.expect_value(t, fake_arg(start, 1), w.wl.surface)
	testing.expect_value(t, fake_arg(start, 3), 9)
	acts, has_acts := find(reqs, src, 2)
	testing.expect(t, has_acts)
	testing.expect_value(t, fake_arg(acts, 0), 3)

	// The target asks for the second type.
	fds: [2]linux.Fd
	linux.pipe2(&fds, {.CLOEXEC})
	fake_send(r.f, src, 1, "text/plain", p.Fd(fds[1])) // send
	p.window_pump(w)
	buf: [64]u8
	n, _ := linux.read(fds[0], buf[:])
	linux.close(fds[0])
	testing.expect_value(t, string(buf[:max(n, 0)]), "payload two")

	w.input.down[.Left] = true
	fake_send(r.f, src, 3) // dnd_drop_performed
	p.window_pump(w)
	testing.expect(t, !w.input.down[.Left], "the release went to the drag; the button is let go")
	testing.expect_value(t, p.drag_result(r.ui), p.Drag_Result.None) // not finished yet
	fake_send(r.f, src, 4) // dnd_finished
	p.window_pump(w)
	testing.expect(t, !p.drag_active(r.ui))
	testing.expect_value(t, p.drag_result(r.ui), p.Drag_Result.Dropped)
	testing.expect_value(t, p.drag_result(r.ui), p.Drag_Result.None)
	_, destroyed := find(fake_requests(r.f), src, 1)
	testing.expect(t, destroyed, "the source is destroyed")

	testing.expect(t, p.drag_start(r.ui, {TEXT}, {"again"}))
	reqs = fake_requests(r.f)
	create, _ = find(reqs, w.clip.ddm, 0)
	fake_send(r.f, fake_arg(create, 0), 2) // cancelled
	p.window_pump(w)
	testing.expect_value(t, p.drag_result(r.ui), p.Drag_Result.Cancelled)
}
