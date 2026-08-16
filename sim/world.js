import * as THREE from 'three';

// ============================================================================
// THE LIVING WORLD
// ----------------------------------------------------------------------------
// A rocky planet whose surface is generated in the shader from 3D noise (so it
// has no texture seam or polar pinch) and whose APPEARANCE IS DRIVEN BY THE
// CLIMATE MODEL: ice caps advance and retreat with the glaciated fraction, seas
// shrink as they boil away, cloud decks thicken with humidity, and the ground
// glows when it is hot enough to.
//
// It is lit by every star at once. That is the whole point — a Trisolaran
// sunset has two or three terminators crossing the disc at different angles,
// in different colours, and you can see it directly here.
// ============================================================================

export const MAX_SUNS = 4;

const SUN_UNIFORMS = () => ({
  uSunDir:   { value: Array.from({ length: MAX_SUNS }, () => new THREE.Vector3(1, 0, 0)) },
  uSunColor: { value: Array.from({ length: MAX_SUNS }, () => new THREE.Color(1, 1, 1)) },
  uSunInt:   { value: new Float32Array(MAX_SUNS) },
  uSunCount: { value: 0 },
});

const NOISE_GLSL = `
  float hash(vec3 p){ return fract(sin(dot(p, vec3(17.1,113.5,7.9))) * 43758.5453); }
  float noise(vec3 p){
    vec3 i = floor(p), f = fract(p); f = f*f*(3.0-2.0*f);
    return mix(mix(mix(hash(i),             hash(i+vec3(1,0,0)), f.x),
                   mix(hash(i+vec3(0,1,0)), hash(i+vec3(1,1,0)), f.x), f.y),
               mix(mix(hash(i+vec3(0,0,1)), hash(i+vec3(1,0,1)), f.x),
                   mix(hash(i+vec3(0,1,1)), hash(i+vec3(1,1,1)), f.x), f.y), f.z);
  }
  float fbm(vec3 p, int oct){
    float v = 0.0, a = 0.5;
    for(int i=0;i<8;i++){ if(i>=oct) break; v += a*noise(p); p *= 2.03; a *= 0.5; }
    return v;
  }
  // ridged noise gives mountain chains rather than rolling blobs
  float ridged(vec3 p, int oct){
    float v = 0.0, a = 0.5;
    for(int i=0;i<8;i++){ if(i>=oct) break; v += a*(1.0-abs(noise(p)*2.0-1.0)); p *= 2.11; a *= 0.5; }
    return v;
  }`;

function surfaceMaterial(seed) {
  return new THREE.ShaderMaterial({
    uniforms: {
      ...SUN_UNIFORMS(),
      uSeed:    { value: seed },
      uIce:     { value: 0.2 },     // glaciated fraction from the EBM
      uSea:     { value: 0.55 },    // sea level (drops as oceans boil)
      uScorch:  { value: 0.0 },     // 0..1 surface incandescence
      uTime:    { value: 0 },
      uAmbient: { value: new THREE.Color(0x0a1020) },
    },
    vertexShader: `
      varying vec3 vObj; varying vec3 vWN; varying vec3 vWP;
      void main(){
        vObj = normalize(position);
        vWN  = normalize(mat3(modelMatrix) * normal);
        vec4 wp = modelMatrix * vec4(position, 1.0);
        vWP = wp.xyz;
        gl_Position = projectionMatrix * viewMatrix * wp;
      }`,
    fragmentShader: `
      precision highp float;
      uniform vec3 uSunDir[${MAX_SUNS}]; uniform vec3 uSunColor[${MAX_SUNS}];
      uniform float uSunInt[${MAX_SUNS}]; uniform int uSunCount;
      uniform float uSeed, uIce, uSea, uScorch, uTime; uniform vec3 uAmbient;
      varying vec3 vObj; varying vec3 vWN; varying vec3 vWP;
      ${NOISE_GLSL}

      void main(){
        vec3 p = normalize(vObj);
        vec3 q = p * 2.1 + vec3(uSeed);

        // --- terrain: continents + ridges
        float cont = fbm(q, 6);
        float ridge = ridged(q * 3.1, 5) * 0.28;
        float elev = cont + ridge * 0.5;

        float lat = abs(p.y);
        bool ocean = elev < uSea;

        vec3 albedo;
        float rough = 1.0;
        if(ocean){
          float depth = clamp((uSea - elev) / max(uSea, 0.001), 0.0, 1.0);
          albedo = mix(vec3(0.10,0.32,0.48), vec3(0.02,0.06,0.20), depth);
          rough = 0.15;
        } else {
          float h = (elev - uSea) / max(1.0 - uSea, 0.001);
          vec3 low  = vec3(0.20,0.36,0.16);       // vegetation
          vec3 mid  = vec3(0.42,0.36,0.20);       // steppe
          vec3 high = vec3(0.38,0.33,0.30);       // bare rock
          albedo = mix(low, mid, smoothstep(0.0,0.35,h));
          albedo = mix(albedo, high, smoothstep(0.35,0.75,h));
          // aridity as the world bakes: green gives way to desert
          albedo = mix(albedo, vec3(0.55,0.42,0.26), clamp(uScorch*1.6, 0.0, 0.85));
        }

        // --- ice: caps grow down from the poles, and high ground freezes first.
        // uIce is the EBM's glaciated fraction, so the caps track the model.
        float capEdge = 1.0 - uIce * 1.05;
        float jitter = (fbm(q * 3.0 + 11.0, 3) - 0.5) * 0.16;
        float icy = smoothstep(capEdge - 0.10, capEdge + 0.06, lat + jitter);
        // above the snow line even the tropics glaciate
        float snowLine = mix(1.4, uSea + 0.02, clamp(uIce * 1.3, 0.0, 1.0));
        if(!ocean) icy = max(icy, smoothstep(snowLine, snowLine + 0.06, elev));
        icy *= smoothstep(0.02, 0.18, uIce) ;
        albedo = mix(albedo, vec3(0.86,0.90,0.95), clamp(icy, 0.0, 1.0));
        rough = mix(rough, 0.8, icy);

        // --- lighting from every sun
        vec3 N = normalize(vWN);
        vec3 V = normalize(cameraPosition - vWP);
        vec3 lit = vec3(0.0);
        for(int i=0;i<${MAX_SUNS};i++){
          if(i >= uSunCount) break;
          vec3 L = normalize(uSunDir[i]);
          float ndl = dot(N, L);
          // soft terminator — a star is a disc, not a point
          float diff = smoothstep(-0.08, 0.22, ndl);
          vec3 sc = uSunColor[i] * uSunInt[i];
          lit += albedo * sc * diff;
          // specular glint off water and ice
          vec3 H = normalize(L + V);
          float spec = pow(max(dot(N,H), 0.0), mix(120.0, 18.0, rough)) * (1.0 - rough);
          lit += sc * spec * 0.7 * step(0.0, ndl);
        }
        lit += albedo * uAmbient;

        // --- incandescent surface once it is truly scorching
        lit += vec3(1.0, 0.28, 0.06) * pow(uScorch, 2.0) * 0.9;

        gl_FragColor = vec4(lit, 1.0);
      }`,
  });
}

