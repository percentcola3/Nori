import React from 'react';
import {Split, reveal} from '../kit/text.jsx';
import {shot, onRender} from '../engine.js';
import {q, qa, sec, Aura, driveAura, Ribbons, entrance, Mascot, driveMascots, span, easeOut, counter} from '../ui.jsx';

// ---------------- 1 · hook: a disk bar that keeps filling ----------------
const BAR_W = 1280, BASE = .40;
const SEGS = [
  {name: 'Xcode DerivedData', w: .18, c: '#BFEAF2', row: 'up'},
  {name: 'Claude Code', w: .09, c: '#B8A7DF', row: 'down'},
  {name: 'npm', w: .08, c: '#69C7DD', row: 'up'},
  {name: 'Codex', w: .08, c: '#C9BCEB', row: 'down'},
  {name: 'pip', w: .05, c: '#F2C66D', row: 'up'},
  {name: 'Cursor', w: .09, c: '#9FDCEB', row: 'down'},
];
const SEG_AT = [.24, .48, .72, .96, 1.2, 1.44], WARN = 2.4;
export function HookView({shot: s}) {
  let x = BASE * BAR_W;
  return <div className="stage">
    <Aura opacity={.35} />
    <div className="hook-title" style={{position: 'absolute', left: 0, right: 0, top: 190, textAlign: 'center'}}>
      <div className="h-en" style={{fontSize: 76}}><Split text={s.headlineEn} lang="en" /></div>
      <div className="h-zh" style={{fontSize: 60, marginTop: 18}}><Split text={s.headline} lang="zh-CN" /></div>
    </div>
    <div className="hook-disk" style={{position: 'absolute', left: (1920 - BAR_W) / 2, top: 520, width: BAR_W}}>
      <div className="hstack" style={{fontFamily: 'var(--ui)', fontSize: 24, marginBottom: 18}}>
        <span style={{fontWeight: 600}}>Macintosh HD</span><span className="spacer" />
        <span className="sec num">已用 <b className="hook-used" style={{color: '#fff', fontWeight: 600}}>198</b> / 494 GB</span>
      </div>
      <div className="hook-bar" style={{position: 'relative', height: 56, borderRadius: 28, background: 'rgba(255,255,255,.08)', boxShadow: 'inset 0 0 0 1px rgba(255,255,255,.1)', overflow: 'hidden'}}>
        <i style={{position: 'absolute', left: 0, top: 0, bottom: 0, width: BASE * BAR_W, background: 'rgba(255,255,255,.2)'}} />
        {SEGS.map((g, i) => { const left = x; x += g.w * BAR_W; return <i key={i} className="hook-seg" style={{position: 'absolute', left, top: 0, bottom: 0, width: g.w * BAR_W, background: g.c, transformOrigin: '0 50%', boxShadow: 'inset -2px 0 0 rgba(10,24,38,.5)'}} />; })}
        <i className="hook-alarm" style={{position: 'absolute', inset: 0, background: 'linear-gradient(90deg, rgba(229,102,114,0) 30%, rgba(229,102,114,.85))', opacity: 0}} />
      </div>
      {(() => { let cx = BASE * BAR_W; return SEGS.map((g, i) => { const c = cx + g.w * BAR_W / 2; cx += g.w * BAR_W;
        return <div key={i} className="hook-label" style={{position: 'absolute', left: c, top: g.row === 'up' ? 120 : 160, transform: 'translateX(-50%)', whiteSpace: 'nowrap', fontFamily: 'var(--ui)', fontSize: 22, fontWeight: 600, color: g.c}}>{g.name}</div>; }); })()}
    </div>
    <div className="hook-desc desc" style={{position: 'absolute', left: 0, right: 0, top: 760, width: 'auto', textAlign: 'center'}}>{s.description}</div>
  </div>;
}
export const buildHook = tl => {
  const id = 'hook', s = shot(id);
  entrance(id, 'cut'); driveAura(id);
  tl.fromTo(q(id, '.hook-disk'), {opacity: 0, y: 24}, {opacity: 1, y: 0, duration: .4, ease: 'power3.out'}, s.start);
  qa(id, '.hook-seg').forEach((el, i) => tl.fromTo(el, {scaleX: 0}, {scaleX: 1, duration: .3, ease: 'power3.out'}, s.start + SEG_AT[i]));
  qa(id, '.hook-label').forEach((el, i) =>
    tl.fromTo(el, {opacity: 0, y: -10}, {opacity: 1, y: 0, duration: .3, ease: 'power3.out'}, s.start + SEG_AT[i] + .06));
  reveal(tl, q(id, '.hook-title .h-en'), s.start + .5, {stagger: .015});
  reveal(tl, q(id, '.hook-title .h-zh'), s.start + .7, {stagger: .04});
  tl.fromTo(q(id, '.hook-desc'), {opacity: 0, y: 16}, {opacity: 1, y: 0, duration: .45, ease: 'power3.out'}, s.start + s.descriptionAt);
  tl.fromTo(q(id, '.hook-alarm'), {opacity: 0}, {opacity: 1, duration: .2, ease: 'power2.out'}, s.start + WARN);
  tl.fromTo(q(id, '.hook-bar'), {x: 0}, {keyframes: {x: [0, -8, 7, -5, 3, 0]}, duration: .35, ease: 'none'}, s.start + WARN);
  const used = q(id, '.hook-used');
  onRender(id, local => {
    let v = 198;
    SEGS.forEach((g, i) => { v += g.w * 494 * easeOut(span(local, SEG_AT[i], SEG_AT[i] + .3)); });
    used.textContent = String(Math.round(v));
    used.style.color = local >= WARN ? 'var(--danger)' : '#fff';
  });
};

