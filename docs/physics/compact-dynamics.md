# Compact-body dynamics

`sim/physics.gd` and the native kernel use symmetric Newtonian gravity for pairs
containing a black hole, with potential `−G m₁ m₂ / r`. Ordinary pairs use the
shared Plummer softening. Both forces match `Derive.total_energy`; with fixed
mass/softening and no drag or mergers, energy drift measures numerical error.
Nonzero separations have no fixed force cutoff, and requested step caps have no
fixed lower floor. The adaptive timestep does not make the entire integration
symplectic.

This is a weak-field orbital model. It has no dynamical ISCO, relativistic
precession, frame dragging or relativistic plunge. Contact remains the
mass-derived Schwarzschild scale; contact merging is an illustrative event,
not a general-relativistic coalescence calculation. Lensing, illustrated discs
and reported Kerr radii do not add those effects to body motion.

The [Paczyński–Wiita construction](https://arxiv.org/html/0904.0913v1) is useful
for test matter around a fixed, nonrotating hole. Its angular frequency is not
the Schwarzschild angular frequency. Applying a different source field to each
member of a moving pair gives unequal opposing forces; it is not a conservative
binary model. A future strong-field mode needs a separately validated dynamical
model, rather than a renamed symmetric pseudo-potential.

## Numerical limits

A positive duration is integrated while representable steps remain and the
8,000-step work budget permits. Caps are upper bounds, including below `1e-8`
years. Existing physical contacts are resolved before selecting the first step;
zero or negative durations do not trigger contacts. Accepted time and successful
step counts remain separate from requested time.

Nonfinite forces, candidate positions/velocities or GW kicks stop integration
and restore that substep's physical state. Unsafe contact candidates are not
published; earlier valid contact events and accepted steps remain committed.
The native wrapper carries accepted time across merger callbacks, so restarting
the kernel cannot silently lose a smaller later increment. The HUD distinguishes
a numerical stop from exhausting the work budget. Elapsed time uses a compensated
remainder to retain accepted intervals smaller than the displayed epoch's ULP.
An explicit epoch assignment clears that remainder.

These guards do not establish scientific accuracy for every finite input.
Extreme products can still underflow in force/energy/strain estimates, ordinary
position increments can disappear below their coordinate's ULP, ordinary body
structures use approximate radius fits, and black-hole inputs must retain
finite positive horizon and evaporation scales. There is no general quantum-gravity
or arbitrary-scale model. `tools/numericalcheck.gd` verifies representative small
resolved systems with analytic forces and orbital convergence in both kernels.

## Illustrative radiation drag

Eligible pairs within 400 times their physical contact-radius sum can receive
a momentum-conserving velocity kick. Its requested power is the circular,
leading-quadrupole value `32 G⁴ m₁² m₂² (m₁+m₂) / (5 c⁵ r⁵)`, multiplied by
`gwBoost`. The kick is capped at 0.25% of relative speed per substep; a speed
floor also limits the near-stationary case. This is an illustration, not the
full 2.5-PN equations of motion. There is no bound-orbit or eccentricity check.
The contact window, multiplier and cap change the resulting loss and timing;
they do not establish a physical chirp, merger or ringdown. See
[Blanchet's review](https://link.springer.com/article/10.12942/lrr-2014-2),
sections 1 and 9, for the conservative and dissipative post-Newtonian terms.

The wide `bhmerger` and `nsmerger` presets retain their IDs for saved selections
and lessons, but show binary orbits with drag off. Their live instrument is a
leading-order strain estimate. The ordinary-star `binarystar` preset retains an
explicitly exaggerated drag demonstration; it is not a physical contact binary
or a model of the hydrodynamics that produces a luminous red nova.

## Live strain estimate

`GWDetector.strain_of` uses actual AU separation, converted to SI, with live
masses and an assumed distance/inclination. Contact and rendered sizes do not
rescale the orbit. For circular motion it estimates `ω² = GM/r³` and
`h₀ = 4G²μM/(c⁴Dr)`; plus/cross amplitudes use ideal inclination factors.
These are leading-quadrupole estimates, as described in section 1.2 of
[Blanchet's review](https://link.springer.com/article/10.12942/lrr-2014-2).
They do not predict an eccentric waveform or include detector antenna response.

The instrument selects the two heaviest live compact bodies, without checking
binding. It unwraps their projected XZ angle, drawing the plus trace from twice
that phase. Its time axis accumulates `|Δphase|/ω`; it is a circular estimate,
not accepted simulation time. Tilt, eccentricity and undersampled rotations can
invalidate that reconstruction. The wide authored views are coplanar examples;
arbitrary edited systems do not inherit quantitative waveform accuracy.