function cloudMaterial() {
  return new THREE.ShaderMaterial({
    uniforms: {
      ...SUN_UNIFORMS(),
      uTime: { value: 0 }, uCover: { value: 0.4 }, uStorm: { value: 0.2 }, uSeed: { value: 3.7 },
    },
    transparent: true, depthWrite: false,
    vertexShader: `
      varying vec3 vObj; varying vec3 vWN; varying vec3 vWP;
      void main(){ vObj = normalize(position);
        vWN = normalize(mat3(modelMatrix) * normal);
        vec4 wp = modelMatrix * vec4(position,1.0); vWP = wp.xyz;
        gl_Position = projectionMatrix * viewMatrix * wp; }`,
    fragmentShader: `
      precision highp float;
      uniform vec3 uSunDir[${MAX_SUNS}]; uniform vec3 uSunColor[${MAX_SUNS}];
      uniform float uSunInt[${MAX_SUNS}]; uniform int uSunCount;
      uniform float uTime, uCover, uStorm, uSeed;
      varying vec3 vObj; varying vec3 vWN; varying vec3 vWP;
      ${NOISE_GLSL}
      void main(){
        vec3 p = normalize(vObj);
        // zonal shear: clouds are dragged into bands, faster at the equator
        float shear = uTime * 0.06 * (1.0 - 0.55 * abs(p.y));
        float c = cos(shear), s = sin(shear);
        vec3 q = vec3(c*p.x - s*p.z, p.y, s*p.x + c*p.z) * 3.0 + vec3(uSeed);
        float d = fbm(q + vec3(0.0, uTime*0.02, 0.0), 6);
        // storm systems: tighter spirals where the atmosphere is energetic
        float st = ridged(q * 2.4 - uTime * 0.05, 4) * uStorm;
        d = d + st * 0.35;
        float a = smoothstep(0.62 - uCover * 0.42, 0.86 - uCover * 0.30, d);
        if(a < 0.01) discard;

        vec3 N = normalize(vWN);
        vec3 lit = vec3(0.0);
        for(int i=0;i<${MAX_SUNS};i++){
          if(i >= uSunCount) break;
          float diff = smoothstep(-0.12, 0.28, dot(N, normalize(uSunDir[i])));
          lit += uSunColor[i] * uSunInt[i] * diff;
        }
        lit += vec3(0.04,0.06,0.10);
        gl_FragColor = vec4(lit * mix(1.0, 0.75, uStorm), a * 0.92);
      }`,
  });
}

