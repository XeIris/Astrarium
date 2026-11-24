#[compute]
#version 450
// OceanField on the GPU, one cascade at a time: the spectrum at time t, the inverse FFT of its rows and then its
// columns in shared memory, and the textures the water shader reads. Must stay OceanField.snapshot's arithmetic:
// oceancheck_gpu reads the result back against the CPU. docs/physics/ocean.md#on-the-gpu.

// One workgroup is one line of the lattice, one invocation one texel along it.
layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

// h̃₀(k) and h̃₀(−k), each re, im.
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D h0;
// ω, kx, kz.
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2D wk;
// Two complex fields per texel: (Dx + iDz, h + i∂Dx/∂z) and (∂h/∂x + i∂h/∂z, ∂Dx/∂x + i∂Dz/∂z).
layout(rgba32f, set = 0, binding = 2) uniform restrict image2D fa;
layout(rgba32f, set = 0, binding = 3) uniform restrict image2D fb;
// What is drawn: (Dx, h, Dz, ∂Dx/∂z) and (∂h/∂x, ∂h/∂z, ∂Dx/∂x, ∂Dz/∂z).
layout(rgba32f, set = 0, binding = 4) uniform restrict image2D disp;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D deriv;

layout(push_constant, std430) uniform Params {
	float mode;      // 0 spectrum, 1 rows, 2 columns, 3 assemble
	float n;
	float t;
	float dt;
	float pad0;
	float pad1;
	float pad2;
	float pad3;
} p;

shared vec4 sa[128];
shared vec4 sb[128];

vec4 cmul2(vec4 a, vec2 w) {
	return vec4(a.x * w.x - a.y * w.y, a.x * w.y + a.y * w.x, a.z * w.x - a.w * w.y, a.z * w.y + a.w * w.x);
}

uint bitrev(uint i, uint bits) {
	return bitfieldReverse(i) >> (32u - bits);
}

void spectrum(ivec2 at) {
	vec4 h = imageLoad(h0, at);
	vec4 w = imageLoad(wk, at);
	float ph = w.x * p.t;
	float c = cos(ph);
	float s = sin(ph);
	float hr = h.x * c + h.y * s + h.z * c + h.w * s;
	float hi = h.y * c - h.x * s + h.z * s - h.w * c;
	float kx = w.y;
	float kz = w.z;
	float k = sqrt(kx * kx + kz * kz);
	vec4 a = vec4(0.0);
	vec4 b = vec4(0.0);
	if (k > 0.0) {
		float ux = kx / k;
		float uz = kz / k;
		float m = kx * kz / k;
		float ax = kx * kx / k;
		float az = kz * kz / k;
		a = vec4(-ux * hi - uz * hr, ux * hr - uz * hi, hr + m * hi, hi - m * hr);
		b = vec4(-kx * hi - kz * hr, kx * hr - kz * hi, -ax * hr + az * hi, -ax * hi - az * hr);
	}
	imageStore(fa, at, a);
	imageStore(fb, at, b);
}

// The inverse DFT along one line, x_n = Σ F_m e^{+2πi mn/N}: bit-reversed load, then Cooley–Tukey in place.
void fft_line(uint line, bool columns) {
	uint x = gl_LocalInvocationID.x;
	uint nn = uint(p.n);
	uint bits = uint(round(log2(p.n)));
	if (x < nn) {
		uint src = bitrev(x, bits);
		ivec2 at = columns ? ivec2(line, src) : ivec2(src, line);
		sa[x] = imageLoad(fa, at);
		sb[x] = imageLoad(fb, at);
	}
	barrier();
	for (uint size = 2u; size <= nn; size <<= 1u) {
		uint half_ = size >> 1u;
		vec4 ua = vec4(0.0), va = vec4(0.0), ub = vec4(0.0), vb = vec4(0.0);
		uint ia = 0u, ib = 0u;
		bool live = x < (nn >> 1u);
		if (live) {
			uint grp = x / half_;
			uint kk = x - grp * half_;
			ia = grp * size + kk;
			ib = ia + half_;
			float ang = 6.283185307179586 * float(kk) / float(size);
			vec2 w = vec2(cos(ang), sin(ang));
			ua = sa[ia]; va = cmul2(sa[ib], w);
			ub = sb[ia]; vb = cmul2(sb[ib], w);
		}
		barrier();
		if (live) {
			sa[ia] = ua + va; sa[ib] = ua - va;
			sb[ia] = ub + vb; sb[ib] = ub - vb;
		}
		barrier();
	}
	if (x < nn) {
		ivec2 at = columns ? ivec2(line, x) : ivec2(x, line);
		imageStore(fa, at, sa[x]);
		imageStore(fb, at, sb[x]);
	}
}

void assemble(ivec2 at) {
	vec4 a = imageLoad(fa, at);
	vec4 b = imageLoad(fb, at);
	imageStore(disp, at, vec4(a.x, a.z, a.y, a.w));
	imageStore(deriv, at, b);
}

void main() {
	uint line = gl_WorkGroupID.x;
	uint x = gl_LocalInvocationID.x;
	int mode = int(p.mode + 0.5);
	if (mode == 1 || mode == 2) {
		fft_line(line, mode == 2);
		return;
	}
	if (x >= uint(p.n)) return;
	ivec2 at = ivec2(x, line);
	if (mode == 0) spectrum(at);
	else assemble(at);
}
