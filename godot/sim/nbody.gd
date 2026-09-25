class_name NBody
extends RefCounted

# ============================================================================
# THE SUB-STEP LOOP, NATIVE WHEN IT CAN BE.
# ----------------------------------------------------------------------------
# Same contract as Derive.step_physics — it IS that loop — but it hands the hot
# part to native/astrarium_native.c's NBodyKernel when the library is loaded,
# because GDScript cannot run the O(N²) pair loops at the rate the presets ask
# for (`solar`: 33.5 ms of physics a frame in GDScript; see the C file's
# header). When the library is missing — a fresh clone on another platform, a
# build without it — Derive.step_physics runs instead and the answer is the
# same, only slower. A missing native piece is not an error.
#
# The kernel stops after any sub-step that produced a merger and returns here,
# so on_merger (the orchestrator's handleMerger) runs exactly where the web
# build ran it — between that sub-step and the next — and may change horizons,
# types and the body list before integration resumes.
# ============================================================================

const HDR := 8
const STRIDE := 16
static var _native := -1   # -1 unknown, 0 absent, 1 present

static func native_available() -> bool:
	if _native < 0:
		_native = 1 if ClassDB.class_exists("NBodyKernel") else 0
	return _native == 1

## Returns { stepped, steps } exactly as Derive.step_physics does.
static func step_physics(bodies: Array, sim_dt: float, max_step: float, gw_boost: float, on_merger: Callable = Callable()) -> Dictionary:
	if not native_available():
		return Derive.step_physics(bodies, sim_dt, max_step, gw_boost, on_merger)
	if sim_dt <= 0.0: return {"stepped": 0.0, "steps": 0}
	var remaining := sim_dt
	var guard := 0
	var stepped := 0.0
	while true:
		var n := bodies.size()
		var A := PackedFloat64Array()
		A.resize(HDR + n * STRIDE + n * 3)
		A[0] = float(A.size()); A[1] = float(n); A[2] = remaining; A[3] = max_step
		A[4] = gw_boost; A[5] = float(guard)
		for k in n:
			var b: Body = bodies[k]
			var o := HDR + k * STRIDE
			A[o] = b.pos.x; A[o + 1] = b.pos.y; A[o + 2] = b.pos.z
			A[o + 3] = b.vel.x; A[o + 4] = b.vel.y; A[o + 5] = b.vel.z
			A[o + 6] = b.mass; A[o + 7] = b.rs; A[o + 8] = 1.0 if b.type == "bh" else 0.0
			A[o + 9] = b.softening; A[o + 10] = b.radius; A[o + 11] = b.contact_au
			A[o + 12] = 1.0 if b.emits_gw else 0.0; A[o + 13] = 1.0 if b.alive else 0.0
		A = ClassDB.class_call_static("NBodyKernel", "step", A)
		for k in n:
			var b: Body = bodies[k]
			var o := HDR + k * STRIDE
			b.pos.x = A[o]; b.pos.y = A[o + 1]; b.pos.z = A[o + 2]
			b.vel.x = A[o + 3]; b.vel.y = A[o + 4]; b.vel.z = A[o + 5]
			b.mass = A[o + 6]
			b.alive = A[o + 13] != 0.0
		remaining = A[2]
		guard = int(A[5])
		stepped += A[6]
		var nev := int(A[7])
		if nev > 0:
			# Resolve the indices to bodies BEFORE any handler runs: a handler
			# removes the absorbed body and shifts every index after it.
			var evs := []
			var eo := HDR + n * STRIDE
			for e in mini(nev, n):
				evs.append({"survivor": bodies[int(A[eo + e * 3])], "absorbed": bodies[int(A[eo + e * 3 + 1])], "separation": A[eo + e * 3 + 2]})
			for ev in evs:
				if on_merger.is_valid(): on_merger.call(ev)
				else: bodies.erase(ev.absorbed)
		if nev == 0 or remaining <= 1e-12 or guard >= Derive.STEP_GUARD:
			break
	return {"stepped": stepped, "steps": guard}
