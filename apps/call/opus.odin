package call

// ---------------------------------------------------------------------------
// Opus.
//
// libopus is linked directly. That is the one dependency this application adds
// beyond libc, and it is the right one: a real call needs a real speech codec,
// and shelling out to ffmpeg for the codec would mean muxing into Ogg and
// demuxing back out again — a container's worth of latency and parsing for a
// job that is three function calls.
//
// If the library is missing at load time the binary will not start at all, so
// `audio_opus_ready` reports whether the *encoder* came up and the audio
// engine falls back to raw PCM-16 on the wire when it did not. That fallback
// is honest rather than silent: the UI names the codec actually in use.
// ---------------------------------------------------------------------------

foreign import libopus "system:opus"

Opus_Encoder :: struct {}
Opus_Decoder :: struct {}

OPUS_APPLICATION_VOIP :: 2048
OPUS_APPLICATION_AUDIO :: 2049
OPUS_APPLICATION_RESTRICTED_LOWDELAY :: 2051

OPUS_SET_BITRATE_REQUEST :: 4002
OPUS_SET_COMPLEXITY_REQUEST :: 4010
OPUS_SET_INBAND_FEC_REQUEST :: 4012
OPUS_SET_PACKET_LOSS_PERC_REQUEST :: 4014
OPUS_SET_DTX_REQUEST :: 4016
OPUS_SET_SIGNAL_REQUEST :: 4024

OPUS_SIGNAL_VOICE :: 3001

@(default_calling_convention = "c")
foreign libopus {
	opus_encoder_create :: proc(fs: i32, channels: i32, application: i32, err: ^i32) -> ^Opus_Encoder ---
	opus_encoder_destroy :: proc(st: ^Opus_Encoder) ---
	opus_encode :: proc(st: ^Opus_Encoder, pcm: [^]i16, frame_size: i32, data: [^]u8, max_data_bytes: i32) -> i32 ---
	opus_encoder_ctl :: proc(st: ^Opus_Encoder, request: i32, #c_vararg args: ..any) -> i32 ---

	opus_decoder_create :: proc(fs: i32, channels: i32, err: ^i32) -> ^Opus_Decoder ---
	opus_decoder_destroy :: proc(st: ^Opus_Decoder) ---
	// `data == nil, len == 0` asks for packet-loss concealment: Opus
	// extrapolates one frame from the decoder's own history. This is the
	// concealment strategy the jitter buffer documents.
	opus_decode :: proc(st: ^Opus_Decoder, data: [^]u8, len: i32, pcm: [^]i16, frame_size: i32, decode_fec: i32) -> i32 ---

	opus_get_version_string :: proc() -> cstring ---
}

opus_version :: proc() -> string {
	return string(opus_get_version_string())
}
