# Planet map sources

These files are local runtime assets. A fresh clone displays the mapped real
worlds without another download; fictional worlds still use procedural terrain.

| File | Source and processing |
| --- | --- |
| `earth-july.jpg` | [NASA Earth Observatory, Blue Marble: Next Generation, July 2004 with topography](https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/base-topography/). The 5400 × 2700 global JPEG was downsampled to 4096 × 2048. Credit: NASA Earth Observatory / Reto Stöckli. |
| `earth-land.png` | [Natural Earth 1:10m land polygons](https://www.naturalearthdata.com/downloads/10m-physical-vectors/10m-land/), rasterized at 4096 × 2048 in equirectangular longitude/latitude. Natural Earth data are public domain. White is land; black is water. |
| `mars-viking.jpg` | [NASA/JPL/USGS Mars image texture](https://science.nasa.gov/3d-resources/mars/), assembled from Viking imagery, resized from 1440 × 720 to 2048 × 1024 for mipmapping. Credit: NASA/JPL-Caltech/USGS. |
| `moon-lro.jpg` | [NASA Scientific Visualization Studio CGI Moon Kit](https://svs.gsfc.nasa.gov/4720/), 2048 × 1024 natural color LRO Wide Angle Camera mosaic. The original host timed out during this update, so the identical resolution was obtained from [this documented mirror](https://github.com/MaxwellLee/physics-lab/blob/main/assets/textures/SOURCES.md). Credit: NASA SVS / Ernie Wright / LRO-LROC team. |
| `jupiter-cassini.jpg` | [NASA PIA07782, Cassini's best maps of Jupiter: cylindrical map](https://science.nasa.gov/photojournal/cassinis-best-maps-of-jupiter-cylindrical-map/), 3601 × 1801 TIFF from 36 Cassini narrow-angle images, 11–12 December 2000. The flat fill past +88° and −81.5° was replaced by the last real row, then the map was resized to 4096 × 2048. Red was raised 9% and blue lowered 7%, and saturation raised 18%, to bring the mosaic's cool balance toward HST and Juno true-colour views. Credit: NASA/JPL/Space Science Institute. |
| `io-galileo.jpg` | [JPL Planetary Image Atlas](https://maps.jpl.nasa.gov/tmaps/jupiter.html), `jup1vss2.tif`, 1440 × 720: the Caltech/JPL/USGS Voyager mosaic with colour from a Galileo global mosaic. Resized to 2048 × 1024. Saturation was cut to 72% and contrast to 90%, because the mosaic's colour is stretched and true-colour Io is muted yellow and tan. Credit: NASA/JPL-Caltech/USGS. |

All color maps have north at the top, 0° longitude at the middle, and
cover 360° × 180°. `sim/planetmaps.js` loads them on demand and falls back to
the procedural surface if a file is missing. The maps supply color and mapped
features; the simulator supplies lighting, atmosphere, clouds, and extreme
climate overlays. Jupiter's map replaces the procedural cloud bands below
about 76° latitude and turns rigidly with System III: real jets move it by less
than a degree a day. Its polar caps stay procedural. Global source resolution is kilometres per pixel, so the
ground patch adds local texture rather than enlarging pixels into boulders.
The flight map anchors use the [NASA launch-site coordinates in the Starship
environmental assessment](https://netspublic.grc.nasa.gov/main/20190807_Final_DRAFT_EA_SpaceX_Starship.pdf)
for Kennedy Pad 39A and the Boca Chica launch site. The local image is aligned
to the launch pad's simulated position as the body rotates.
