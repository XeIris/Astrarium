# Compact-body dynamics

`sim/physics.gd` and the native kernel use symmetric Newtonian gravity for pairs
containing a black hole, with potential `−G m₁ m₂ / r`. Ordinary pairs use the
shared Plummer softening. Both forces match `Derive.total_energy`; with fixed
mass/softening and no drag or mergers, energy drift measures numerical error.
These claims apply to resolved separations: both kernels skip forces below
`1e-9 AU`, and integration has a `1e-8 year` step floor. Arbitrarily tiny authored
systems are not validated by the structural input gate. The adaptive timestep
does not make the entire integration symplectic.

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
