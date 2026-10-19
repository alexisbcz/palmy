package main

// The worker: one job at a time off the UI thread, so the window keeps
// drawing ("Signing in…", the setup list filling in) while the network and
// the other programs work.

import "core:strings"
import "core:sync"
import "core:thread"

lock :: proc(st: ^St) {
	sync.mutex_lock(&st.job.mu)
}

unlock :: proc(st: ^St) {
	sync.mutex_unlock(&st.job.mu)
}

start_job :: proc(st: ^St, kind: Job_Kind) {
	if st.job.running {
		return
	}
	clear_msg(st)
	st.job.kind = kind
	st.job.running = true
	st.job.finished = false
	delete(st.job.err)
	st.job.err = ""
	if st.opts.fixture {
		// Screenshots never run anything.
		st.job.running = false
		return
	}
	st.job.th = thread.create_and_start_with_poly_data(st, worker_main)
}

worker_main :: proc(st: ^St) {
	err := ""
	switch st.job.kind {
	case .None:
	case .Sign_In:
		err = do_sign_in(st)
	case .Sign_Up:
		err = do_sign_up(st)
	case .Identities:
		if n := do_identities(st); n > 0 {
			err = tr("Some identities could not be created. Each says why.")
		}
	case .Vault:
		err = do_vault(st)
	case .Vault_Enroll:
		err = do_vault_enroll(st)
	case .Kit:
		err = do_kit(st, kit_dir_default())
	case .Services:
		do_services(st)
	}
	lock(st)
	st.job.err = strings.clone(err)
	st.job.finished = true
	unlock(st)
}

// poll_job is called at the start of every frame: a finished job is joined
// and its result handed to the page that started it.
poll_job :: proc(st: ^St) {
	if !st.job.running {
		return
	}
	lock(st)
	done := st.job.finished
	unlock(st)
	if !done {
		return
	}
	thread.join(st.job.th)
	thread.destroy(st.job.th)
	st.job.th = nil
	st.job.running = false
	st.job.finished = false
	job_done(st, st.job.kind, st.job.err)
}

// wait_job blocks until the running job is over: the command line and the
// offscreen test driver use it.
wait_job :: proc(st: ^St) {
	if st.job.th != nil {
		thread.join(st.job.th)
	}
	if st.job.running {
		poll_job(st)
	}
}
