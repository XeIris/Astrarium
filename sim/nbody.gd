class_name NBody
extends RefCounted

# Merger callbacks run between native sub-steps so changed types, horizons and
# body lists are repacked before continuing. Derive supplies the same fallback.

const HDR := 10
const STRIDE := 16
static var _native := -1   # -1 unknown, 0 absent, 1 present

static func native_available() -> bool:
	if _native < 0:
		_native = 1 if ClassDB.class_exists("NBodyKernel") else 0
	return _native == 1

## Returns accepted years, successful sub-steps and numerical limits as Derive does.
static func step_physics(bodies: Array, sim_dt: float, max_step: float, gw_boost: float, on_merger: Callable = Callable(), initial_steps: int = 0) -> Dictionary:
	if not native_available():
		return Derive.step_physics(bodies, sim_dt, max_step, gw_boost, on_merger, initial_steps)
	if not is_finite(sim_dt) or not is_finite(max_step) or not is_finite(gw_boost) or (sim_dt > 0.0 and (max_step <= 0.0 or not Physics.finite_state(bodies))):
		return {"stepped": 0.0, "steps": initial_steps, "resolution_limited": true}
	if sim_dt <= 0.0: return {"stepped": 0.0, "steps": initial_steps, "resolution_limited": false}
	var remaining := sim_dt
	var guard := initial_steps
	var stepped := 0.0
	var resolution_limited := false
	while true:
		var n := bodies.size()
		var A := PackedFloat64Array()
		A.resize(HDR + n * STRIDE + n * 3)
		A[0] = float(A.size()); A[1] = float(n); A[2] = remaining; A[3] = max_step
		A[4] = gw_boost; A[5] = float(guard); A[6] = stepped; A[9] = sim_dt
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
		stepped = A[6]
		var nev := int(A[7])
		resolution_limited = A[8] != 0.0
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
		if resolution_limited or nev == 0 or remaining <= 0.0 or guard >= Derive.STEP_GUARD:
			break
	return {"stepped": stepped, "steps": guard, "resolution_limited": resolution_limited}
