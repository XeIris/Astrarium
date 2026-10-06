// Matches sim/suns.gd's apply_suns() (MAX_SUNS = 4). Colours arrive linear
// (Stellar.blackbody_color or U.lin), so no source_color hint.
uniform vec3 uSunDir[4];
uniform vec3 uSunColor[4];
uniform float uSunInt[4];
uniform int uSunCount = 0;
