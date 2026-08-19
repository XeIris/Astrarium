// ============================================================================
// GPU profile of the lensed pass — runs inside the Electron renderer.
// ============================================================================
// The intent is to time each draw on the GPU's own clock instead of inferring
// it from a readPixels stall. Chrome exposes EXT_disjoint_timer_query_webgl2
// and returns 0 from every query; --enable-gpu-benchmarking (set in main.js)
// is meant to un-blunt that, but on ANGLE's Metal backend the queries still
// return 0 — the backend does not implement GPU timestamps at all. So this
// currently reports zeros on macOS, and says so in the output rather than
// claiming the numbers are real. It is kept because it is correct and will
// work the day the backend gains timestamp support; every measurement in
// PORTING.md used the readPixels fallback instead.
//
// It answers one question: is the lensed pass limited by arithmetic, or by
// occupancy? The evidence so far is behavioural — splitting the marcher and the
// sky apart made the same total work 1.28x faster, and made a sky optimisation
// that previously bought nothing start buying 1.20x. Both point at register
// pressure. Timing the passes separately and summing them tests it directly:
// if the split passes together cost meaningfully less than the fused one did,
// the fused shader was paying for occupancy it could not use.
(async () => {
  const THREE = await import('three');
  const bh = await import('/sim/blackhole.js');
  const sky = await import('/sim/sky.js');

  const W = 1280, H = 720;
  const renderer = new THREE.WebGLRenderer({ antialias: false, powerPreference: 'high-performance' });
  renderer.setPixelRatio(1);
  renderer.setSize(W, H);
  const gl = renderer.getContext();
  const ext = gl.getExtension('EXT_disjoint_timer_query_webgl2');
  if (!ext) return { error: 'EXT_disjoint_timer_query_webgl2 unavailable' };

  const out = new THREE.WebGLRenderTarget(W, H, { type: THREE.HalfFloatType });

  const pass = bh.createBlackHolePass();
  const u = pass.uniforms;
  u.holeCount.value = 2;
  u.holePos.value[0].set(-3, 0, 0);
  u.holePos.value[1].set(3, 0, 0);
  u.holeRs.value[0] = 1; u.holeRs.value[1] = 1;
  sky.applySkyBand(u, 3);
  pass.setSize(W, H);

  const setCam = (dist) => {
    const c = new THREE.PerspectiveCamera(50, W / H, 0.01, 1e5);
    c.position.set(0, dist * 0.3, dist);
    c.lookAt(0, 0, 0);
    c.updateMatrixWorld();
    u.camPos.value.copy(c.position);
    u.camMat.value.copy(c.matrixWorld);
    u.aspect.value = W / H;
    u.fov.value = 50 * Math.PI / 180;
  };

  // One TIME_ELAPSED query around one draw, repeated; the median rejects the
  // occasional sample that catches an unrelated GPU client.
  const gpuMs = (draw, reps = 15) => {
    const s = [];
    for (let i = 0; i < reps; i++) {
      const q = gl.createQuery();
      gl.beginQuery(ext.TIME_ELAPSED_EXT, q);
      draw();
      gl.endQuery(ext.TIME_ELAPSED_EXT);
      gl.finish();
      let guard = 0;
      while (!gl.getQueryParameter(q, gl.QUERY_RESULT_AVAILABLE) && guard++ < 2e6);
      if (!gl.getParameter(ext.GPU_DISJOINT_EXT)) s.push(gl.getQueryParameter(q, gl.QUERY_RESULT) / 1e6);
      gl.deleteQuery(q);
    }
    s.sort((a, b) => a - b);
    if (s.some((v) => v > 0)) sawNonZeroTiming = true;
    return s.length ? +s[s.length >> 1].toFixed(3) : null;
  };

  const drawMarch = () => {
    renderer.setRenderTarget(pass.target);
    renderer.clear();
    renderer.render(pass.marchScene, pass.camera);
  };
  const drawResolve = () => {
    u.tMarch0.value = pass.target.texture[0];
    u.tMarch1.value = pass.target.texture[1];
    renderer.setRenderTarget(out);
    renderer.clear();
    renderer.render(pass.scene, pass.camera);
  };

  // Whether any query came back non-zero. On ANGLE Metal every one is 0, and
  // reporting that honestly is the difference between "the pass is free" and
  // "this stack cannot measure it".
  let sawNonZeroTiming = false;

  const results = {};
  for (const dist of [26, 60]) {
    setCam(dist);
    const perScale = {};
    for (const s of [1.0, 0.5, 0.25]) {
      pass.setScale(s);
      for (let i = 0; i < 6; i++) pass.render(renderer, out);   // warm caches + compile
      const march = gpuMs(drawMarch);
      const resolve = gpuMs(drawResolve);
      const whole = gpuMs(() => pass.render(renderer, out));
      perScale['scale_' + s] = {
        march_ms: march,
        resolve_ms: resolve,
        sum_ms: march !== null && resolve !== null ? +(march + resolve).toFixed(3) : null,
        wholePass_ms: whole,
        marchPx: pass.marchSize().join('x'),
      };
    }
    results['cam_' + dist] = perScale;
  }

  renderer.dispose();
  return {
    renderer: gl.getParameter(gl.getExtension('WEBGL_debug_renderer_info').UNMASKED_RENDERER_WEBGL),
    timerQueriesReturnRealValues: sawNonZeroTiming,
    size: W + 'x' + H,
    results,
  };
})();
