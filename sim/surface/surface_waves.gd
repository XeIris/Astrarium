class_name SurfaceWaves
extends RefCounted

# A sea state from the local wind and the world's own gravity: a JONSWAP spectrum sampled into
# wave trains the ocean shader sums, and the equilibrium tide from the live bodies.
# docs/physics/surface.md#oceans. SI. Exists only while someone stands on the world.

const N := 24
# JONSWAP's peak shape (Hasselmann et al. 1973, via Stewart's Introduction to Physical Oceanography §16.4).
const GAMMA := 3.3
const SIGMA_LOW := 0.07
const SIGMA_HIGH := 0.09
# Pierson-Moskowitz's constants, by which a fully developed sea stops growing.
const PM_ALPHA := 8.1e-3
const PM_HS := 0.22                  # H_s = 0.22 U₁₀²/g
const PM_PEAK := 0.855               # ω_p = 0.855 g/U₁₀, from c_p = 1.17 U₁₀
# Sea water against air, N/m and kg/m³: the capillary term in the dispersion relation.
const SIGMA_WATER := 0.074
const RHO_WATER := 1000.0
const MIN_WIND := 0.05

## Fetch-limited JONSWAP peak ω, rad/s, floored at a fully developed sea's.
static func peak_omega(wind: float, g: float, fetch_m: float) -> float:
	var u := maxf(wind, MIN_WIND)
	var limited := 22.0 * pow(g * g / (u * fetch_m), 1.0 / 3.0)
	return maxf(limited, PM_PEAK * g / u)

## JONSWAP's α, floored at Pierson-Moskowitz's.
static func alpha(wind: float, g: float, fetch_m: float) -> float:
	var u := maxf(wind, MIN_WIND)
	return maxf(0.076 * pow(u * u / (fetch_m * g), 0.22), PM_ALPHA)

## The peak's sharpening: JONSWAP's 3.3 on a growing sea, falling to Pierson-Moskowitz's 1 as it
## develops (JONSWAP with γ = 1 is that spectrum, and a developed sea is no longer peaked up).
static func gamma_of(wind: float, g: float, fetch_m: float) -> float:
	var u := maxf(wind, MIN_WIND)
	var developed := PM_PEAK * g / u
	var limited := 22.0 * pow(g * g / (u * fetch_m), 1.0 / 3.0)
	return 1.0 + (GAMMA - 1.0) * clampf(limited / developed - 1.0, 0.0, 1.0)

## Spectral density S(ω) m²s at ω.
static func spectrum(omega: float, wind: float, g: float, fetch_m: float) -> float:
	var wp := peak_omega(wind, g, fetch_m)
	var a := alpha(wind, g, fetch_m)
	var sigma := SIGMA_LOW if omega <= wp else SIGMA_HIGH
	var q := (omega - wp) / (sigma * wp)
	var r := exp(-0.5 * q * q)
	return a * g * g / pow(omega, 5.0) * exp(-1.25 * pow(wp / omega, 4.0)) * pow(gamma_of(wind, g, fetch_m), r)

## Wavenumber at ω over `depth` m, by Newton on ω² = (gk + σk³/ρ) tanh(kh).
static func wavenumber(omega: float, g: float, depth: float, rho := RHO_WATER, surface_tension := SIGMA_WATER) -> float:
	var w2 := omega * omega
	var k := w2 / g
	for i in 12:
		var th := tanh(minf(k * depth, 20.0))
		var f := (g * k + surface_tension / rho * k * k * k) * th - w2
		var sech2 := 1.0 - th * th
		var df := (g + 3.0 * surface_tension / rho * k * k) * th + (g * k + surface_tension / rho * k * k * k) * depth * sech2
		var step := f / maxf(df, 1e-12)
		k = maxf(k - step, 1e-9)
		if absf(step) < 1e-9 * k: break
	return k

