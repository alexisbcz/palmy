#+build wasi
package odin_libc

// Part of the web backend's overlay of the Odin root (see
// apps/tools/web-build.sh). On wasm, core:math's sin, cos, pow and exp are
// LLVM intrinsics that lower to calls to sinf/cosf/powf/expf (wasm has no
// instruction for them), and vendor:libc-shim answers those calls with
// core:math again -- so the first `math.pow` (palmy's text gamma table)
// recursed until the stack ran out. web-build.sh rewrites the shim's bodies
// to call these instead: the browser's own Math functions, in double
// precision, rounded once to float where the C function is single precision.
// expf is not in the shim at all and is added here.

foreign import libm "palmy_libm"

@(default_calling_convention = "c")
foreign libm {
	@(link_name = "palmy_libm_sin")
	libm_sin :: proc(x: f64) -> f64 ---
	@(link_name = "palmy_libm_cos")
	libm_cos :: proc(x: f64) -> f64 ---
	@(link_name = "palmy_libm_pow")
	libm_pow :: proc(x, y: f64) -> f64 ---
	@(link_name = "palmy_libm_exp")
	libm_exp :: proc(x: f64) -> f64 ---
}

@(require, linkage = "strong", link_name = "expf")
expf :: proc "c" (x: f32) -> f32 {
	return f32(libm_exp(f64(x)))
}
