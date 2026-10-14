import React from 'react';
import {Split, reveal} from './kit/text.jsx';
import {onRender, frame} from './engine.js';

// ---------- selectors ----------
export const sec = id => document.querySelector(`section[data-shot="${id}"]`);
export const q = (id, sel) => sec(id).querySelector(sel);
export const qa = (id, sel) => [...sec(id).querySelectorAll(sel)];

// ---------- math ----------
export const clamp01 = x => Math.min(1, Math.max(0, x));
export const easeOut = x => 1 - Math.pow(1 - clamp01(x), 3);
export const easeInOut = x => { x = clamp01(x); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
export const span = (local, a, b) => clamp01((local - a) / (b - a));

// ---------- icons (SF Symbol look-alikes drawn at 1em) ----------
const S = ({children, size = 12, sw = 1.6, fill = 'none'}) =>
  <svg width={size} height={size} viewBox="0 0 16 16" fill={fill} stroke="currentColor" strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round">{children}</svg>;
export const Icon = {
  check: p => <S {...p} sw={2.2}><path d="M3.5 8.4l3 3 6-6.8" /></S>,
  hammer: p => <S {...p}><path d="M9.5 6.5l-6 6.2 1.3 1.3 6.1-6.1" /><path d="M7.6 3.2l2.2-1.4 4.4 4.3-1.5 1.4-1.6-.8-1.1 1.1-2.7-2.7 1.1-1.1z" /></S>,
  sparkles: p => <S {...p}><path d="M7 1.8l1.2 3.6L11.8 6.6 8.2 7.8 7 11.4 5.8 7.8 2.2 6.6 5.8 5.4z" /><path d="M12.4 10.2l.6 1.6 1.6.6-1.6.6-.6 1.6-.6-1.6-1.6-.6 1.6-.6z" /></S>,
  appx: p => <S {...p}><rect x="2" y="2.5" width="10" height="10" rx="2.5" /><circle cx="11.5" cy="11.5" r="2.6" /><path d="M10.5 10.5l2 2M12.5 10.5l-2 2" /></S>,
  chevron: p => <S {...p} sw={2}><path d="M4.5 6.5L8 10l3.5-3.5" /></S>,
  history: p => <S {...p}><path d="M2.6 8a5.4 5.4 0 1 0 1.6-3.8" /><path d="M2.4 2.6v2.6H5" /><path d="M8 5.2V8l2 1.3" /></S>,
  trash: p => <S {...p} fill="currentColor" sw={0}><path d="M5.5 1.8h5l.5 1.2H14v1.4H2V3h3zM3.2 5.4h9.6l-.7 8.4c-.06.7-.6 1.2-1.3 1.2H5.2c-.7 0-1.24-.5-1.3-1.2z" /></S>,
  lock: p => <S {...p}><rect x="3.3" y="7" width="9.4" height="7" rx="1.6" /><path d="M5.3 7V5a2.7 2.7 0 0 1 5.4 0v2" /></S>,
  folder: p => <S {...p}><path d="M1.8 4.2c0-.7.5-1.2 1.2-1.2h3l1.4 1.5h5.6c.7 0 1.2.5 1.2 1.2v6.6c0 .7-.5 1.2-1.2 1.2H3c-.7 0-1.2-.5-1.2-1.2z" /></S>,
  brain: p => <S {...p}><path d="M6.2 2.4a2.2 2.2 0 0 0-2.1 2.2A2.3 2.3 0 0 0 2.6 8a2.3 2.3 0 0 0 1.6 3.6 2.2 2.2 0 0 0 4 1V3.8a1.8 1.8 0 0 0-2-1.4z" /><path d="M9.8 2.4a2.2 2.2 0 0 1 2.1 2.2A2.3 2.3 0 0 1 13.4 8a2.3 2.3 0 0 1-1.6 3.6 2.2 2.2 0 0 1-4 1" /></S>,
  cpu: p => <S {...p}><rect x="4" y="4" width="8" height="8" rx="1.4" /><path d="M6 1.8v2M10 1.8v2M6 12.2v2M10 12.2v2M1.8 6h2M1.8 10h2M12.2 6h2M12.2 10h2" /></S>,
  memory: p => <S {...p}><rect x="1.8" y="4.5" width="12.4" height="7" rx="1.2" /><path d="M4.5 4.5v7M7 4.5v7M9.5 4.5v7M12 4.5v7" /></S>,
  globe: p => <S {...p}><circle cx="8" cy="8" r="6" /><path d="M2 8h12M8 2c1.8 1.7 2.6 3.7 2.6 6S9.8 12.3 8 14C6.2 12.3 5.4 10.3 5.4 8S6.2 3.7 8 2z" /></S>,
  close: p => <S {...p}><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" /></S>,
  right: p => <S {...p} sw={2}><path d="M6 3.5L10.5 8 6 12.5" /></S>,
  doc: p => <S {...p}><path d="M3 4h10M3 7h10M3 10h6" /></S>,
  file: p => <S {...p}><path d="M4 1.8h5.2L12.5 5v8.4c0 .5-.4.8-.8.8H4c-.4 0-.8-.3-.8-.8V2.6c0-.5.4-.8.8-.8z" /><path d="M9 1.8V5h3.5" /></S>,
  pin: p => <S {...p}><path d="M5.5 2h5M6.3 2v4.3L4 9h8l-2.3-2.7V2M8 9v5" /></S>,
  copy: p => <S {...p}><rect x="5" y="5" width="8.5" height="9" rx="1.4" /><path d="M3 11V3.4C3 2.6 3.6 2 4.4 2H10" /></S>,
  clock: p => <S {...p}><circle cx="8" cy="8" r="6" /><path d="M8 4.6V8l2.4 1.5" /></S>,
  eye: p => <S {...p}><circle cx="7" cy="7" r="4.2" /><path d="M10.2 10.2L14 14" /></S>,
};

// ---------- product pieces (reconstructed from SimpleMole/Views/Components.swift & Theme.swift) ----------
export const Checkbox = ({on, cls = ''}) => <span className={'cb ' + (on ? 'on ' : '') + cls}><svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="#10283F" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"><path d="M3.5 8.4l3 3 6-6.8" /></svg></span>;
export const Lights = () => <div className="lights"><i /><i /><i /></div>;
const TABS = ['清理', 'Agent', '分析', '软件', 'Dev 环境', '进程', '端口', '流量', '剪贴板', '设置'];
/** PillPicker with the native glass lens on the selected item. */
export function Tabs({selected}) {
  return <div style={{display: 'flex', justifyContent: 'center', padding: '2px 0 10px'}}>
    <div className="hstack" style={{gap: 4, padding: 4, borderRadius: 99, background: 'var(--surface1)', boxShadow: 'inset 0 0 0 .5px rgba(255,255,255,.08)'}}>
      {TABS.map(t => <span key={t} style={{fontSize: 11, fontWeight: 600, padding: '0 9px', height: 28, lineHeight: '28px', borderRadius: 99, whiteSpace: 'nowrap', flex: 'none',
        color: t === selected ? '#fff' : 'var(--secondary)',
        background: t === selected ? 'rgba(255,255,255,.14)' : 'transparent',
        boxShadow: t === selected ? 'inset 0 .5px 0 rgba(255,255,255,.3), 0 1px 4px rgba(0,0,0,.2)' : 'none'}}>{t}</span>)}
    </div>
  </div>;
}
export function TitleBar() {
  return <div className="titlebar"><Lights /><img src="nori/AppIcon-1024.png" width="18" height="18" style={{borderRadius: 4, marginLeft: 6}} alt="" /><span style={{fontSize: 13, fontWeight: 600}}>Nori</span></div>;
}

// ---------- mascot: the product's own animated SVG, seeked to film time ----------
export const Mascot = ({mood, size, style, id}) =>
  <object className="mascot" data-mascot={id || mood} data={`nori/nori-${mood}.svg`} type="image/svg+xml" width={size} height={size} style={style} aria-hidden="true" />;
export async function mascotReady(el) {
  for (let i = 0; i < 100; i++) {
    if (el.contentDocument?.documentElement?.tagName === 'svg') return;
    await new Promise(r => setTimeout(r, 30));
  }
  throw new Error('Mascot SVG failed to load: ' + el.data);
}
/** Set every CSS animation inside the SVG document to `seconds` of its own timeline. */
export function seekMascot(el, seconds) {
  const doc = el?.contentDocument;
  if (!doc?.getAnimations) return;
  for (const a of doc.getAnimations()) { a.pause(); a.currentTime = Math.max(0, seconds) * 1000; }
}
export function driveMascots(id, offsets = {}) {
  const els = qa(id, 'object.mascot');
  onRender(id, local => { for (const el of els) seekMascot(el, local - (offsets[el.dataset.mascot] || 0)); });
  return Promise.all(els.map(mascotReady));
}

// ---------- aura: drifting brand-colour light behind the glass ----------
export const Aura = ({opacity = 1}) => <div className="aura" style={{opacity}}><i className="a1" /><i className="a2" /><i className="a3" /></div>;
export function driveAura(id) {
  const [a1, a2, a3] = qa(id, '.aura i');
  if (!a1) return;
  onRender(id, (_, t) => {
    a1.style.transform = `translate(${200 + 420 * Math.sin(t * .21) - 450}px, ${260 + 180 * Math.cos(t * .17) - 450}px)`;
    a2.style.transform = `translate(${1350 + 320 * Math.cos(t * .19 + 1) - 380}px, ${820 + 200 * Math.sin(t * .23) - 380}px)`;
    a3.style.transform = `translate(${1650 + 280 * Math.sin(t * .15 + 2) - 410}px, ${160 + 220 * Math.cos(t * .2 + 1) - 410}px)`;
  });
}

// ---------- shot entrance: hard cut or the three-ribbon wipe ----------
export const Ribbons = () => <div className="ribbons"><b className="r1" /><b className="r2" /><b className="r3" /></div>;
const TILT = 14, HALF = Math.tan(TILT * Math.PI / 180) * 540;
/** Ribbon wipe runs from local -0.55 to +0.35; the new stage is revealed behind the trailing ribbon. */
export function entrance(id, kind = 'cut') {
  const el = sec(id), stage = el.querySelector('.stage'), bands = [...el.querySelectorAll('.ribbons b')];
  onRender(id, local => {
    el.style.opacity = '1';
    if (kind !== 'wipe') { stage.style.clipPath = local >= 0 ? 'none' : 'inset(0 0 0 100%)'; return; }
    const p = easeInOut((local + .55) / .9);
    const lead = -500 + p * (1920 + 1200);
    bands.forEach((b, i) => {
      const x = lead - i * 150;
      b.style.opacity = p > 0 && p < 1 ? '1' : '0';
      b.style.transform = `translateX(${x - 75}px) rotate(${TILT}deg)`;
    });
    const edge = lead - 2 * 150;
    stage.style.clipPath = p >= 1 ? 'none' : p <= 0 ? 'inset(0 0 0 100%)'
      : `polygon(0 0, ${edge + HALF}px 0, ${edge - HALF}px 100%, 0 100%)`;
  });
}

// ---------- title column ----------
export function TitleCol({s, kicker, style}) {
  return <div className="title-col" style={style}>
    {kicker && <div className="kicker">{kicker}</div>}
    <div className="h-en"><Split text={s.headlineEn} lang="en" /></div>
    <div className="h-zh"><Split text={s.headline} lang="zh-CN" /></div>
    {s.description && <div className="desc">{s.description}</div>}
  </div>;
}
export function buildTitleCol(tl, id, at) {
  const k = q(id, '.title-col .kicker');
  if (k) tl.fromTo(k, {opacity: 0, x: -16}, {opacity: 1, x: 0, duration: .6, ease: 'power3.out'}, at);
  reveal(tl, q(id, '.title-col .h-en'), at + .1, {stagger: .022});
  reveal(tl, q(id, '.title-col .h-zh'), at + .3, {stagger: .05});
  const d = q(id, '.title-col .desc');
  if (d) tl.fromTo(d, {opacity: 0, y: 18}, {opacity: 1, y: 0, duration: .7, ease: 'power3.out'}, at + .6);
}
export const DemoNote = () => <div className="demo-note">界面为演示数据</div>;

/** Write a number that counts from `from` to `to` between local a..b. */
export function counter(el, local, a, b, from, to, fmt) { el.textContent = fmt(from + (to - from) * easeOut(span(local, a, b))); }
export const gb = v => v.toFixed(2) + ' GB';
export {frame};
