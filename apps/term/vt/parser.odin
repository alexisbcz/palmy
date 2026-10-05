package vt

// ---------------------------------------------------------------------------
// The escape-sequence state machine.
//
// This is Paul Williams' DEC-compatible parser, the one every serious terminal
// uses, written out as an explicit state machine rather than a switch over
// bytes. The difference matters: an ad-hoc switch handles the sequences its
// author thought of and corrupts the screen on the ones they did not, and
// every time a new sequence is added it grows another special case until
// nobody can say what it does. A state machine has a fixed set of states and a
// transition for every byte, so "what happens if a C0 control arrives in the
// middle of a CSI parameter?" has an answer whether or not anyone asked.
//
// The parser knows nothing about what the sequences mean. It emits Actions;
// terminal.odin decides what they do.
// ---------------------------------------------------------------------------

MAX_PARAMS :: 32
MAX_INTERMEDIATES :: 4
MAX_OSC :: 8 * 1024
MAX_DCS :: 8 * 1024

State :: enum u8 {
	Ground,
	Escape,
	Escape_Intermediate,
	Csi_Entry,
	Csi_Param,
	Csi_Intermediate,
	Csi_Ignore,
	Dcs_Entry,
	Dcs_Param,
	Dcs_Intermediate,
	Dcs_Passthrough,
	Dcs_Ignore,
	Osc_String,
	Sos_Pm_Apc_String,
}

Action_Kind :: enum u8 {
	Print,        // cp holds a decoded codepoint to put on the screen
	Execute,      // b holds a C0 or C1 control
	Esc_Dispatch, // b holds the final byte, intermediates may be set
	Csi_Dispatch, // b holds the final byte, params/intermediates/private set
	Osc_Dispatch, // osc holds the raw string, osc_term the terminator
	Dcs_Hook,     // a DCS began: params/intermediates/final are set
	Dcs_Put,      // b is one byte of the DCS payload
	Dcs_Unhook,   // the DCS ended
}

Action :: struct {
	kind:          Action_Kind,
	cp:            rune,
	b:             u8,
	// params[i] is the i'th parameter and seps[i] is the separator that
	// *follows* it -- ';' or ':', with the last one always ';'. Keeping the
	// separators is what makes `4:3` (curly underline) distinguishable from
	// `4;3` (underline, then italic), and following rather than preceding is
	// the convention libghostty uses, so the oracle can hand the arrays
	// straight across.
	params:        []u16,
	seps:          []u8,
	// True where the parameter was written as an empty field, so that `1;;3`
	// can default its middle parameter rather than reading a literal zero.
	empty:         []bool,
	intermediates: []u8,
	private:       u8, // '<' '=' '>' '?' or 0
	osc:           []u8,
	osc_term:      u8,
}

Sink :: struct {
	user: rawptr,
	fn:   proc(user: rawptr, a: Action),
}

Parser :: struct {
	state:       State,
	utf8:        Utf8_Decoder,

	params:      [MAX_PARAMS]u16,
	seps:        [MAX_PARAMS]u8,
	empty:       [MAX_PARAMS]bool,
	nparams:     int,
	param_full:  bool, // a parameter list longer than MAX_PARAMS is ignored
	overflow:    bool, // a single parameter exceeded 65534

	inter:       [MAX_INTERMEDIATES]u8,
	ninter:      int,
	inter_full:  bool,

	private:     u8,

	osc:         [MAX_OSC]u8,
	nosc:        int,
	osc_full:    bool,

	sink:        Sink,
}

parser_init :: proc(p: ^Parser, sink: Sink) {
	p^ = {}
	p.sink = sink
}

@(private = "file")
emit :: proc(p: ^Parser, a: Action) {
	if p.sink.fn != nil {
		p.sink.fn(p.sink.user, a)
	}
}

@(private = "file")
clear_state :: proc(p: ^Parser) {
	p.nparams = 0
	p.param_full = false
	p.overflow = false
	p.ninter = 0
	p.inter_full = false
	p.private = 0
	p.nosc = 0
	p.osc_full = false
}

