# Neutron-star light bending

The surface shader uses the approximate cosine relation from
[Beloborodov (2002), equation 1](https://arxiv.org/html/astro-ph/0201117v1),
not numerical ray tracing. For a spherical star in Schwarzschild spacetime,
with emission angle α to the local radial direction and surface colatitude ψ
from the distant observer's axis:

```
u = r_s/R,  r_s = 2GM/c²
1 − cos α ≈ (1 − cos ψ)(1 − u)
cos ψ ≈ 1 − (1 − cos α)/(1 − u)
```

Here r_s ≈ 2.95 km per M☉ (about 4.13 km for 1.4 M☉).

The paper restricts this relation to R ≥ 2 r_s (u ≤ 0.5). Accuracy depends on
angle and compactness: at R = 3 r_s the bending-angle error reaches 3% at
α = 90°, and stays below 1% for α < 75°. It worsens near u = 0.5 and the limb.

Tangential emission (cos α = 0) gives cos ψ_limb ≈ −u/(1 − u), hence a visible
surface fraction ≈ 1/[2(1 − u)]. At u = 0.4 this is 83.33%, with ψ_limb ≈ 131.81°.
The paper's exact visibility table gives 81.65% at that compactness (§3).

`sim/neutron_visual.gd` derives `uCompact` from `b.rs/b.radius`, both in AU,
independently of scene magnification. The default is 0.4; display values are
clamped to 0.15–0.5. The lower bound is an illustrative display floor; above
0.5 the image uses the boundary approximation, without changing physical
compactness. Such capped images do not model the additional strong bending.
The lesson's 1.4 M☉ pulsar has a modeled radius about 12.48 km and u ≈ 0.331.

`shaders/bodies/neutron_surface.gdshader` substitutes the apparent mesh-disc
cosine `mu` for cos α, then remaps surface coordinates with the relation above.
It clamps cos ψ to [−1, 1]. The bright rim, cap intensity and beam pulse are
stylized; they do not integrate the paper's observed-flux formula. The mapping
omits rotational spacetime, oblateness and finite observer-distance corrections.
