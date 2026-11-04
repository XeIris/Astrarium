# Third-party code and data

Astrarium's own code, documentation, Blender model scripts and generated
material textures are under the [MIT License](LICENSE). The files below come
from elsewhere and keep their own terms, which take precedence over the MIT
License for those files. Each entry says where the file came from and what it
asks of a redistributor.

## Code

| what | where | terms |
|---|---|---|
| Godot Engine 4.7 | not vendored; the editor and export templates are downloaded | MIT, © Godot Engine contributors. An exported build contains the engine, so ship Godot's licence notice and its third-party notices with it ([Godot: complying with licenses](https://docs.godotengine.org/en/stable/about/complying_with_licenses.html)) |
| GDExtension interface header | `native/gdextension_interface.h` | MIT, © Godot Engine contributors; the notice is kept in the file |
| three.js 0.160.0 | loaded from a CDN by the archived `web/` build; not vendored | MIT, © three.js authors |
| ERFA (IAU 2000B nutation series) | `sim/observatory/nutation2000b.gd`, built by `tools/build_nutation.py` from ERFA's `src/nut00b.c` | BSD-3-Clause, © 2013–2023 NumFOCUS Foundation; ERFA is derived from the IAU SOFA library. Full terms [below](#erfa); source: [liberfa/erfa](https://github.com/liberfa/erfa/blob/master/LICENSE) |
| d3-celestial (constellation boundaries) | `assets/sky/constellations.json` (`bounds`), built by `tools/build_constellations.py` from `data/constellations.bounds.json` | BSD-3-Clause, © 2015 Olaf Frohn; full terms [below](#d3-celestial); source: [ofrohn/d3-celestial](https://github.com/ofrohn/d3-celestial/blob/master/LICENSE); the boundaries themselves are the IAU's, from CDS VI/49 (Davenhall & Leggett 1989) |

## Data that carries conditions

| what | where | terms |
|---|---|---|
| Gaia DR3 stars, G 6.5–8 | `assets/sky/gaia_g8.bin`, built by `tools/build_gaia.py` | **CC BY-SA 3.0 IGO.** Credit: ESA/Gaia/DPAC (Gaia Collaboration, Vallenari et al. 2023). `gaia_g8.bin` (positions, magnitudes, colours and proper motions) is a derivative and stays under CC BY-SA 3.0 IGO when redistributed, whatever the rest of the project's licence ([sky.md](docs/physics/sky.md#catalogue-stars)) |

## Public-domain and freely usable data

These need no permission. The credits are given as their sources ask.

| what | where | source and credit |
|---|---|---|
| Earth colour map | `assets/planet-maps/earth-july.jpg` | NASA Earth Observatory, Blue Marble: Next Generation. Credit: NASA Earth Observatory / Reto Stöckli |
| Earth land mask | `assets/planet-maps/earth-land.png` | Natural Earth 1:10m land polygons, public domain |
| Mars, Moon, Jupiter and Io maps | `assets/planet-maps/` | NASA/JPL-Caltech/USGS, NASA SVS (LRO), NASA PIA07782 (Cassini), JPL Planetary Image Atlas (Voyager/Galileo). Per-file credits and processing are in [assets/planet-maps/README.md](assets/planet-maps/README.md) |
| Yale Bright Star Catalogue, 5th ed. | `assets/sky/bsc5.bin` and the figure stars of `assets/sky/constellations.json`, built by `tools/build_starcat.py` and `tools/build_constellations.py` | Hoffleit & Warren (1991), via NASA HEASARC's BSC5P table |
| Measured ΔT | `sim/observatory/deltat.gd`, built by `tools/build_deltat.py` | U.S. Naval Observatory, IERS Rapid Service/Prediction Centre (`maia.usno.navy.mil/ser7/historic_deltat.data`, `deltat.data`), U.S. Government work |
| Lunar gravity field GL0420A | `sim/flight/lunar_gravity.gd`, built by `tools/build_lunar_gravity.py` | NASA GRAIL, PDS Geosciences Node (Konopliv et al. 2013) |
| Planetary gravity coefficients | `sim/flight/rocketry.gd` | Earth: EGM2008 (U.S. National Geospatial-Intelligence Agency); Mars: MRO120D (Konopliv et al. 2016); Jupiter: Juno (Iess et al. 2018) |
| US Standard Atmosphere 1976 | `sim/flight/rocketry.gd` | NOAA/NASA/USAF (NASA-TM-X-74335), public domain |

## Values from published papers

Tables and coefficients taken from the scientific literature are facts, used
with citations: for example Claret (2000) limb darkening (`sim/limbdark.gd`, from
VizieR J/A+A/363/1081), the Saturn V axial-force curves digitized from Boeing
D5-15481-1, DLR's Falcon 9 return drag (Bykerk & Horchler 2024), JPL's planetary
elements and DE440 masses, the ELP-2000/82 lunar terms as Meeus (Astronomical
Algorithms, ch. 47) truncates them (`sim/observatory/lunar.gd`), the Espenak & Meeus
ΔT polynomials, the IAU 2006 precession, and IAU, IERS and CODATA constants. The
Observatory's reference values come from JPL Horizons, the USNO's data services and
IAU SOFA (`tools/observatorycheck.gd`). Each value's
source is cited where it is used, in the code and in [docs/physics/](docs/physics/).

## Designs from fiction

The Hail Mary and the Beetle probes are inspired by *Project Hail Mary*, and
future craft inspired by films are planned. These are our own models built from
our own Blender scripts. The MIT License covers that code and geometry only.
It grants no rights in the original works' names, designs or characters, which
belong to their owners.

## Licence texts

Reproduced as these licences require a redistribution to do.

### ERFA

As it stands in ERFA's `nut00b.c`:

```text
Copyright (C) 2013-2023, NumFOCUS Foundation.
All rights reserved.

This library is derived, with permission, from the International
Astronomical Union's "Standards of Fundamental Astronomy" library,
available from http://www.iausofa.org.

The ERFA version is intended to retain identical functionality to
the SOFA library, but made distinct through different function and
file names, as set out in the SOFA license conditions.  The SOFA
original has a role as a reference standard for the IAU and IERS,
and consequently redistribution is permitted only in its unaltered
state.  The ERFA version is not subject to this restriction and
therefore can be included in distributions which do not support the
concept of "read only" software.

Although the intent is to replicate the SOFA API (other than
replacement of prefix names) and results (with the exception of
bugs;  any that are discovered will be fixed), SOFA is not
responsible for any errors found in this version of the library.

If you wish to acknowledge the SOFA heritage, please acknowledge
that you are using a library derived from SOFA, rather than SOFA
itself.


TERMS AND CONDITIONS

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

1 Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.

2 Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in
  the documentation and/or other materials provided with the
  distribution.

3 Neither the name of the Standards Of Fundamental Astronomy Board,
  the International Astronomical Union nor the names of its
  contributors may be used to endorse or promote products derived
  from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE
COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### d3-celestial

From the project's `LICENSE`:

```text
Copyright (c) 2015, Olaf Frohn
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
