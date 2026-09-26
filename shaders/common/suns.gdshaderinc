// The GLSL declaration that matches sim/suns.gd's apply_suns(), so the two
// cannot drift apart. (The web build's SUN_GLSL; MAX_SUNS = 4.)
// Colours arrive as LINEAR vec3s already (they come from Stellar.blackbody_color
// or U.lin), so no source_color hint: that would convert them a second time.
uniform vec3 uSunDir[4];
uniform vec3 uSunColor[4];
uniform float uSunInt[4];
uniform int uSunCount = 0;
