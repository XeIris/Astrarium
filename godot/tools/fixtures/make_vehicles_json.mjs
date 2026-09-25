// ============================================================================
// TEMPORARY FIXTURE — sim/flight/vehicles.js as JSON, for craftmodel.gd to read
// while godot/sim/flight/vehicles.gd (ported in parallel by the flight-physics
// agent) does not exist yet. Functions are dropped, data kept; each stage's
// `engine` is the ENGINES entry inlined, exactly as the JS object graph has it.
//
//   node godot/tools/fixtures/make_vehicles_json.mjs godot/tools/fixtures/vehicles.json
//
// DELETE this file and vehicles.json once vehicles.gd lands: craftmodel.gd's
// vehicles() accessor prefers res://sim/flight/vehicles.gd whenever it exists.
// ============================================================================
import { writeFileSync } from 'node:fs';
import { VEHICLES, VEHICLE_ORDER, ENGINES } from '../../../sim/flight/vehicles.js';
const out = JSON.stringify({ VEHICLES, VEHICLE_ORDER, ENGINES }, null, 1) + '\n';
if (process.argv[2]) writeFileSync(process.argv[2], out); else process.stdout.write(out);
