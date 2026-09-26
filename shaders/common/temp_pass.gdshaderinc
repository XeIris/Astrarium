// ============================================================================
// THE TEMPERATURE PASS — shared by every spatial shader in the orrery and the
// flight view. Read PORT_GUIDE.md, "the temperature pass", before using it.
//
// The web build rendered one frame and let each emitter write its true
// temperature, log-encoded, into the ALPHA of the HDR buffer (sim/spectrum.js).
// Godot cannot write arbitrary alpha from an opaque spatial shader — ALPHA
// switches a material to the transparent pipeline — so the same world is drawn
// twice, by two cameras. The second camera's cull mask carries TEMP_LAYER_BIT,
// a layer no object is on, and every shader asks is_temp_pass(): if true it
// writes, into ALBEDO.r, what the web build's shader would have written into
// alpha, in the form the material's blend mode turns into the web build's
// alpha arithmetic (the table is in PORT_GUIDE.md). The temperature pass only
// renders when the imaging band is not visible light.
// ============================================================================
const uint TEMP_LAYER_BIT = 524288u;   // 1 << 19: render layer 20
const float TEMP_NO_DATA = 1.0;        // "infer the temperature from colour"
const float TEMP_LOG_SCALE = 25.33;

bool is_temp_pass(uint camera_visible_layers) {
	return (camera_visible_layers & TEMP_LAYER_BIT) != 0u;
}

// ln(T)/25.33, clamped below 1 — the encoding sim/spectrum.js reads back.
float temp_code(float T) {
	return T > 0.0 ? min(log(max(T, 1.0)) / TEMP_LOG_SCALE, 0.98) : 0.0;
}
