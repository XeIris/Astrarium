# Astronomy branch review

## Corrections

- Surface skies stay linear until the final tone curve. Reduced scattered-light gain, removed the minimum daytime exposure, and added the Sun over the sky instead of replacing sky with an underexposed disc. Daylight suppresses background stars independently of artistic radiance gain.
- Lesson entry, Back, and step jumps reconstruct prerequisite patches. Normal Next preserves the running experiment. Lesson speed takes precedence over surface-camera defaults, saved progress is validated, and cutaway contexts are released.
- Reduced card height at ordinary desktop sizes so narration leaves the scene centre visible; narrow windows give the card a readable full-width bottom region. Lens buttons and disc defaults now reflect the loaded scenario; the lone-hole demo starts without a disc.
- Lunar lessons use real sizes and a synchronously oriented Moon. Removed the unnecessary Moon from the two-body seasons demo. Eclipse-shadow rendering limitations are explicit.
- Photometry handles luminous companions, total eclipses by large bodies, and overlapping silhouettes; paused samples no longer fill the history. Sampling uses the current frame’s camera. Traces use elapsed simulated time.
- GW charts use equivalent detector timestamps, suppress stationary duplicate samples, and bound schematic arm motion. The course labels the rescaled, leading-order inspiral and distinguishes differential displacement from motion per arm.
- Corrected shadow radius versus diameter, the Arctic Circle latitude, EHT photon-ring wording, and transit clock wording. Hot Earth-like worlds lose their oceans by the model's near-Earth-pressure boiling threshold.

## Verification

- All 35 scenarios: 60 frames each, no exceptions or unexpected body loss.
- All 35 lessons / 108 forward steps: no errors or warnings.
- Direct last-step entry and backward traversal of all 35 lessons: correct scenario, requested focus and time scale.
- Analytic central transit: 1.24812% for radius ratio 0.1 with linear limb darkening u=0.6; face-on flux unchanged; overlapping occultations, total occultation, and luminous companion fixtures pass.
- Integrated teaching system: peak transit depth 2.09414%, stellar RV amplitude 152.418 m/s.
- Inverse-distance GW scaling, exclusion of noncompact bodies, dry/habitable ocean states, and lunar near-side orientation pass.
- Visual inspection: Earth daylight, night and Sun-centred views; Trisolaris daylight; hot habitable-zone world; stellar cutaway; binary inspiral and instrument; transit-card layout.
- JavaScript syntax and git whitespace checks pass.

The catalogue sweep is a short smoke test, not a proof of long-term orbital stability or a validation of every possible user edit. Eclipse shadows, full radiative transfer, and relativistic merger/ringdown waveforms remain outside this educational model.

## Primary references used for content checks

- [NASA: Earth's orbital cycles and seasons](https://science.nasa.gov/science-research/earth-science/milankovitch-orbital-cycles-and-their-role-in-earths-climate/)
- [NASA: Moon phases and synchronous rotation](https://science.nasa.gov/moon/moon-phases/)
- [LIGO/Virgo: GW150914 observation](https://arxiv.org/abs/1602.03837)
- [Photon rings and the unresolved EHT image](https://arxiv.org/abs/1907.04329)
