# Planet map sources

These files are local runtime assets. A fresh clone displays the mapped real
worlds without another download; fictional worlds still use procedural terrain.

| File | Source and processing |
| --- | --- |
| `earth-july.jpg` | [NASA Earth Observatory, Blue Marble: Next Generation, July 2004 with topography](https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/base-topography/). The 5400 × 2700 global JPEG was downsampled to 4096 × 2048. Credit: NASA Earth Observatory / Reto Stöckli. |
| `earth-land.png` | [Natural Earth 1:10m land polygons](https://www.naturalearthdata.com/downloads/10m-physical-vectors/10m-land/), rasterized at 4096 × 2048 in equirectangular longitude/latitude. Natural Earth data are public domain. White is land; black is water. |
| `mars-viking.jpg` | [NASA/JPL/USGS Mars image texture](https://science.nasa.gov/3d-resources/mars/), assembled from Viking imagery, resized from 1440 × 720 to 2048 × 1024 for mipmapping. Credit: NASA/JPL-Caltech/USGS. |
| `moon-lro.jpg` | [NASA Scientific Visualization Studio CGI Moon Kit](https://svs.gsfc.nasa.gov/4720/), 2048 × 1024 natural color LRO Wide Angle Camera mosaic. The original host timed out during this update, so the identical resolution was obtained from [this documented mirror](https://github.com/MaxwellLee/physics-lab/blob/main/assets/textures/SOURCES.md). Credit: NASA SVS / Ernie Wright / LRO-LROC team. |

All three color maps have north at the top, 0° longitude at the middle, and
cover 360° × 180°. `sim/planetmaps.js` loads them on demand and falls back to
the procedural surface if a file is missing. The maps supply color and mapped
features; the simulator supplies lighting, atmosphere, clouds, and extreme
climate overlays. Global source resolution is kilometres per pixel, so the
ground patch adds local texture rather than enlarging pixels into boulders.
The flight map anchors use the [NASA launch-site coordinates in the Starship
environmental assessment](https://netspublic.grc.nasa.gov/main/20190807_Final_DRAFT_EA_SpaceX_Starship.pdf)
for Kennedy Pad 39A and the Boca Chica launch site. The local image is aligned
to the launch pad's simulated position as the body rotates.
