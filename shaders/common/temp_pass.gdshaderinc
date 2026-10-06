// THE TEMPERATURE PASS, for every spatial shader in the orrery and flight view; read
// docs/godot.md first. An opaque shader can't write arbitrary alpha, so the world is
// drawn twice: a second camera with TEMP_LAYER_BIT (on no object) makes
// is_temp_pass() true, and the shader writes its temperature code into ALBEDO.r in
// the form its blend mode needs (the table in docs/godot.md). It only renders outside
// visible light.
const uint TEMP_LAYER_BIT = 524288u;   // 1 << 19: render layer 20
const float TEMP_NO_DATA = 1.0;        // "infer the temperature from colour"
const float TEMP_LOG_SCALE = 25.33;

bool is_temp_pass(uint camera_visible_layers) {
	return (camera_visible_layers & TEMP_LAYER_BIT) != 0u;
}

// ln(T)/25.33, clamped below 1: the encoding the remap reads back.
float temp_code(float T) {
	return T > 0.0 ? min(log(max(T, 1.0)) / TEMP_LOG_SCALE, 0.98) : 0.0;
}
