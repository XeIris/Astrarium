import * as THREE from 'three';
import { structureOf } from './structure.js';
import { tempColor, fmtLength, fmtTemp } from './crosssection.js';

// ============================================================================
// THE 3D CUTAWAY — the interior model, as an object rather than as a chart
// ----------------------------------------------------------------------------
// sim/crosssection.js already draws a body's interior, and draws it well: exact
// radii, a temperature ramp, a label per layer. What a flat disc cannot do is
// make a beginner believe that the core is a SPHERE — that the iron core is not
// a circle painted on a cut face but a ball with a shell of liquid iron round
// it and a mantle round that. That belief is most of what an interior model is
// for, and it costs one quarter of the geometry to earn.
//
// HOW THE WEDGE IS CUT. Not by building wedge geometry — by clipping. Every
// layer is an ordinary sphere at its own radius, drawn DOUBLE-SIDED, and two
// clipping planes with `clipIntersection = true` remove the one octant-pair
// where both of them would cut. Building the wedge as geometry would need cut
// faces, caps and a seam per layer; clipping needs two planes for the whole
// model and gets the inside surfaces for free, which is the entire point: what
// you see through the notch is the far inner wall of every shell above the one
// you are looking at, which is exactly what a cutaway is.
//
// It gets its own tiny renderer rather than sharing the orrery's. A
// WebGLRenderer is bound to one canvas for life, and this is 300 px square with
// a dozen spheres in it — the cost of a second context is far less than the
// cost of teaching the main render loop about a second viewport it would have
// to save and restore state around every frame.
//
// THE RADII ARE REAL, AND THAT IS SOMETIMES THE LESSON. A red giant's
// degenerate helium core is 0.008 of its radius, which is a dot — and it should
// be a dot, because the fact that a third of the star's mass is inside a
// thousandth of its volume is the reason it is a red giant at all.
// ============================================================================

export function createCutaway({ canvas }) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.setSize(canvas.clientWidth || 300, canvas.clientHeight || 300, false);
  renderer.setClearColor(0x000000, 0);
  renderer.localClippingEnabled = true;

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(34, 1, 0.01, 100);
  camera.position.set(2.1, 1.35, 2.3);
  camera.lookAt(0, 0, 0);

  scene.add(new THREE.AmbientLight(0x93a6c4, 0.55));
  const key = new THREE.DirectionalLight(0xffffff, 1.5); key.position.set(3, 4, 5); scene.add(key);
  const fill = new THREE.DirectionalLight(0x88a8ff, 0.45); fill.position.set(-4, -1, -2); scene.add(fill);
  // A light INSIDE the notch, or the whole reason for cutting it is in shadow.
  const inner = new THREE.PointLight(0xffe3c0, 2.0, 8, 2); inner.position.set(0.9, 0.5, 0.9); scene.add(inner);

  // The two planes bound the removed quarter: x > 0 AND z > 0. With
  // clipIntersection the material is cut only where BOTH would cut, so the
  // union (three quarters of the sphere) survives.
  const planes = [
    new THREE.Plane(new THREE.Vector3(-1, 0, 0), 0),
    new THREE.Plane(new THREE.Vector3(0, 0, -1), 0),
  ];

  const root = new THREE.Group();
  scene.add(root);

  let spin = 0, current = null, autoSpin = true;

  function clear() {
    while (root.children.length) {
      const m = root.children.pop();
      m.geometry?.dispose(); m.material?.dispose();
      root.remove(m);
    }
  }

  // ---- build from a structure
  function show(st) {
    clear();
    current = st;
    if (!st || !st.layers || !st.layers.length) return;

    // A black hole has no interior. Its "layers" are locations in the
    // spacetime, so they are drawn as wireframe shells over a black ball
    // rather than as material — see drawCrossSection for the same distinction.
    const isHole = st.type === 'bh';

    for (let i = st.layers.length - 1; i >= 0; i--) {
      const L = st.layers[i];
      const r = Math.max(L.r1, 0.004);
      const geo = new THREE.SphereGeometry(r, 64, 40);
      const col = new THREE.Color(isHole && L.T === 0 ? '#06070c' : tempColor(L.T));
      const mat = new THREE.MeshStandardMaterial({
        color: col,
        roughness: 0.82, metalness: 0.0,
        side: THREE.DoubleSide,
        clippingPlanes: planes,
        clipIntersection: true,
        // Hot layers carry their own light. A 15-million-kelvin core lit only
        // by a lamp outside the star is the one thing a cutaway must not show.
        emissive: col.clone().multiplyScalar(L.T > 1e5 ? 0.55 : L.T > 3000 ? 0.22 : 0.04),
        transparent: isHole && /sphere|ISCO|Ergosphere/i.test(L.name),
        opacity: isHole && /sphere|ISCO|Ergosphere/i.test(L.name) ? 0.16 : 1,
        wireframe: isHole && /sphere|ISCO/i.test(L.name),
      });
      const mesh = new THREE.Mesh(geo, mat);
      mesh.userData.layer = L;
      root.add(mesh);
    }

    // Rotational flattening, applied to the whole model rather than layer by
    // layer: the published layer radii are means, and the shape is the body's.
    const f = st.flattening || 0;
    root.scale.set(1, 1 - f, 1);
  }

  function render(dt = 1 / 60) {
    const w = canvas.clientWidth || 300, h = canvas.clientHeight || 300;
    if (canvas.width !== w * renderer.getPixelRatio() || canvas.height !== h * renderer.getPixelRatio()) {
      renderer.setSize(w, h, false);
      camera.aspect = w / h; camera.updateProjectionMatrix();
    }
    if (autoSpin) spin += dt * 0.35;
    root.rotation.y = spin;
    renderer.render(scene, camera);
  }

  return {
    show, render,
    showSpec(spec) { show(structureOf(spec)); },
    get structure() { return current; },
    setSpin(on) { autoSpin = on; },
    nudge(d) { spin += d; },
    // The legend is HTML rather than drawn into the canvas: it has to be
    // readable and selectable, and a WebGL canvas is neither.
    legend() {
      if (!current?.layers?.length) return '';
      return current.layers.slice().reverse().map(L => `
        <div class="cut-row">
          <i style="background:${tempColor(L.T)}"></i>
          <span class="cut-name">${L.name}</span>
          <span class="cut-num">${fmtLength(L.r1 * (current.radiusAU || 0))} · ${fmtTemp(L.T)}</span>
        </div>`).join('');
    },
    dispose() { clear(); renderer.dispose(); },
  };
}
