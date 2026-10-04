# Numerical representability

Physics uses binary64 positions, velocities and accepted coordinate time.
Finite input components do not establish physical validity or accuracy for every
combination of mass, separation, velocity and step size. Structure validates its
own model domain before stage mutation; the kernels reject detected unsafe
arithmetic and return the accepted prefix with `resolution_limited`.

Both kernels reject a candidate when a body has nonzero velocity, zero old and
new acceleration, and its entire position increment disappears. Candidate state
rolls back; its elapsed time is not accepted. A stationary body may advance time.
An accelerated body can gain a resolved velocity before position changes become
representable, so an unchanged position alone is insufficient to reject a step.

`Derive.total_energy` retains ordinary operation order. Exceptional kinetic,
potential and softened-distance intermediates are rescaled by binary powers to
recover representable terms without introducing a physics cutoff. A genuinely
unrepresentable positive term makes the diagnostic unavailable (`NAN`); singular
potential remains `-INF`. This is strict term availability even when another term
would dominate the sum. True zero energy remains valid. The HUD discards invalid
baselines and restarts when the diagnostic recovers; relative drift from a zero
reference to nonzero energy is undefined and shown as unavailable.

The numerical gate includes analytic extreme-energy fixtures, rounded subnormal
terms, an ordinary bit-exact expression, lost-drift rollback and accepted-prefix
checks in both kernels. Native/reference agreement alone cannot validate these.

Individual drift components, accelerated kicks and extreme force intermediates
can still lose precision. Closely cancelling energy sums and long-run phase
accuracy need independent convergence evidence. These guards are not universal
finite-input safety or a promise that a larger step solves a precision limit.