@(private = "file")
push_param :: proc(p: ^Parser) {
	if p.nparams >= MAX_PARAMS {
		p.param_full = true
		return
	}
	p.params[p.nparams] = 0
	p.seps[p.nparams] = ';'
	p.empty[p.nparams] = true
	p.nparams += 1
}

// separate records the separator that closed the current parameter and opens
// the next one.
@(private = "file")
separate :: proc(p: ^Parser, sep: u8) {
	if p.nparams == 0 {
		push_param(p)
	}
	if p.nparams > 0 && p.nparams <= MAX_PARAMS {
		p.seps[p.nparams - 1] = sep
	}
	push_param(p)
}

@(private = "file")
digit :: proc(p: ^Parser, b: u8) {
	if p.nparams == 0 {
		push_param(p)
	}
	if p.nparams > MAX_PARAMS {
		return
	}
	i := p.nparams - 1
	v := u32(p.params[i]) * 10 + u32(b - '0')
	if v > 65534 {
		v = 65534
		p.overflow = true
	}
	p.params[i] = u16(v)
	p.empty[i] = false
}

@(private = "file")
collect :: proc(p: ^Parser, b: u8) {
	if p.ninter >= MAX_INTERMEDIATES {
		p.inter_full = true
		return
	}
	p.inter[p.ninter] = b
	p.ninter += 1
}

@(private = "file")
dispatch :: proc(p: ^Parser, kind: Action_Kind, final: u8) {
	if p.param_full || p.inter_full {
		// xterm drops a sequence whose parameter or intermediate list ran
		// over rather than acting on a truncated one.
		return
	}
	emit(
		p,
		Action {
			kind = kind,
			b = final,
			params = p.params[:p.nparams],
			seps = p.seps[:p.nparams],
			empty = p.empty[:p.nparams],
			intermediates = p.inter[:p.ninter],
			private = p.private,
		},
	)
}

// is_c0 is true for the controls that are executed from any state.
@(private = "file")
is_c0 :: proc "contextless" (b: u8) -> bool {
	return b <= 0x17 || b == 0x19 || (b >= 0x1C && b <= 0x1F)
}