## Wave trains on a frequency set wide enough for any wind this site's weather brings, so a wind change
## moves amplitudes and never a phase. Each: {omega, k, dir, phase, dw, amp}. Directions are offsets from
## the wind's, drawn narrower at the peak (a choice), and `seed` makes a site's sea its own.
static func make_trains(mean_wind: float, g: float, depth: float, seed: int) -> Array:
	var calm := maxf(mean_wind * 0.3, 0.3)
	var gale := maxf(mean_wind * 4.0, 3.0)
	var lo := PM_PEAK * g / gale * 0.7
	var hi := PM_PEAK * g / calm * 4.0
	var ratio := pow(hi / lo, 1.0 / float(N))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var trains := []
	var w0 := lo
	for i in N:
		var w1 := w0 * ratio
		var w := sqrt(w0 * w1)
		trains.append({"omega": w, "dw": w1 - w0, "k": wavenumber(w, g, depth),
			"dir": rng.randfn(0.0, 0.45), "phase": rng.randf() * TAU, "amp": 0.0, "angle": 0.0})
		w0 = w1
	return trains

## Fill the trains for this wind and fetch. Returns the sea state: {hs, m0, peak_period, wind, fetch}.
static func fill(trains: Array, wind: float, wind_dir: float, g: float, fetch_m: float) -> Dictionary:
	var m0 := 0.0
	for t: Dictionary in trains:
		var s := spectrum(float(t.omega), wind, g, fetch_m)
		var e := s * float(t.dw)
		m0 += e
		t.amp = sqrt(2.0 * e)
		t.angle = wind_dir + float(t.dir)
	return {"hs": 4.0 * sqrt(m0), "m0": m0, "peak_period": TAU / peak_omega(wind, g, fetch_m), "wind": wind, "wind_dir": wind_dir, "fetch": fetch_m}

## H_s of a fully developed sea, m.
static func developed_hs(wind: float, g: float) -> float:
	return PM_HS * wind * wind / g

## Whether a wind can raise gravity waves at all: the minimum phase speed of gravity-capillary waves
## is (4gσ/ρ)^¼, 0.23 m/s on Earth, and air must push at it.
static func min_phase_speed(g: float, rho := RHO_WATER, surface_tension := SIGMA_WATER) -> float:
	return pow(4.0 * g * surface_tension / rho, 0.25)

## The equilibrium tide at unit direction `up` on a world, m: Σ γ(m/M)(R/d)³R(3cos²ψ − 1)/2 over the
## other bodies, read live. `up_world` is the site's direction in the orrery's axes.
## Returns {height, rows: [{name, amp}]} with each body's full semi-range (m/M)(R/d)³R·(3/4)·γ's.
static func tide(world: Body, up_world: Vector3, bodies: Array) -> Dictionary:
	var R: float = world.radius * Rocketry.AU_M
	var k2 := float(U.nz(world.spec.get("k2"), 0.0))
	# h₂ ≈ 2.04 k₂ for Earth (0.609, 0.299): γ = 1 + k₂ − h₂ = 0.69, the elastic Earth's yield.
	var gamma := 1.0 - 1.04 * k2
	var total := 0.0
	var rows := []
	for b: Body in bodies:
		if b == world or not b.alive or b.mass <= 0.0: continue
		var d_vec: DVec3 = b.pos.sub(world.pos)
		var d_au := d_vec.length()
		if d_au <= 0.0: continue
		var d := d_au * Rocketry.AU_M
		var scale: float = (b.mass / world.mass) * pow(R / d, 3.0) * R * gamma
		if scale < 1e-4: continue
		var cos_psi := clampf(float(d_vec.x / d_au) * up_world.x + float(d_vec.y / d_au) * up_world.y + float(d_vec.z / d_au) * up_world.z, -1.0, 1.0)
		var h := scale * 0.5 * (3.0 * cos_psi * cos_psi - 1.0)
		total += h
		rows.append({"name": b.name, "scale": scale, "height": h})
	rows.sort_custom(func(a, c): return a.scale > c.scale)
	return {"height": total, "rows": rows}

## A shader's arrays: xy the wave vector, z the amplitude, w ω; and the phases.
static func shader_arrays(trains: Array) -> Dictionary:
	var waves := PackedVector4Array()
	var phases := PackedFloat32Array()
	for t: Dictionary in trains:
		# A bearing from north towards east; the site's x runs west and its z north.
		waves.append(Vector4(-float(t.k) * sin(float(t.angle)), float(t.k) * cos(float(t.angle)), float(t.amp), float(t.omega)))
		phases.append(float(t.phase))
	return {"waves": waves, "phases": phases}
