// subsurface.odin — wl_subsurface synchronized and desynchronized commits.
//
// A subsurface is synchronized by default: its commit does not show; the
// state is cached and applied, together with its children's, when its parent
// next commits. That is what lets a client move a child (a video, a bubble, a
// web page's content) and repaint the parent in one atomic step instead of
// showing the child's new frame over the parent's old one. A desynchronized
// subsurface (Firefox's page content) shows its commits at once — unless an
// ancestor is synchronized, which makes it synchronized too. set_position and
// the stacking requests apply with the parent's commit as well.
//
// The client's pixels are still copied at commit time, into the cache, so the
// wl_buffer is released straight away exactly as for any other surface.
package wm

// sub_synced is the effective mode: synchronized itself, or under a parent
// that is.
sub_synced :: proc(surf: ^Surface) -> bool {
	q := surf
	for i := 0; i < 32 && q != nil && q.role == .Sub; i += 1 {
		if !q.sub_desync {
			return true
		}
		q = q.parent
	}
	return false
}

// sub_cache takes a synchronized subsurface's pending state into its cache.
sub_cache :: proc(s: ^Server, surf: ^Surface) {
	if surf.p_buffer_set {
		surf.p_buffer_set = false
		b := surf.p_buffer
		surf.p_buffer = nil
		surf.c_buf_set = true
		if b == nil {
			delete(surf.c_img)
			surf.c_img = nil
			surf.c_iw, surf.c_ih = 0, 0
		} else if !b.destroyed && b.pool.mem != nil {
			// copy_buffer writes the surface's current image; point it at the
			// cache for the duration, and put the current one back.
			img, iw, ih, opq, df := surf.img, surf.iw, surf.ih, surf.opaque, surf.dmg_full
			surf.img, surf.iw, surf.ih = surf.c_img, surf.c_iw, surf.c_ih
			copy_buffer(surf, b)
			surf.c_img, surf.c_iw, surf.c_ih, surf.c_opaque = surf.img, surf.iw, surf.ih, surf.opaque
			surf.img, surf.iw, surf.ih, surf.opaque, surf.dmg_full = img, iw, ih, opq, df
			event(b.client, b.id, 0) // wl_buffer.release
		}
	}
	surf.c_scale = surf.p_scale
	for cb in surf.p_frames {
		append(&surf.c_frames, cb)
	}
	clear(&surf.p_frames)
	// The damage is applied with the state; until then it is the cache's.
	surf.p_dmg_full = true
	surf.p_dmg_n = 0
	surf.c_has = true
}

// sub_apply_cache shows what a subsurface cached.
sub_apply_cache :: proc(s: ^Server, surf: ^Surface) {
	if !surf.c_has {
		return
	}
	if surf.c_buf_set {
		delete(surf.img)
		surf.img, surf.iw, surf.ih, surf.opaque = surf.c_img, surf.c_iw, surf.c_ih, surf.c_opaque
		surf.c_img, surf.c_iw, surf.c_ih = nil, 0, 0
	}
	if surf.c_scale > 0 {
		surf.scale = surf.c_scale
	}
	for cb in surf.c_frames {
		append(&surf.frames, cb)
	}
	clear(&surf.c_frames)
	surface_apply_damage(surf)
	damage_commit(s, surf)
	surf.c_has = false
	surf.c_buf_set = false
	if !session.bare {
		s.dirty = true
	}
}

// sub_parent_committed runs after a surface's commit took effect: its
// children's pending positions apply, and the synchronized ones show what
// they cached — which counts as their commit, so on down the tree.
sub_parent_committed :: proc(s: ^Server, parent: ^Surface) {
	for ch in parent.children {
		if ch.p_pos_set {
			ch.p_pos_set = false
			if ch.sx != ch.p_sx || ch.sy != ch.p_sy {
				ch.sx, ch.sy = ch.p_sx, ch.p_sy
				s.dirty = true
			}
		}
		if ch.c_has && sub_synced(ch) {
			sub_apply_cache(s, ch)
			sub_parent_committed(s, ch)
		}
	}
}