// parse_byte feeds one byte through the machine.
parse_byte :: proc(p: ^Parser, b: u8) {
	// The "anywhere" transitions, which outrank whatever state we are in.
	// A CAN or SUB abandons the sequence in progress; an ESC starts a new one.
	switch b {
	case 0x18, 0x1A:
		if p.state == .Dcs_Passthrough {
			emit(p, Action{kind = .Dcs_Unhook})
		}
		p.state = .Ground
		clear_state(p)
		utf8_reset(&p.utf8)
		emit(p, Action{kind = .Execute, b = b})
		return
	case 0x1B:
		if p.state == .Dcs_Passthrough {
			emit(p, Action{kind = .Dcs_Unhook})
		}
		// An ESC inside an OSC or a string state is the first half of ST.
		// The string states handle that themselves below, so only get here
		// for the rest.
		if p.state == .Osc_String {
			osc_finish(p, 0x1B)
			p.state = .Escape
			clear_state(p)
			return
		}
		if p.state == .Sos_Pm_Apc_String {
			p.state = .Escape
			clear_state(p)
			return
		}
		p.state = .Escape
		clear_state(p)
		utf8_reset(&p.utf8)
		return
	}

	switch p.state {
	case .Ground:
		ground_byte(p, b)

	case .Escape:
		switch {
		case is_c0(b):
			emit(p, Action{kind = .Execute, b = b})
		case b == 0x7F:
		// ignored
		case b >= 0x20 && b <= 0x2F:
			collect(p, b)
			p.state = .Escape_Intermediate
		case b == '[':
			clear_state(p)
			p.state = .Csi_Entry
		case b == ']':
			clear_state(p)
			p.state = .Osc_String
		case b == 'P':
			clear_state(p)
			p.state = .Dcs_Entry
		case b == 'X' || b == '^' || b == '_':
			clear_state(p)
			p.state = .Sos_Pm_Apc_String
		case b >= 0x30 && b <= 0x7E:
			dispatch(p, .Esc_Dispatch, b)
			p.state = .Ground
		case:
			p.state = .Ground
		}

	case .Escape_Intermediate:
		switch {
		case is_c0(b):
			emit(p, Action{kind = .Execute, b = b})
		case b == 0x7F:
		case b >= 0x20 && b <= 0x2F:
			collect(p, b)
		case b >= 0x30 && b <= 0x7E:
			dispatch(p, .Esc_Dispatch, b)
			p.state = .Ground
		case:
			p.state = .Ground
		}

	case .Csi_Entry:
		switch {
		case is_c0(b):
			emit(p, Action{kind = .Execute, b = b})
		case b == 0x7F:
		case b >= '0' && b <= '9':
			digit(p, b)
			p.state = .Csi_Param
		case b == ';' || b == ':':
			separate(p, b)
			p.state = .Csi_Param
		case b >= 0x3C && b <= 0x3F:
			p.private = b
			p.state = .Csi_Param
		case b >= 0x20 && b <= 0x2F:
			collect(p, b)
			p.state = .Csi_Intermediate
		case b >= 0x40 && b <= 0x7E:
			dispatch(p, .Csi_Dispatch, b)
			p.state = .Ground
		case:
			p.state = .Csi_Ignore
		}

	case .Csi_Param:
		switch {
		case is_c0(b):
			emit(p, Action{kind = .Execute, b = b})
		case b == 0x7F:
		case b >= '0' && b <= '9':
			digit(p, b)
		case b == ';' || b == ':':
			separate(p, b)
		case b >= 0x3C && b <= 0x3F:
			// A private marker after parameters have started is malformed.
			p.state = .Csi_Ignore
		case b >= 0x20 && b <= 0x2F:
			collect(p, b)
			p.state = .Csi_Intermediate
		case b >= 0x40 && b <= 0x7E:
			dispatch(p, .Csi_Dispatch, b)
			p.state = .Ground
		case:
			p.state = .Csi_Ignore
		}

	case .Csi_Intermediate:
		switch {
		case is_c0(b):
			emit(p, Action{kind = .Execute, b = b})
		case b == 0x7F:
		case b >= 0x20 && b <= 0x2F:
			collect(p, b)
		case b >= 0x40 && b <= 0x7E:
			dispatch(p, .Csi_Dispatch, b)
			p.state = .Ground
		case:
			p.state = .Csi_Ignore
		}

	case .Csi_Ignore:
		switch {
		case is_c0(b):
			emit(p, Action{kind = .Execute, b = b})
		case b >= 0x40 && b <= 0x7E:
			p.state = .Ground
		}

	case .Dcs_Entry:
		switch {
		case b == 0x7F || is_c0(b):
		case b >= '0' && b <= '9':
			digit(p, b)
			p.state = .Dcs_Param
		case b == ';' || b == ':':
			separate(p, b)
			p.state = .Dcs_Param
		case b >= 0x3C && b <= 0x3F:
			p.private = b
			p.state = .Dcs_Param
		case b >= 0x20 && b <= 0x2F:
			collect(p, b)
			p.state = .Dcs_Intermediate
		case b >= 0x40 && b <= 0x7E:
			dispatch(p, .Dcs_Hook, b)
			p.state = .Dcs_Passthrough
		case:
			p.state = .Dcs_Ignore
		}

	case .Dcs_Param:
		switch {
		case b == 0x7F || is_c0(b):
		case b >= '0' && b <= '9':
			digit(p, b)
		case b == ';' || b == ':':
			separate(p, b)
		case b >= 0x3C && b <= 0x3F:
			p.state = .Dcs_Ignore
		case b >= 0x20 && b <= 0x2F:
			collect(p, b)
			p.state = .Dcs_Intermediate
		case b >= 0x40 && b <= 0x7E:
			dispatch(p, .Dcs_Hook, b)
			p.state = .Dcs_Passthrough
		case:
			p.state = .Dcs_Ignore
		}

	case .Dcs_Intermediate:
		switch {
		case b == 0x7F || is_c0(b):
		case b >= 0x20 && b <= 0x2F:
			collect(p, b)
		case b >= 0x40 && b <= 0x7E:
			dispatch(p, .Dcs_Hook, b)
			p.state = .Dcs_Passthrough
		case:
			p.state = .Dcs_Ignore
		}

	case .Dcs_Passthrough:
		switch {
		case b == 0x7F:
		case b == 0x9C:
			emit(p, Action{kind = .Dcs_Unhook})
			p.state = .Ground
		case:
			emit(p, Action{kind = .Dcs_Put, b = b})
		}

	case .Dcs_Ignore:
		if b == 0x9C {
			p.state = .Ground
		}

	case .Osc_String:
		switch {
		case b == 0x07:
			osc_finish(p, 0x07)
			p.state = .Ground
		case b == 0x9C:
			osc_finish(p, 0x9C)
			p.state = .Ground
		case b < 0x20 && b != 0x08 && b != 0x09 && b != 0x0A && b != 0x0D:
			// Most C0 inside an OSC is a sign the string is malformed.
			// Tabs, newlines and backspaces do occur in titles in the wild.
			osc_finish(p, 0)
			p.state = .Ground
			emit(p, Action{kind = .Execute, b = b})
		case:
			if p.nosc < MAX_OSC {
				p.osc[p.nosc] = b
				p.nosc += 1
			} else {
				p.osc_full = true
			}
		}

	case .Sos_Pm_Apc_String:
		if b == 0x9C {
			p.state = .Ground
		}
	}
}

