# The Voyager mission archive

Spaceflight → Voyager 1 or Voyager 2 → Start mission opens at the instant Voyager 1 reached one light-day from Earth. The probes share a UTC clock. Type a year, date or exact timestamp into the clock and press Enter to jump there. Change spacecraft to compare their locations on the same date. Each mission begins at its own launch. The archive ends on 19 November 2026. The command-line entry points are `mode=flight craft=voyager1` and `mode=flight craft=voyager2`.

## Reading the flight path

The solid lines trace the paths already flown. The rings mark heliocentric distances in the J2000 ecliptic plane. The vertical dashed lines drop the probes onto that plane. Rotate the map to see how the Titan–Saturn passage took Voyager 1 north and the Neptune–Triton passage sent Voyager 2 south. Distances on the scale bar are projected sky-plane lengths. The numerical readouts use all three coordinates.

A flyby bookmark switches to a frame centred on the encounter body. The solid track arrives and the dashed track departs. Both subtract the target at each sample time. The encounter clock spans twelve hours on either side of the landmark. The full mission slider, landmark menu and play controls remain available.

The offline archive combines JPL Horizons cruise tracks with JPL’s reconstructed Voyager navigation kernels at the encounters. All positions are geometric, Sun-centred J2000 ecliptic XYZ in AU. Each sample carries a velocity in AU/day. Cubic Hermite interpolation joins samples on a UTC clock. The centre-to-centre ranges and light times use this same geometry. [Horizons API](https://ssd-api.jpl.nasa.gov/doc/horizons.html) · [NAIF Voyager SPKs](https://naif.jpl.nasa.gov/pub/naif/VOYAGER/kernels/spk/)

Cruise samples are 28 days apart. Within 15 days of each giant-planet encounter the spacing tightens to 12 hours. Within three days, the builder samples the navigation SPK every ten minutes. The Jupiter passes use `vgr1_jup230` and `vgr2_jup230`, the Saturn passes use `vgr1_sat337` and `vgr2_sat337`, and Voyager 2 uses `vgr2.ura182` at Uranus and `vgr2_nep097` at Neptune. The builder gives the encounter kernel priority over DE440s and uses the associated satellite solution when available. Jupiter and Io use Horizons for their centre positions. The four moon tracks cover six days each at 20-minute spacing.

The displayed encounter distance is measured from the body’s centre. For example, the reconstructed Neptune range is about 29,300 km at the flyby bookmark, consistent with a passage about 5,000 km above the clouds. The patched-conic cruise ephemerides and the navigation solutions are joined outside the encounter window. Later interstellar positions come from JPL’s 2022 refits to tracking through 1992. The first spacecraft vectors start about an hour after launch. During that gap the map identifies Earth as the launch location. [NASA planetary encounter distances](https://nssdc.gsfc.nasa.gov/planetary/voyager-periapse.html) · [Voyager 2 mission history](https://science.nasa.gov/mission/voyager/voyager-2/)

To regenerate the archive, install `spiceypy` in a Python environment and run `python3 tools/build_voyager.py`. The optional `--kernels /path/to/cache` retains the downloaded SPKs and leap-second kernel. Godot ships the baked resource and runs the replay offline.

## The mission clock

Planetary closest approaches use the Voyager Project table of spacecraft-event UTC. In particular, Voyager 2 passed Saturn at 03:24:57 UTC on 26 August 1981, still 25 August in California. The Miranda bookmark uses the reconstructed minimum rounded to the nearest minute. A published date without a time opens at the start of that UTC day. [Closest approaches](https://nssdc.gsfc.nasa.gov/planetary/voyager-periapse.html) · [Voyager 1 history](https://science.nasa.gov/mission/voyager/voyager-1/) · [Voyager 2 history](https://science.nasa.gov/mission/voyager/voyager-2/) · [Io encounter](https://doi.org/10.1029/2010JA016094) · [PDS encounter archive](https://search-pdsppi.igpp.ucla.edu/mission/VOYAGER)

Voyager 1 photographed Earth for the family portrait at 04:48 UTC on 14 February 1990. The twins crossed the heliopause on 25 August 2012 and 5 November 2018. On 18 November 2026 at 10:16:07 UTC, Voyager 1 was about 173.145 AU from Earth and 172.389 AU from the Sun. The displayed one-way light time divides the simultaneous geometric Earth–probe range by the speed of light. [Pale Blue Dot](https://science.nasa.gov/mission/voyager/voyager-1s-pale-blue-dot/) · [Interstellar mission](https://science.nasa.gov/mission/voyager/interstellar-mission/) · [NASA light-day milestone](https://science.nasa.gov/mission/voyager/where-are-voyager-1-and-voyager-2-now/)

## The deployed spacecraft

NASA identifies the two spacecraft as identical in design. The shared metre-scale model depicts the deployed configuration throughout the archive. Its inspection camera can orbit the bus, dish, instrument platform, power boom and engraved cover. Historical spacecraft roll, scan-platform movements and the launch deployment sequence are outside the reconstruction. [Instruments and design](https://science.nasa.gov/mission/voyager/instruments/) · [Flight-module engineering drawing, TC-6 Voyager flight data report](https://www.nasa.gov/wp-content/uploads/2025/06/tc-6-voyager-flight-data-report-1976.pdf)

The mesh and texture atlases come from NASA Visualization Technology Applications and Development. The preparation script sets scale from the 3.7 m dish and fits both plasma-wave antennas to their documented orthogonal 10 m elements, retaining their feed locations. The engraved cover photograph maps onto the existing 30 cm face on the side of the bus. To reproduce the mesh, download the original glTF binary and run `python3 model_sources/voyager.py /path/to/Voyager.glb`. [VTAD spacecraft download](https://science.nasa.gov/resource/voyager-3d-model/) · [Plasma-wave instrument paper](https://pds.nasa.gov/data/vg1-j-spice-6-spk-v2.0/vg_1501/document/pws/pwsinst.htm)

| Reference in the viewer | What to compare |
|---|---|
| JPL spacecraft rendering | Scan platform, calibration target, magnetometer mast and placement of the three power generators. [NASA/JPL-Caltech, PIA14111](https://science.nasa.gov/photojournal/model-of-voyager-artist-concept/) |
| Instrument drawing | Direction of the booms, cameras and radiometer relative to the dish. [NASA/JPL-Caltech](https://science.nasa.gov/mission/voyager/instruments/) |
| Golden Record installation | Engineers securing the cover on Voyager 1 in 1977. [NASA/JPL-Caltech, PIA21740](https://science.nasa.gov/photojournal/voyager-installing-the-golden-record/) |
| Engraved cover | Playback diagrams, image encoding, pulsar map and the hydrogen transition. [NASA/JPL](https://science.nasa.gov/mission/voyager/golden-record-cover/) |
