// Numerical and navigation regressions, run inside the simulator document.
(async () => {
  const { Vector3 } = await import('three');
  const { measure } = await import('/sim/lightcurve.js');
  const { strainOf, findBinary } = await import('/sim/gwdetector.js');
  const { integrate } = await import('/sim/physics.js');
  const { MODULES } = await import('/sim/lessons.js');
  const s = window.SIM, errors = [], rows = [];
  const check = (name, ok, value) => { rows.push({name, ok, value}); if (!ok) errors.push(name); };
  const body = (name, radius, pos, luminosity=0) => ({name, radius, pos:new Vector3(...pos), vel:new Vector3(), luminosity, alive:true});
  const star=body('star',1,[0,0,0],1), p=body('planet',0.1,[0,0,2]), u=new Vector3(0,0,1);
  let m=measure([star,p],u);check('central limb-darkened transit',Math.abs((1-m.rel)-0.012481)<0.00001,1-m.rel);
  check('face-on has no transit',measure([star,p],new Vector3(0,1,0)).rel===1);
  check('overlapping silhouettes counted once',Math.abs(measure([star,p,{...p,name:'twin'}],u).rel-m.rel)<1e-10);
  check('large occulter total eclipse',measure([star,body('large',100,[0,0,2])],u).rel===0);
  check('luminous companion eclipse',measure([star,body('companion',2,[0,0,2],0.5)],u).rel===1/3);
  s.load('bhmerger');const pair=findBinary(s.state.bodies), h=strainOf(pair), h2=strainOf(pair,{distMpc:820});
  check('GW amplitude scales as inverse distance',Math.abs(h.h0/h2.h0-2)<1e-12);
  check('GW ignores noncompact objects',findBinary([star,p])===null);
  s.load('edu_transit');
  let deepest=0, rvLo=Infinity, rvHi=-Infinity;
  for(let i=0;i<5000;i++){
    integrate(s.state.bodies,1e-5);
    const m=measure(s.state.bodies,u);
    deepest=Math.max(deepest,1-m.rel);rvLo=Math.min(rvLo,m.rv);rvHi=Math.max(rvHi,m.rv);
  }
  check('live hot Jupiter transit depth',deepest>0.019&&deepest<0.022,deepest);
  check('live hot Jupiter RV amplitude', (rvHi-rvLo)/2>145&&(rvHi-rvLo)/2<160,(rvHi-rvLo)/2);
  s.setAppMode('learn',{quiet:true});
  for(const mod of MODULES)for(const lesson of mod.lessons){
    document.title='Checking '+mod.id+'/'+lesson.id;
    const key=mod.id+'/'+lesson.id;
    s.lessons.openLesson(key,lesson.steps.length-1);
    for(let i=lesson.steps.length-1;i>=0;i--){
      if(i<lesson.steps.length-1)s.lessons.prev();

      const accumulated=lesson.steps.slice(0,i+1).map(x=>x.do).filter(Boolean);
      const preset=accumulated.findLast(x=>x.preset)?.preset||'edu_galaxy';
      const d=lesson.steps[i].do;
      if(s.state.presetKey!==preset)errors.push(`${key} ${i}: wrong preset ${s.state.presetKey}`);
      if(d?.timeScale!==undefined&&Math.abs(s.state.timeScale-d.timeScale)>1e-12)errors.push(`${key} ${i}: wrong pace ${s.state.timeScale}`);
      if(d?.focus&&s.state.bodies.find(x=>x.id===s.state.focusId)?.name!==d.focus)errors.push(`${key} ${i}: wrong focus`);
    }
    await new Promise(r=>setTimeout(r,0));
  }
  check('35 lessons direct entry and reverse navigation',errors.length===0);
  s.load('edu_habitable');
  s.state.paused=false;
  for(let i=0;i<60;i++)s.frame(1/60);
  const hot=s.state.bodies.find(b=>b.name==='Scorched');
  const temperate=s.state.bodies.find(b=>b.name==='Temperate');
  check('hot world loses its oceans',hot.viz.surfMat.uniforms.uSeaKm.value < -50,hot.viz.surfMat.uniforms.uSeaKm.value);
  check('temperate world retains oceans',Math.abs(temperate.viz.surfMat.uniforms.uSeaKm.value)<1,temperate.viz.surfMat.uniforms.uSeaKm.value);
  s.load('edu_moon');s.state.paused=false;
  for(let i=0;i<12;i++){s.frame(1/60);const moon=s.state.bodies.find(b=>b.name==='Moon'), earth=s.state.bodies.find(b=>b.name==='Earth');const toward=earth.pos.clone().sub(moon.pos).applyQuaternion(moon.viz.group.quaternion.clone().invert()).normalize();const facing=new Vector3(Math.cos(moon.spinPhase),0,-Math.sin(moon.spinPhase));if(facing.dot(toward)<0.99)errors.push('Moon synchronous rotation');}
  check('Moon keeps its near side toward Earth',!errors.includes('Moon synchronous rotation'));
  window.SCIENCE_REPORT={rows,errors,ok:!errors.length};
})().catch(error => {
  window.SCIENCE_REPORT = { ok: false, errors: [String(error.stack || error)] };
});
