// ============================================================================
// A MINIMAL `three` FOR NODE — just enough of r160's math for the pure flight
// modules (sim/flight/{rocketry,vehicles,orbit,vessel,guidance,relativity}.js)
// to import and run headlessly.
//
// Every method here is copied from three.js r160's own source, operation for
// operation, because the point of the reference run is to reproduce what the
// page computes to the last bit: `normalize` multiplies by the reciprocal of
// the length (it does NOT divide each component), `setLength` goes through
// `normalize`, `angleTo` clamps before acos, `setFromUnitVectors` normalizes at
// the end. A stub written "equivalently" rather than identically moves every
// trajectory in the last place and the port comparison stops meaning anything.
//
// flightref.mjs can also be pointed at the real three.module.js
// (THREE_MODULE=/path/to/three.module.js) — the two must give identical output,
// which is the check that this file is faithful.
// ============================================================================

function clamp(value, min, max) { return Math.max(min, Math.min(max, value)); }

export const MathUtils = {
  clamp,
  degToRad: (d) => d * Math.PI / 180,
  radToDeg: (r) => r * 180 / Math.PI,
  smoothstep(x, min, max) {
    if (x <= min) return 0;
    if (x >= max) return 1;
    x = (x - min) / (max - min);
    return x * x * (3 - 2 * x);
  },
};

export class Quaternion {
  constructor(x = 0, y = 0, z = 0, w = 1) { this._x = x; this._y = y; this._z = z; this._w = w; this.isQuaternion = true; }
  get x() { return this._x; } set x(v) { this._x = v; }
  get y() { return this._y; } set y(v) { this._y = v; }
  get z() { return this._z; } set z(v) { this._z = v; }
  get w() { return this._w; } set w(v) { this._w = v; }
  set(x, y, z, w) { this._x = x; this._y = y; this._z = z; this._w = w; return this; }
  clone() { return new Quaternion(this._x, this._y, this._z, this._w); }
  copy(q) { this._x = q.x; this._y = q.y; this._z = q.z; this._w = q.w; return this; }
  setFromAxisAngle(axis, angle) {
    const halfAngle = angle / 2, s = Math.sin(halfAngle);
    this._x = axis.x * s; this._y = axis.y * s; this._z = axis.z * s;
    this._w = Math.cos(halfAngle);
    return this;
  }
  setFromUnitVectors(vFrom, vTo) {
    let r = vFrom.dot(vTo) + 1;
    if (r < Number.EPSILON) {
      r = 0;
      if (Math.abs(vFrom.x) > Math.abs(vFrom.z)) {
        this._x = -vFrom.y; this._y = vFrom.x; this._z = 0; this._w = r;
      } else {
        this._x = 0; this._y = -vFrom.z; this._z = vFrom.y; this._w = r;
      }
    } else {
      this._x = vFrom.y * vTo.z - vFrom.z * vTo.y;
      this._y = vFrom.z * vTo.x - vFrom.x * vTo.z;
      this._z = vFrom.x * vTo.y - vFrom.y * vTo.x;
      this._w = r;
    }
    return this.normalize();
  }
  angleTo(q) { return 2 * Math.acos(Math.abs(clamp(this.dot(q), -1, 1))); }
  identity() { return this.set(0, 0, 0, 1); }
  invert() { return this.conjugate(); }
  conjugate() { this._x *= -1; this._y *= -1; this._z *= -1; return this; }
  dot(v) { return this._x * v._x + this._y * v._y + this._z * v._z + this._w * v._w; }
  lengthSq() { return this._x * this._x + this._y * this._y + this._z * this._z + this._w * this._w; }
  length() { return Math.sqrt(this._x * this._x + this._y * this._y + this._z * this._z + this._w * this._w); }
  normalize() {
    let l = this.length();
    if (l === 0) { this._x = 0; this._y = 0; this._z = 0; this._w = 1; }
    else { l = 1 / l; this._x = this._x * l; this._y = this._y * l; this._z = this._z * l; this._w = this._w * l; }
    return this;
  }
  multiply(q) { return this.multiplyQuaternions(this, q); }
  premultiply(q) { return this.multiplyQuaternions(q, this); }
  multiplyQuaternions(a, b) {
    const qax = a._x, qay = a._y, qaz = a._z, qaw = a._w;
    const qbx = b._x, qby = b._y, qbz = b._z, qbw = b._w;
    this._x = qax * qbw + qaw * qbx + qay * qbz - qaz * qby;
    this._y = qay * qbw + qaw * qby + qaz * qbx - qax * qbz;
    this._z = qaz * qbw + qaw * qbz + qax * qby - qay * qbx;
    this._w = qaw * qbw - qax * qbx - qay * qby - qaz * qbz;
    return this;
  }
  slerp(qb, t) {
    if (t === 0) return this;
    if (t === 1) return this.copy(qb);
    const x = this._x, y = this._y, z = this._z, w = this._w;
    let cosHalfTheta = w * qb._w + x * qb._x + y * qb._y + z * qb._z;
    if (cosHalfTheta < 0) {
      this._w = -qb._w; this._x = -qb._x; this._y = -qb._y; this._z = -qb._z;
      cosHalfTheta = -cosHalfTheta;
    } else {
      this.copy(qb);
    }
    if (cosHalfTheta >= 1.0) { this._w = w; this._x = x; this._y = y; this._z = z; return this; }
    const sqrSinHalfTheta = 1.0 - cosHalfTheta * cosHalfTheta;
    if (sqrSinHalfTheta <= Number.EPSILON) {
      const s = 1 - t;
      this._w = s * w + t * this._w; this._x = s * x + t * this._x;
      this._y = s * y + t * this._y; this._z = s * z + t * this._z;
      this.normalize();
      return this;
    }
    const sinHalfTheta = Math.sqrt(sqrSinHalfTheta);
    const halfTheta = Math.atan2(sinHalfTheta, cosHalfTheta);
    const ratioA = Math.sin((1 - t) * halfTheta) / sinHalfTheta,
      ratioB = Math.sin(t * halfTheta) / sinHalfTheta;
    this._w = (w * ratioA + this._w * ratioB);
    this._x = (x * ratioA + this._x * ratioB);
    this._y = (y * ratioA + this._y * ratioB);
    this._z = (z * ratioA + this._z * ratioB);
    return this;
  }
}

