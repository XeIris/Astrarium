// CLOUD CLIMATOLOGY, shared by the orrery's deck (cloud_deck.gdshader) and the flight
// layer (clouds.gdshaderinc); Terrain.cloud_zonal_z is the CPU copy.
// The circulation cells move cloud from the subtropical highs (~26°, where Hadley air
// sinks) to the ITCZ and the storm tracks (~57°). The result is a probit offset: a
// field whose opaque fraction is Φ(z) gets Φ(z_global + cloud_zonal_z) here. Fitted to
// the MODIS/ISCCP zonal means; see docs/physics/clouds.md#climatology.
#ifndef CLOUD_CLIMATE_INC
#define CLOUD_CLIMATE_INC

// phi: latitude (rad). itcz: the ITCZ's latitude (rad), which follows the sun.
float cloud_zonal_z(float phi, float itcz) {
	float a = abs(phi);
	float i = (phi - itcz) / 0.14;
	float s = (a - 0.45) / 0.17;
	float k = (a - 1.0) / 0.22;
	return 0.30 * exp(-i * i) - 0.50 * exp(-s * s) + 0.72 * exp(-k * k);
}

#endif
