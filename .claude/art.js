// Reusable page probe: pump N frames, read the composited default framebuffer
// back and return it as a coarse luminance grid plus colour samples.
window.__art = function (cols, rows, frames) {
  for (let i = 0; i < (frames || 3); i++) SIM.frame(1 / 60);
  const gl = SIM.renderer.getContext();
  const W = gl.drawingBufferWidth, H = gl.drawingBufferHeight;
  const px = new Uint8Array(W * H * 4);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, px);
  const RAMP = ' .:-=+*#%@', out = [];
  for (let r = 0; r < rows; r++) {
    let line = '';
    for (let c = 0; c < cols; c++) {
      const x0 = (c * W / cols) | 0, x1 = ((c + 1) * W / cols) | 0;
      const y0 = ((rows - 1 - r) * H / rows) | 0, y1 = ((rows - r) * H / rows) | 0;
      let R = 0, G = 0, B = 0, k = 0;
      for (let y = y0; y < y1; y += 2) for (let x = x0; x < x1; x += 2) {
        const i = (y * W + x) * 4; R += px[i]; G += px[i + 1]; B += px[i + 2]; k++;
      }
      const lum = (0.2126 * R + 0.7152 * G + 0.0722 * B) / k / 255;
      line += RAMP[Math.min(9, (lum * 10) | 0)];
    }
    out.push(line);
  }
  const sm = (fx, fy) => { const x = (fx * W) | 0, y = (fy * H) | 0, i = (y * W + x) * 4; return [px[i], px[i + 1], px[i + 2]]; };
  return { W, H, art: out.join('\n'), top: sm(0.5, 0.9), mid: sm(0.5, 0.5), low: sm(0.5, 0.12), left: sm(0.1, 0.25) };
};