const _quaternion = new Quaternion();

export class Vector3 {
  constructor(x = 0, y = 0, z = 0) { this.x = x; this.y = y; this.z = z; this.isVector3 = true; }
  set(x, y, z) { if (z === undefined) z = this.z; this.x = x; this.y = y; this.z = z; return this; }
  clone() { return new Vector3(this.x, this.y, this.z); }
  copy(v) { this.x = v.x; this.y = v.y; this.z = v.z; return this; }
  add(v) { this.x += v.x; this.y += v.y; this.z += v.z; return this; }
  addVectors(a, b) { this.x = a.x + b.x; this.y = a.y + b.y; this.z = a.z + b.z; return this; }
  addScaledVector(v, s) { this.x += v.x * s; this.y += v.y * s; this.z += v.z * s; return this; }
  sub(v) { this.x -= v.x; this.y -= v.y; this.z -= v.z; return this; }
  subVectors(a, b) { this.x = a.x - b.x; this.y = a.y - b.y; this.z = a.z - b.z; return this; }
  multiplyScalar(s) { this.x *= s; this.y *= s; this.z *= s; return this; }
  divideScalar(s) { return this.multiplyScalar(1 / s); }
  applyAxisAngle(axis, angle) { return this.applyQuaternion(_quaternion.setFromAxisAngle(axis, angle)); }
  applyQuaternion(q) {
    const vx = this.x, vy = this.y, vz = this.z;
    const qx = q.x, qy = q.y, qz = q.z, qw = q.w;
    const tx = 2 * (qy * vz - qz * vy);
    const ty = 2 * (qz * vx - qx * vz);
    const tz = 2 * (qx * vy - qy * vx);
    this.x = vx + qw * tx + qy * tz - qz * ty;
    this.y = vy + qw * ty + qz * tx - qx * tz;
    this.z = vz + qw * tz + qx * ty - qy * tx;
    return this;
  }
  negate() { this.x = -this.x; this.y = -this.y; this.z = -this.z; return this; }
  dot(v) { return this.x * v.x + this.y * v.y + this.z * v.z; }
  lengthSq() { return this.x * this.x + this.y * this.y + this.z * this.z; }
  length() { return Math.sqrt(this.x * this.x + this.y * this.y + this.z * this.z); }
  normalize() { return this.divideScalar(this.length() || 1); }
  setLength(length) { return this.normalize().multiplyScalar(length); }
  lerp(v, alpha) { this.x += (v.x - this.x) * alpha; this.y += (v.y - this.y) * alpha; this.z += (v.z - this.z) * alpha; return this; }
  cross(v) { return this.crossVectors(this, v); }
  crossVectors(a, b) {
    const ax = a.x, ay = a.y, az = a.z;
    const bx = b.x, by = b.y, bz = b.z;
    this.x = ay * bz - az * by;
    this.y = az * bx - ax * bz;
    this.z = ax * by - ay * bx;
    return this;
  }
  angleTo(v) {
    const denominator = Math.sqrt(this.lengthSq() * v.lengthSq());
    if (denominator === 0) return Math.PI / 2;
    const theta = this.dot(v) / denominator;
    return Math.acos(clamp(theta, -1, 1));
  }
  distanceTo(v) { return Math.sqrt(this.distanceToSquared(v)); }
  distanceToSquared(v) { const dx = this.x - v.x, dy = this.y - v.y, dz = this.z - v.z; return dx * dx + dy * dy + dz * dz; }
  equals(v) { return v.x === this.x && v.y === this.y && v.z === this.z; }
  toArray() { return [this.x, this.y, this.z]; }
}

// Present only so an accidental import resolves; the pure modules do not use it.
export class Matrix3 { constructor() { this.elements = [1, 0, 0, 0, 1, 0, 0, 0, 1]; } }
