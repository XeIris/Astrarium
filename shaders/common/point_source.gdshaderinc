// The one mapping from a point source's flux to what is drawn, shared by the body
// markers, the catalogue stars and the procedural sky's stars. docs/physics/sky.md.
//
// The argument is flux / (pixel solid angle), which is radiance × pixel². Linear to
// the knee (about a V = 1 star at the default zoom), then logarithmic: each magnitude
// brighter adds 0.92 knees, and the slope is continuous at the knee.
const float POINT_KNEE = 1000.0;

float point_flux(float flux_px2) {
	return flux_px2 <= POINT_KNEE ? flux_px2 : POINT_KNEE * (1.0 + log(flux_px2 / POINT_KNEE));
}
