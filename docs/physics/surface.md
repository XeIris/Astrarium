# The surface: `sim/planet_relief.gd`, `sim/planet_pin.gd`

What a world is like at one point on it. It reads the world's gravity, air, water and temperature
and writes nothing back.

## The pin

`PlanetPin` draws a latitude and longitude uniform on the sphere (uniform in sin φ), from a hash of the
world's seed, the run's `seed=` and the pin's number, so the same scenario always gets the same sequence.

It reads what is there from what the planet draws. `PlanetRelief` is the CPU half of
`terrain.gdshaderinc`, and `pincheck gpu=1` renders the shader's height at 8192 random points and holds the
two to each other: a mean difference of 0.0 m, a worst of 2.8 m, and no disagreement about sea and land.

To make that possible the rocky surface's noise uses an integer lattice hash, PCG3D ([Jarzynski &
Olano 2020](https://jcgt.org/published/0009/03/02/)), rather than `fract(sin(x)·43758)`: a GPU's `sin` cannot be
reproduced on a CPU, and at that multiplier an error of one part in 10⁶ moves the result by 0.04. `Vector3` is
float32, as the shader is, so high octaves round alike. Cloud decks, giants and rings keep their hash.

This re-rolled the geography of every unmapped rocky world once. Its statistics stayed: over 40 seeds the fBm has a
mean of 0.492 and an sd of 0.110 against the 0.497 and 0.1065 `Terrain.crust_threshold` assumes, and asking for 29%
land gives 28.9%.

A pin does not hunt for land. It says what it found: open sea and how deep, sea ice, an ice sheet, or the biome and
its height. On Earth it falls on land about 29% of the time, as it should. **A mapped world** (Earth, Mars, the Moon)
keeps its map's coast and its height is the procedural crust's, not a measurement, and the panel says so.
