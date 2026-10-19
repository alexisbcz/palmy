package pcp

// PCP2 — the call transport in SFU mode.
//
// PCP1 (apps/call/proto.odin) is a two-party protocol: there is one peer, so a
// datagram needs no source. Through a selective forwarding unit there are N,
// and the SFU needs three things it could not read before without decoding,
// which under end-to-end encryption it cannot do:
//
//	src     who sent this. The *SFU* stamps it, from the session the datagram
//	        arrived on. A sender writes 0; whatever it writes is overwritten,
//	        so one participant cannot speak as another.
//	layer   which simulcast layer a video frame belongs to (0 high, 1 low),
//	        so the SFU can pick one per receiver.
//	level   the audio level, RFC 6464 style: bit 7 is voice activity, the low
//	        seven bits are the level in -dBov (0 loudest, 127 silence). The
//	        SFU runs dominant-speaker detection on this byte alone.
//
// All three travel in the clear on purpose. Everything else a forwarder
// needs — sequence, timestamp, frame id, fragment index, keyframe flag — was
// already in PCP1's header, and the payload is an SFrame ciphertext.
//
//	 0       4    5     6     8                 16      20     22     24    26     27     28
//	+-------+----+-----+-----+-----------------+-------+------+------+-----+------+------+
//	| "PCP2"| pt |flags| seq | capture ts (us) | frame | frag |nfrag | src |layer |level |
//	+-------+----+-----+-----+-----------------+-------+------+------+-----+------+------+
//
// All integers big-endian. 28 bytes. The payload cap is the same 1200 bytes as
// PCP1, so the largest datagram is 1228.

import "core:encoding/endian"
import "core:math"

HDR :: 28
MTU_PAYLOAD :: 1200
MAX_PACKET :: HDR + MTU_PAYLOAD
MAGIC :: [4]u8{'P', 'C', 'P', '2'}

// Payload types share PCP1's numbering.
Ptype :: enum u8 {
	Control    = 0,
	Audio_Opus = 1,
	Audio_PCM  = 2,
	Video_JPEG = 3,
	Video_H264 = 4,
}

FLAG_MARKER :: u8(0x01) // last fragment of its frame
FLAG_KEYFRAME :: u8(0x02) // decodable on its own; set on every fragment
FLAG_E2EE :: u8(0x04) // the reassembled frame is an SFrame ciphertext

// Audio level: RFC 6464's octet. 127 is silence.
LEVEL_SILENT :: u8(127)
LEVEL_VAD :: u8(0x80)

Header :: struct {
	ptype: Ptype,
	flags: u8,
	seq:   u16,
	ts_us: u64,
	frame: u32,
	frag:  u16,
	nfrag: u16,
	src:   u16,
	layer: u8,
	level: u8,
}

is_video :: proc(t: Ptype) -> bool {
	return t == .Video_JPEG || t == .Video_H264
}

is_audio :: proc(t: Ptype) -> bool {
	return t == .Audio_Opus || t == .Audio_PCM
}

keyframed :: proc(h: Header) -> bool {
	return h.flags & FLAG_KEYFRAME != 0
}

write_header :: proc(b: []u8, h: Header) -> bool {
	if len(b) < HDR {
		return false
	}
	m := MAGIC
	copy(b[0:4], m[:])
	b[4] = u8(h.ptype)
	b[5] = h.flags
	endian.put_u16(b[6:8], .Big, h.seq)
	endian.put_u64(b[8:16], .Big, h.ts_us)
	endian.put_u32(b[16:20], .Big, h.frame)
	endian.put_u16(b[20:22], .Big, h.frag)
	endian.put_u16(b[22:24], .Big, h.nfrag)
	endian.put_u16(b[24:26], .Big, h.src)
	b[26] = h.layer
	b[27] = h.level
	return true
}

// parse validates the framing — magic, a known type, fragment counters that
// agree with each other and with the marker bit — and returns the payload as
// a slice of `b`.
parse :: proc(b: []u8) -> (h: Header, payload: []u8, ok: bool) {
	if len(b) < HDR || len(b) > MAX_PACKET {
		return
	}
	if b[0] != 'P' || b[1] != 'C' || b[2] != 'P' || b[3] != '2' {
		return
	}
	if b[4] > u8(Ptype.Video_H264) {
		return
	}
	h.ptype = Ptype(b[4])
	h.flags = b[5]
	h.seq, _ = endian.get_u16(b[6:8], .Big)
	h.ts_us, _ = endian.get_u64(b[8:16], .Big)
	h.frame, _ = endian.get_u32(b[16:20], .Big)
	h.frag, _ = endian.get_u16(b[20:22], .Big)
	h.nfrag, _ = endian.get_u16(b[22:24], .Big)
	h.src, _ = endian.get_u16(b[24:26], .Big)
	h.layer = b[26]
	h.level = b[27]
	if h.nfrag == 0 || h.frag >= h.nfrag {
		return
	}
	// The marker is set exactly on the last fragment. A datagram where the
	// two disagree is corrupt, and trusting either one would be guessing.
	if (h.flags & FLAG_MARKER != 0) != (h.frag == h.nfrag - 1) {
		return
	}
	return h, b[HDR:], true
}

// stamp_src overwrites the source field of an encoded datagram in place. The
// SFU does this to every datagram it forwards.
stamp_src :: proc(b: []u8, src: u16) {
	if len(b) >= HDR {
		endian.put_u16(b[24:26], .Big, src)
	}
}

fragment_count :: proc(n: int) -> int {
	if n <= 0 {
		return 1
	}
	return (n + MTU_PAYLOAD - 1) / MTU_PAYLOAD
}

// fragment_into writes fragment `i` of `data` into `out` and returns the
// datagram. The marker goes on the last fragment.
fragment_into :: proc(out: []u8, data: []u8, i: int, h: Header) -> []u8 {
	nf := fragment_count(len(data))
	lo := i * MTU_PAYLOAD
	hi := min(len(data), lo + MTU_PAYLOAD)
	hh := h
	hh.frag = u16(i)
	hh.nfrag = u16(nf)
	hh.flags &= ~FLAG_MARKER
	if i == nf - 1 {
		hh.flags |= FLAG_MARKER
	}
	write_header(out, hh)
	n := copy(out[HDR:], data[lo:hi])
	return out[:HDR + n]
}

// level_byte turns a frame RMS (linear, 0..1 of full scale) into RFC 6464's
// octet: -dBov clamped to 0..127, with the voice-activity bit set above
// VAD_DBOV.
VAD_DBOV :: -50.0

level_byte :: proc(rms: f64) -> u8 {
	if rms <= 1e-7 {
		return LEVEL_SILENT
	}
	db := 20 * math.log10(rms)
	if db > 0 {
		db = 0
	}
	l := u8(clamp(-db + 0.5, 0, 127))
	if db > VAD_DBOV {
		l |= LEVEL_VAD
	}
	return l
}

// level_dbov returns the level part of the octet as a negative dBov.
level_dbov :: proc(l: u8) -> f64 {
	return -f64(l & 0x7f)
}

level_vad :: proc(l: u8) -> bool {
	return l & LEVEL_VAD != 0
}