// ---------------- 2 · brand lockup ----------------
export function BrandView({shot: s}) {
  return <><div className="stage">
    <Aura opacity={.9} />
    <div className="brand-mascot" style={{position: 'absolute', left: 750, top: 250, width: 420, height: 420}}><Mascot mood="working" size={420} /></div>
    <div className="brand-word" style={{position: 'absolute', left: 980, top: 300}}>
      <div className="brand-nori" style={{fontFamily: 'var(--en)', fontSize: 190, fontWeight: 700, letterSpacing: -4, lineHeight: 1, color: '#fff'}}><Split text="Nori" lang="en" /></div>
      <div className="h-en" style={{fontSize: 52, marginTop: 26}}><Split text={s.headlineEn} lang="en" /></div>
      <div className="h-zh" style={{fontSize: 44, marginTop: 12, color: 'rgba(255,255,255,.88)'}}><Split text={s.headline} lang="zh-CN" /></div>
      <div className="desc brand-desc" style={{marginTop: 22}}>{s.description}</div>
    </div>
  </div><Ribbons /></>;
}
export const buildBrand = async tl => {
  const id = 'brand', s = shot(id), t = s.start;
  entrance(id, 'wipe'); driveAura(id);
  const m = q(id, '.brand-mascot');
  tl.fromTo(m, {opacity: 0, scale: .6, y: 40}, {opacity: 1, scale: 1, y: 0, duration: .7, ease: 'expo.out'}, t + .1);
  tl.to(m, {x: -390, duration: .75, ease: 'expo.inOut'}, t + .7);
  reveal(tl, q(id, '.brand-nori'), t + .96, {from: {opacity: 0, y: 40, filter: 'blur(16px)'}, stagger: .05, dur: .6});
  reveal(tl, q(id, '.brand-word .h-en'), t + 1.3, {stagger: .014});
  reveal(tl, q(id, '.brand-word .h-zh'), t + 1.5, {stagger: .04});
  tl.fromTo(q(id, '.brand-desc'), {opacity: 0, y: 14}, {opacity: 1, y: 0, duration: .4, ease: 'power3.out'}, t + s.descriptionAt);
  tl.to([m, q(id, '.brand-word')], {opacity: 0, filter: 'blur(14px)', duration: .25, ease: 'power2.in'}, s.end - .25);
  await driveMascots(id);
};

// ---------------- 8 · close ----------------
export function CloseView({shot: s}) {
  return <div className="stage">
    <Aura opacity={1} />
    <div className="close-ribbons" style={{position: 'absolute', inset: 0}}>
      {['var(--ribbon-blue)', 'var(--ribbon-gold)', 'var(--ribbon-lilac)'].map((c, i) =>
        <i key={i} style={{position: 'absolute', left: 960 - 60, top: 300 - 400, width: 120, height: 800, borderRadius: 60, background: c}} />)}
    </div>
    <div className="close-mascot" style={{position: 'absolute', left: 960 - 190, top: 120, width: 380, height: 380}}><Mascot mood="working" size={380} /></div>
    <div style={{position: 'absolute', left: 0, right: 0, top: 520, textAlign: 'center'}}>
      <div className="close-nori" style={{fontFamily: 'var(--en)', fontSize: 150, fontWeight: 700, letterSpacing: -3, lineHeight: 1}}><Split text="Nori" lang="en" /></div>
      <div className="h-en close-en" style={{fontSize: 46, marginTop: 26}}><Split text={s.headlineEn} lang="en" /></div>
      <div className="h-zh close-zh" style={{fontSize: 40, marginTop: 10, color: 'rgba(255,255,255,.88)'}}><Split text={s.headline} lang="zh-CN" /></div>
      <div className="close-meta" style={{fontFamily: 'var(--zh)', fontSize: 26, marginTop: 34, color: 'rgba(255,255,255,.6)', letterSpacing: '.04em'}}>{s.description}</div>
    </div>
  </div>;
}
export const buildClose = async tl => {
  const id = 'close', s = shot(id), t = s.start;
  entrance(id, 'cut'); driveAura(id);
  const bands = qa(id, '.close-ribbons i');
  [-520, 0, 520].forEach((x0, i) => tl.fromTo(bands[i], {x: x0, y: 240, rotation: 14, scaleX: 1, scaleY: 1.6, opacity: 1},
    {x: 0, y: 0, rotation: 14 + 90, scaleX: .35, scaleY: .3, opacity: 0, duration: .7, ease: 'expo.inOut'}, t + i * .04));
  tl.fromTo(q(id, '.close-mascot'), {opacity: 0, scale: .5}, {opacity: 1, scale: 1, duration: .7, ease: 'expo.out'}, t + .45);
  tl.to(q(id, '.close-mascot'), {scale: 1.04, y: -6, duration: 3.6, ease: 'sine.inOut'}, t + 1.1);
  reveal(tl, q(id, '.close-nori'), t + .96, {from: {opacity: 0, y: 40, filter: 'blur(16px)'}, stagger: .05, dur: .6});
  reveal(tl, q(id, '.close-en'), t + 1.3, {stagger: .014});
  reveal(tl, q(id, '.close-zh'), t + 1.5, {stagger: .04});
  tl.fromTo(q(id, '.close-meta'), {opacity: 0, y: 14}, {opacity: 1, y: 0, duration: .5, ease: 'power3.out'}, t + s.descriptionAt);
  tl.to(q(id, '.stage'), {opacity: 0, duration: .5, ease: 'power1.in'}, s.end - .5);
  await driveMascots(id);
};