@(private = "file")
osc_finish :: proc(p: ^Parser, term: u8) {
	if !p.osc_full {
		emit(p, Action{kind = .Osc_Dispatch, osc = p.osc[:p.nosc], osc_term = term})
	}
	clear_state(p)
}

@(private = "file")
ground_byte :: proc(p: ^Parser, b: u8) {
	if b < 0x80 {
		// An ASCII byte ends any partial UTF-8 sequence, which is a
		// truncation and therefore one replacement character.
		if p.utf8.remaining != 0 {
			utf8_reset(&p.utf8)
			emit(p, Action{kind = .Print, cp = REPLACEMENT})
		}
		if is_c0(b) {
			emit(p, Action{kind = .Execute, b = b})
			return
		}
		if b == 0x7F {
			// DEL is discarded in the ground state.
			return
		}
		emit(p, Action{kind = .Print, cp = rune(b)})
		return
	}

	// 0x80..0x9F are the C1 controls when they are not continuation bytes.
	// A continuation byte is only legitimate mid-sequence, and the decoder
	// already knows whether it is mid-sequence.
	if p.utf8.remaining == 0 && b >= 0x80 && b <= 0x9F {
		c1_execute(p, b)
		return
	}

	cp, res := utf8_feed(&p.utf8, b)
	switch res {
	case .Incomplete:
	case .Codepoint:
		emit(p, Action{kind = .Print, cp = cp})
	case .Invalid_Consumed:
		emit(p, Action{kind = .Print, cp = REPLACEMENT})
	case .Invalid:
		emit(p, Action{kind = .Print, cp = REPLACEMENT})
		// The byte was not part of the bad sequence, so reconsider it.
		ground_byte(p, b)
	}
}

// c1_execute maps the eight-bit controls onto the escape sequences they are
// shorthand for, so the rest of the parser only has to know one spelling.
@(private = "file")
c1_execute :: proc(p: ^Parser, b: u8) {
	switch b {
	case 0x90: // DCS
		clear_state(p)
		p.state = .Dcs_Entry
	case 0x98, 0x9E, 0x9F: // SOS, PM, APC
		clear_state(p)
		p.state = .Sos_Pm_Apc_String
	case 0x9B: // CSI
		clear_state(p)
		p.state = .Csi_Entry
	case 0x9D: // OSC
		clear_state(p)
		p.state = .Osc_String
	case 0x9C: // ST with nothing open
	case:
		emit(p, Action{kind = .Execute, b = b})
	}
}

// parse feeds a block of bytes.
parse :: proc(p: ^Parser, data: []u8) {
	for b in data {
		parse_byte(p, b)
	}
}

// param returns parameter i, or `def` when it is missing or written empty.
// Separator-joined subparameters are read with `subparam`.
param :: proc(a: Action, i: int, def: u16) -> u16 {
	if i >= len(a.params) || a.empty[i] {
		return def
	}
	return a.params[i]
}

// param_count reports how many parameters were given.
param_count :: proc(a: Action) -> int {
	return len(a.params)
}