function atmosphereMaterial() {
  return new THREE.ShaderMaterial({
    uniforms: { ...SUN_UNIFORMS(), uThick: { value: 1 } },
    transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.BackSide,
    vertexShader: `
      varying vec3 vWN; varying vec3 vWP;
      void main(){ vWN = normalize(mat3(modelMatrix) * normal);
        vec4 wp = modelMatrix * vec4(position,1.0); vWP = wp.xyz;
        gl_Position = projectionMatrix * viewMatrix * wp; }`,
    fragmentShader: `
      precision highp float;
      uniform vec3 uSunDir[${MAX_SUNS}]; uniform vec3 uSunColor[${MAX_SUNS}];
      uniform float uSunInt[${MAX_SUNS}]; uniform int uSunCount; uniform float uThick;
      varying vec3 vWN; varying vec3 vWP;
      void main(){
        vec3 N = normalize(vWN);
        vec3 V = normalize(cameraPosition - vWP);
        float rim = pow(1.0 - abs(dot(N, V)), 2.6);
        vec3 col = vec3(0.0);
        for(int i=0;i<${MAX_SUNS};i++){
          if(i >= uSunCount) break;
          vec3 L = normalize(uSunDir[i]);
          float lam = smoothstep(-0.35, 0.5, dot(N, L));
          // forward scattering reddens the limb toward each sun
          float fwd = pow(max(dot(V, -L), 0.0), 3.0);
          col += mix(vec3(0.35,0.58,1.0), vec3(1.0,0.45,0.22), fwd)
               * uSunColor[i] * uSunInt[i] * lam;
        }
        gl_FragColor = vec4(col * rim * uThick, 1.0);
      }`,
  });
}

// ---------------------------------------------------------------------------
export function createWorldVisual(b, opts) {
  const g = new THREE.Group();
  const R = opts.radiusScene;
  const seed = ((b.id * 2654435761) >>> 0) % 1000 / 7.3;

  const surfMat = surfaceMaterial(seed);
  const surface = new THREE.Mesh(new THREE.SphereGeometry(R, 96, 64), surfMat);
  g.add(surface);

  const cloudMat = cloudMaterial();
  const clouds = new THREE.Mesh(new THREE.SphereGeometry(R * 1.02, 64, 48), cloudMat);
  g.add(clouds);

  const atmoMat = atmosphereMaterial();
  const atmo = new THREE.Mesh(new THREE.SphereGeometry(R * 1.12, 48, 32), atmoMat);
  g.add(atmo);

  // The spin axis is tilted — obliquity is what gives a world seasons on top of
  // whatever its orbit is already doing.
  const tilt = opts.obliquity ?? 0.35;
  g.rotation.z = tilt;

  b.viz = {
    group: g, core: surface, surface, clouds, atmo,
    surfMat, cloudMat, atmoMat, baseR: R, R, isWorld: true,
  };

  b.spinPhase = 0;

  b.viz.update = (dt, ctx) => {
    const simDt = ctx.simDt ?? 0;
    // planet rotation — b.dayLength is in years
    const day = b.dayLength || 0.01;
    b.spinPhase += (simDt / day) * Math.PI * 2;
    surface.rotation.y = b.spinPhase;
    clouds.rotation.y = b.spinPhase * 0.985;   // super-rotating cloud deck

    surfMat.uniforms.uTime.value += dt;
    cloudMat.uniforms.uTime.value += dt + simDt * 40;

    const cl = ctx.climate;
    if (cl) {
      surfMat.uniforms.uIce.value = cl.ice;
      // oceans retreat as the world bakes past the boiling point
      const boil = THREE.MathUtils.clamp((cl.T - 350) / 90, 0, 1);
      surfMat.uniforms.uSea.value = 0.55 - boil * 0.4;
      surfMat.uniforms.uScorch.value = THREE.MathUtils.clamp((cl.T - 330) / 140, 0, 1);
      cloudMat.uniforms.uCover.value = cl.clouds;
      cloudMat.uniforms.uStorm.value = cl.storm ?? 0.2;
      atmoMat.uniforms.uThick.value = 0.6 + cl.humidity * 0.8;
    }

    // feed the multi-star lighting
    if (ctx.suns) applySuns([surfMat, cloudMat, atmoMat], ctx.suns, b.viz.group.position);
  };

  return b.viz;
}

// Point every sun-aware material at the current star set. `suns` entries carry
// { posScene, color, intensity }.
export function applySuns(materials, suns, targetScene) {
  const n = Math.min(suns.length, MAX_SUNS);
  for (const m of materials) {
    const u = m.uniforms;
    if (!u.uSunDir) continue;
    for (let i = 0; i < n; i++) {
      u.uSunDir.value[i].copy(suns[i].posScene).sub(targetScene).normalize();
      u.uSunColor.value[i].copy(suns[i].color);
      u.uSunInt.value[i] = suns[i].intensity;
    }
    u.uSunCount.value = n;
  }
}
