# Movie-inspired spacecraft, phases 2–4

All models are original scripted Blender reconstructions for phases 2–4 of
[issue 26](https://github.com/XeIris/Astrarium/issues/26). Photographs inform shape
and finish. The Ranger has an inhabited flight deck. Discovery's enclosed rotor
and Endurance's spin telemetry illustrate the gravity systems. Fuller interiors
for the larger ships are phase 5.

Build the authored assets with `model_sources/blender/build.sh ranger discovery lander endurance`.
Select each ship in the Spaceflight hangar. Enable Developer mode in Settings ›
Controls to open scenarios, or pass `scenario=<vehicle>:<id>` on the command line.

## Ranger reconstruction

The Blender model was inspected from front, rear, side, plan and below, then
through the production flight renderer. The 17.9 m length and 9.7 m span are
reconstruction estimates. The photographed plan and side profile inform the
low canopy, clipped triangular foredeck and broad shoulder break about a third
of the length forward of the stern. The swept chines end in free tips beside
the bow. A radiator belt crosses the deck ahead of the recessed axial port.
The filming miniature supplies the uneven groups of chamfered canopy apertures.
[Exhibited prop](https://hollywoodmoviecostumesandprops.blogspot.com/2017/08/tars-robot-and-space-shuttle-models.html)
[New Deal Studios filming miniature](https://www.fxguide.com/wp-content/uploads/2014/12/IMG_3278_LARGE.jpg)

`vehicles.gd` owns these dimensions, mass, propulsion and camera datums. `RangerCraft.geometry`
exports the same skin, apertures, chines and wheel wells to Blender and the
procedural fallback. Blender adds gaskets, blanket seams, radiator ribs, nozzle
walls and cabin fittings.

The chemical OMS estimate is two 45 kN engines at 360 s vacuum Isp, 6 t main
propellant and 14.5 t dry mass. Aerodynamics reuse the Shuttle coefficient family
on an estimated 85 m² lifting area. This is an orbit-to-ground shuttle model;
the film's extraordinary single-stage ascent is not represented.

The cockpit loads only on entry. Its up direction is +Z in the stage frame,
separate from the +Y thrust axis; camera yaw uses that cabin vertical. G lowers
three independently hinged wheel assemblies. The stowed tyres fit above the
belly and the extended struts place them at the catalogue's ground contacts. The seven
trailing control surfaces reuse the guidance's existing command ordering; this
is an estimated control layout. Screens and switches are visual fittings.

The cockpit detail pass adds a roof-mounted instrument spine, handholds, a
multi-display centre stack and distinct flight, propulsion and cabin screens.
The inset pressure liner shares the exterior aperture vertices. Moulded seals
connect the liner to the hull, with brushed frames and small-scale quilted fabric
between the windows. Paired ceiling strips illuminate bolted instrument frames,
labelled rotary selectors, a ribbed aisle and webbed equipment lockers around
the aft pressure hatch. The mounts fit the hull and both port canopy sightlines
were checked from the pilot eye.

The headless return check flew a 250 km orbit through a paid deorbit burn,
atmospheric entry, banking reversals, glide, preflare and rollout. Touchdown was
0.73 m/s sink at 79.1 m/s ground speed, and wheel stop followed after 1.86 km.
Orbit, entry-interface and preflare scenarios also pass played-flight replay.
Development and asset gates cover all fourteen authored models (28 parity poses).
The Ranger-specific sweep checks ground contact, attachment, cockpit sightlines,
camera frames, finish maps and repeated entry in both build paths.

Observation sources:

- [Ian Hunter, miniature VFX supervisor interview](https://www.artofvfx.com/interstellar-ian-hunter-miniature-vfx-supervisor-co-founder-new-deal-studios/):
  practical miniature construction, Shuttle heat tiles, quilted insulation and
  familiar aerospace hardware as the material direction.
- [Chris Kieffer, film graphics designer](https://www.chriskieffer.com/work/interstellar):
  practical cockpit photographs, two-seat layout, centre stack, overhead windows,
  graphite instrument cabinets and pale structural framing. Our display graphics
  are newly drawn static schematics, not copied film graphics or live instruments.
- The two exhibited miniatures show distinct planforms. The Ranger has one
  tapered lifting body and the Lander carries two large faceted cargo pods.
  [Exhibit photographs](https://hollywoodmoviecostumesandprops.blogspot.com/2017/08/tars-robot-and-space-shuttle-models.html)
  [Smithsonian Ranger photograph](https://airandspace.si.edu/multimedia-gallery/image/9568hjpg)
- [Moebius kit from several angles](https://thegreatcanadianmodelbuilderswebpage.blogspot.com/2015/08/ranger-from-intersteller.html):
  supplementary rear and planform observation; a model is secondary evidence.

Build with `model_sources/blender/build.sh ranger`. Capture inspection views using
`tools/moviecraftshots.tscn -- v=ranger dump=/absolute/directory`. Numeric geometry
and lifecycle assertions run headless in `tools/rangercheck.gd` with either asset
path. `tools/rangerflightcheck.tscn` flies the production deorbit-to-rollout loop.

## Discovery reconstruction

The 103 m envelope and 11.44 m command sphere follow the published miniature
proportions at the existing EVA pod's scale. The [studio-reference collection](https://starshipmodeler.com/2001/2001ref.htm)
describes a 54 ft model with a 6 ft sphere and a 13 inch pod miniature, while
discussing the discrepancy with the 700 ft design concept. These figures do not
define a consistent full-size engineering drawing. Our rounded dimensions are a
documented reconstruction choice. The hull includes a small allowance for raised
bay seals in its overall length datum.

Three EVA pods sit behind independently driven curved covers. The covers follow
idealised circumferential tracks. The bay furniture was trimmed against the
spherical shell, and the common berth and opening datums were revised after
checking the stowed pod's full translation through each aperture. Equipment
panels, drawers and work lights sit behind the docking cradles. All three
reflectors point aft in the default pose. Each 4.38 m flared drive housing
joins its fixed corrugated duct at the gimbal coupling. The reconstructed
reactor starts 8.7 m forward of the exhaust plane. The studio and supplementary
aft-model photographs inform the proportions of the three drive assemblies.
[Studio photographs](https://starshipmodeler.com/2001/2001ref.htm)

`evapod:pod_berth` flies a live RCS approach from 12 m off the empty middle berth.
The scenario and played replays both captured at about 0.034 m/s after 53.15 s,
using 0.694 kg of reaction-control propellant. Capture couples the pod rigidly to
the carrier after position, orientation, speed and rate gates. Docking contact
compliance and recoil are omitted.

The propulsion estimate is three 100 kN nuclear modules at 4,000 s Isp with
80 t dry mass and 80 t hydrogen. Each visual drive module has two main outlets.
Its thrust and effective nozzle diameter represent the pair. A historical NASA
gas-core concept examined a comparable thrust and Isp range. Our values are
estimates for the simulation. Reactor mass, shielding and heat rejection remain
unresolved in the radiator-free filming silhouette.
[NASA gas-core engine study](https://ntrs.nasa.gov/citations/19710010425)

The 4.6 m rotor at 8 rpm produces about 0.329 g. Telemetry evaluates
`g = omega² r` and `2 v / (omega r)` for a 1.4 m/s walker, giving a Coriolis to
floor-gravity ratio of about 0.73. Its phase follows accepted ship time. The
vehicle description and telemetry identify the omission of rotor angular
momentum exchange with the hull.

`jovian_voyage` adds Io, Europa, Ganymede and Callisto on approximate circular
equatorial orbits, conserving the original Jovian system mass and barycentre.
The starting phases are illustrative. Exospheres use zero continuum gas column.
[NASA satellite factsheet](https://nssdc.gsfc.nasa.gov/planetary/factsheet/joviansatfact.html)

From the 1,000 km Earth assembly orbit, choose Jupiter in the ordinary mission
planner. The porkchop departure uses finite burns and the arrival target is a
100,000 km propulsive parking orbit under Jupiter's zonal potential. The complete
production-guidance check finished in an approximately 90,079 × 91,439 km orbit
with eccentricity 0.004234 and 10.68 t of main propellant left. All four moons
remained in their expected orbital bands. Use `discovery:departure` and
`discovery:jupiter_orbit` to inspect the departure and nominal arrival fixtures.

## Endurance and Lander reconstruction

Endurance's 65 m ring diameter is judged from the 14 ft miniature built at 1:15
scale. The separate 51.7 m axial envelope includes the berthed Ranger. Twelve
bevelled modules alternate insulated service panels and ribbed radiator banks.
One stepped pressure tunnel joins the axial hub to the ring. Rounded
intermodule junctions connect the modules. Axial and transverse adapters carry
the same original Ranger and Lander models used in the hangar. The axial adapter
meets the Ranger's recessed docking port while leaving clearance at its nozzles.
The transverse adapter seats the Lander on the opposite side of the hub from the
tunnel. Both model paths share the berth and tunnel datums.
[New Deal Studios miniature photographs and scale](https://www.fxguide.com/fxfeatured/real-and-raw-the-miniature-fx-behind-interstellar/)

The separate 21.4 × 18.6 m Lander uses the Ranger scale as a reconstruction
reference. Three passes shaped the stepped 18-aperture canopy, waisted faceted
cargo pods and their load bridges. Pale quilted blankets, dark heat shielding,
brushed access hardware and fitted glazing seals use original materials. Its
dorsal collar sits on the sloped deck behind the canopy. The six 90 kN outlets
at 370 s Isp are a chemical propulsion estimate for this vehicle. Vertical
landing and single-stage ascent are outside the model.
[Exhibited Ranger and Lander props](https://hollywoodmoviecostumesandprops.blogspot.com/2017/08/tars-robot-and-space-shuttle-models.html)

The ring's twelve 25 kN outlets at 2,000 s Isp are a fictional plasma propulsion
estimate. At 5 rpm the 30.5 m floor produces about 0.85 g, with a Coriolis to
floor-gravity ratio of about 0.18 at 1.4 m/s. The spin follows accepted proper
time, with angular momentum exchange omitted. `ranger:spin_match` starts 16 m off the
axial berth and uses the approaching Ranger's RCS to match the ring's pose and
spin. The scenario captured after 76.90 s at 0.0341 m/s and 5.00 rpm, using
37.383 kg of RCS propellant. A played 60 fps replay also passed the gates.

`endurance:kerr_orbit` uses the isolated `gargantua_demo` preset, a 100 million
solar mass black hole with spin 0.998. At 3.5 GM/c², the prescribed equatorial
orbit has a coordinate period of about 6 h 29 min and a clock ratio to infinity
of 1.722. The [Kerr demonstration](physics/kerr-demonstration.md) specifies the
orbit, clocks and rendering assumptions.

## Surface finishes

Blender generates tileable colour, roughness and tangent-space normal maps for
the thermal blankets, ceramic tiles, painted panels, brushed fittings, vinyl
and woven straps. The maps share seam, pore and wear patterns at metre-scaled
UVs and are embedded in the authored GLBs. The Ranger uses pale quilted
insulation and a dark porous underside. The Lander uses warmer blankets over
the faceted cargo pods. Endurance has alternating blanket-clad modules and
matte blue-grey radiator panels. Discovery's enamel has fine paint grain and
the ducts and fittings use directionally brushed metal.

## Inspection and verification

`tools/moviecraftshots.tscn -- v=<vehicle> dump=/absolute/directory` captures the
studio angles. The authored and fallback builds run through audit, clearance,
part counts and 28 authored parity poses. Discovery's check covers the full
cover sweep, pod aperture clearance, rotor fit and Jovian initial conditions.
Endurance's check covers rotor phase, its mounted craft clearances and outlet
attachment. `tools/dockingflightshots.tscn` exercises both captures and checks
the rendered attachment against the parked craft datum after a second of flight.
`eval=_soak_check` exercises each mode repeatedly through launch and teardown.
Reference comparisons, successive views and local check logs live in ignored
`tools/evidence/movie-craft/`.
