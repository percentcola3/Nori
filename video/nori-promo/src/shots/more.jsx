import React from 'react';
import {Split, reveal} from '../kit/text.jsx';
import {shot, onRender} from '../engine.js';
import {Cursor, paintCursor} from '../kit/cursor.jsx';
import {q, qa, Aura, driveAura, Ribbons, entrance, TitleCol, buildTitleCol, DemoNote, Icon, Lights, span, easeOut, clamp01} from '../ui.jsx';

function productPoint(el, root) {
  const r = el.getBoundingClientRect(), b = root.getBoundingClientRect(), z = b.width / root.offsetWidth;
  return {x: (r.left + r.width / 2 - b.left) / z, y: (r.top + r.height / 2 - b.top) / z};
}
function productOrigin(el, root) {
  const r = el.getBoundingClientRect(), b = root.getBoundingClientRect(), z = b.width / root.offsetWidth;
  return {x: (r.left - b.left) / z, y: (r.top - b.top) / z};
}

// ---------------- 7 · screenshot editor (ScreenshotEditorView) ----------------
const PRESETS = [['原图', null], ['极光', 'linear-gradient(135deg,#5B3FD8,#4F8FE6 55%,#5EC8C0)'], ['日落', 'linear-gradient(135deg,#F05F57,#F7B267)'],
  ['海洋', 'linear-gradient(135deg,#1E3C72,#2A9DF4)'], ['薄荷', 'linear-gradient(135deg,#3FB68B,#BDEBD6)'], ['糖果', 'linear-gradient(135deg,#F78CA0,#B8A7DF)']];
const CHECKER = 'repeating-conic-gradient(rgba(255,255,255,.07) 0 25%, rgba(255,255,255,.02) 0 50%) 0 0/16px 16px';
const ToolGlyph = {
  rect: <rect x="3" y="4" width="10" height="8" rx="1.2" />,
  ellipse: <ellipse cx="8" cy="8" rx="5.2" ry="4.2" />,
  arrow: <path d="M4 12L12 4M6.5 4H12v5.5" />,
  pen: <path d="M3.5 12.5l1-3.2 6.3-6.3 2.2 2.2-6.3 6.3zM9.6 4.2l2.2 2.2" />,
  text: <path d="M3.5 4h9M8 4v8.5" />,
  mosaic: <path d="M3 3h4.5v4.5H3zM8.5 8.5H13V13H8.5z" fill="currentColor" stroke="none" />,
};
const TOOLS = ['rect', 'ellipse', 'arrow', 'pen', 'text', 'mosaic'];
const SH = {rect: .72, arrow: 1.2, mosaic: 1.68, presets: [2.4, 3.36, 4.32]};
const MW = 372, MH = 196;
const RECT = {x: 10, y: 48, w: 296, h: 26}, ARROW = [[352, 150], [312, 80]], MOSAIC = {x: 10, y: 78, w: 236, h: 22};
const mosaicCells = (() => { const out = []; let seed = 7;
  for (let y = 0; y < MOSAIC.h; y += 11) for (let x = 0; x < MOSAIC.w; x += 11) { seed = (seed * 9301 + 49297) % 233280; out.push([x, y, 40 + (seed / 233280) * 60]); }
  return out; })();
export function ScreenshotView({shot: s}) {
  return <><div className="stage">
    <Aura opacity={.5} />
    <TitleCol s={s} kicker="Screenshot editor" />
    <div className="cam" style={{position: 'absolute', left: 800, top: 168}}>
      <div className="product zoomp proot" style={{zoom: 1.6, position: 'relative'}}>
        <div className="win" style={{width: 520, padding: 14}}>
          <div className="hstack" style={{gap: 5, marginBottom: 12}}>
            {TOOLS.map(k => <span key={k} className="stool" data-k={k} style={{width: 28, height: 26, borderRadius: 8, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#E8EDF2'}}>
              <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">{ToolGlyph[k]}</svg></span>)}
            <span style={{width: 1, height: 18, background: 'var(--hairline)', margin: '0 6px'}} />
            {['#FF5A5F', '#F2C66D', '#69C7DD', '#FFFFFF'].map((c, i) => <span key={c} style={{width: 14, height: 14, borderRadius: 7, background: c, boxShadow: i === 0 ? '0 0 0 2px rgba(16,40,63,1), 0 0 0 3.5px #fff' : 'none', marginRight: 3}} />)}
            <span className="spacer" />
            <span className="btn-secondary" style={{height: 26, fontSize: 11}}>撤销</span>
            <span className="btn-primary" style={{height: 26, fontSize: 11, padding: '0 14px'}}>保存</span>
          </div>
          <div className="scanvas" style={{position: 'relative', height: 244, borderRadius: 12, overflow: 'hidden', background: CHECKER}}>
            {PRESETS.slice(1).map(([n, bg], i) => <div key={n} className="sbg" style={{position: 'absolute', inset: 0, background: bg, opacity: 0}} />)}
            <div className="sminiwin" style={{position: 'absolute', left: (492 - MW) / 2, top: (244 - MH) / 2, width: MW, height: MH, borderRadius: 9, background: '#16202B', boxShadow: '0 12px 34px rgba(0,0,0,.45)', overflow: 'hidden'}}>
              <div className="hstack" style={{gap: 5, padding: '8px 10px'}}><Lights /><span className="sec" style={{fontSize: 10, marginLeft: 8}}>zsh — web</span></div>
              <div className="mono" style={{position: 'absolute', left: 16, top: 30, fontSize: 11, lineHeight: '24px', color: '#D6E0EA'}}>
                <div><span style={{color: '#69C7DD'}}>$</span> npm run dev</div>
                <div>▲ Next.js · ready on <span style={{color: '#BFEAF2'}}>http://localhost:3000</span></div>
                <div>OPENAI_API_KEY=sk-proj-8f2Kq1xV9…</div>
                <div style={{color: '#53C68C'}}>✓ Compiled in 1.2s</div>
                <div className="sec">○ Waiting for changes…</div>
              </div>
              <svg width={MW} height={MH} style={{position: 'absolute', left: 0, top: 0, overflow: 'visible'}}>
                <g className="smosaic" opacity="0">{mosaicCells.map(([x, y, l], i) =>
                  <rect key={i} x={MOSAIC.x + x} y={MOSAIC.y + y} width="11" height="11" fill={`hsl(210 14% ${l}%)`} />)}</g>
                <rect className="srect" x={RECT.x} y={RECT.y} width={RECT.w} height={RECT.h} rx="4" fill="none" stroke="#FF5A5F" strokeWidth="2.4" pathLength="1" strokeDasharray="1" strokeDashoffset="1" />
                <line className="sarrow" x1={ARROW[0][0]} y1={ARROW[0][1]} x2={ARROW[1][0]} y2={ARROW[1][1]} stroke="#FF5A5F" strokeWidth="3" strokeLinecap="round" pathLength="1" strokeDasharray="1" strokeDashoffset="1" />
                <path className="shead" d={`M${ARROW[1][0] - 3} ${ARROW[1][1] + 14} L${ARROW[1][0]} ${ARROW[1][1]} L${ARROW[1][0] + 13} ${ARROW[1][1] + 7}`} fill="none" stroke="#FF5A5F" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" opacity="0" />
              </svg>
            </div>
          </div>
          <div className="hstack" style={{gap: 9, marginTop: 12}}>
            <span className="sec" style={{fontSize: 10}}>预设</span>
            {PRESETS.map(([n, bg], i) => <div key={n} style={{textAlign: 'center'}}>
              <div className="spreset" data-i={i} style={{width: 58, height: 34, borderRadius: 7, background: bg || CHECKER, boxShadow: 'inset 0 0 0 .5px rgba(255,255,255,.15)'}} />
              <div className="spname" style={{fontSize: 10, marginTop: 4, color: 'var(--secondary)'}}>{n}</div></div>)}
          </div>
        </div>
        <Cursor id="screenshot" color="#fff" stroke="#10283F" />
      </div>
    </div>
    <DemoNote />
  </div><Ribbons /></>;
}
export const buildScreenshot = tl => {
  const id = 'screenshot', s = shot(id), t = s.start;
  const root = q(id, '.proot'), cur = q(id, '.film-cursor');
  const o = productOrigin(q(id, '.sminiwin'), root);
  const at = (x, y) => ({x: o.x + x, y: o.y + y});
  const presets = qa(id, '.spreset'), names = qa(id, '.spname'), bgs = qa(id, '.sbg'), tools = qa(id, '.stool');
  const pp = [1, 2, 3].map(i => productPoint(presets[i], root));
  entrance(id, 'wipe'); driveAura(id);
  buildTitleCol(tl, id, t + .2);
  tl.fromTo(q(id, '.win'), {opacity: 0, y: 40}, {opacity: 1, y: 0, duration: .45, ease: 'expo.out'}, t + .15);
  tl.fromTo(q(id, '.cam'), {scale: 1}, {scale: 1.03, duration: s.end - t - .5, ease: 'sine.inOut'}, t + .5);
  tl.fromTo(q(id, '.smosaic'), {opacity: 0}, {opacity: 1, duration: .12}, t + SH.mosaic);
  tl.fromTo(q(id, '.shead'), {opacity: 0}, {opacity: 1, duration: .08}, t + SH.arrow + .22);
  const rect = q(id, '.srect'), arrow = q(id, '.sarrow'), mini = q(id, '.sminiwin');
  const keys = [
    {at: .4, ...at(RECT.x + 40, RECT.y + 60)}, {at: SH.rect, ...at(RECT.x, RECT.y)}, {at: SH.rect + .28, ...at(RECT.x + RECT.w, RECT.y + RECT.h)},
    {at: SH.arrow, ...at(...ARROW[0])}, {at: SH.arrow + .25, ...at(...ARROW[1])},
    {at: SH.mosaic, ...at(MOSAIC.x, MOSAIC.y + 8)}, {at: SH.mosaic + .22, ...at(MOSAIC.x + MOSAIC.w, MOSAIC.y + 12)},
    {at: SH.presets[0] - .25, ...pp[0]}, {at: SH.presets[1] - .25, ...pp[0]}, {at: SH.presets[1], ...pp[1]},
    {at: SH.presets[2] - .25, ...pp[1]}, {at: SH.presets[2], ...pp[2]},
  ];
  onRender(id, local => {
    rect.style.strokeDashoffset = String(1 - span(local, SH.rect, SH.rect + .28));
    arrow.style.strokeDashoffset = String(1 - span(local, SH.arrow, SH.arrow + .25));
    const tool = local < SH.arrow - .1 ? 'rect' : local < SH.mosaic - .1 ? 'arrow' : 'mosaic';
    tools.forEach(el => { const on = el.dataset.k === tool && local >= .4;
      el.style.background = on ? 'rgba(191,234,242,.2)' : 'transparent'; el.style.color = on ? 'var(--ice)' : '#E8EDF2';
      el.style.boxShadow = on ? 'inset 0 .5px 0 rgba(255,255,255,.3)' : 'none'; });
    let sel = 0; SH.presets.forEach((a, i) => { if (local >= a) sel = i + 1; });
    bgs.forEach((el, i) => { const a = SH.presets[i]; el.style.opacity = String(i + 1 === sel ? clamp01((local - a) / .2) : 0); });
    const prev = sel - 1; if (prev >= 1) bgs[prev - 1].style.opacity = String(1 - clamp01((local - SH.presets[sel - 1]) / .2));
    presets.forEach((el, i) => { el.style.outline = i === sel ? '2px solid var(--ice)' : 'none'; el.style.outlineOffset = '2px'; });
    names.forEach((el, i) => { el.style.color = i === sel ? 'var(--ice)' : 'var(--secondary)'; el.style.fontWeight = i === sel ? '600' : '400'; });
    const since = sel ? local - SH.presets[sel - 1] : 9;
    mini.style.transform = since < .3 ? `scale(${1 - .04 * Math.sin(since / .3 * Math.PI)})` : '';
    paintCursor(cur, local, keys, SH.presets, [.4, 4.9]);
  });
};

// ---------------- 8 · clipboard history (ClipboardHistoryTabView) ----------------
const FILTERS = ['全部', '置顶', '文本', '网址', '文件', '图片'];
const KIND = {text: ['文本', '#E8EDF2', 'doc'], url: ['网址', 'var(--ribbon-blue)', 'globe'], file: ['文件', 'var(--ribbon-gold)', 'file'], image: ['图片', 'var(--ribbon-lilac)', 'eye']};
const CLIPS = [
  {k: 'text', time: '3分钟', body: '为下一个灵感腾出空间。'},
  {k: 'url', time: '8分钟', body: <span className="mono" style={{fontSize: 10}}>https://github.com/nori-app/nori</span>},
  {k: 'text', time: '12分钟', body: <span className="mono" style={{fontSize: 10.5}}>swift build -c release</span>, pin: true},
  {k: 'image', time: '26分钟', body: <div style={{height: 52, borderRadius: 6, background: 'linear-gradient(135deg,#5B3FD8,#4F8FE6 55%,#5EC8C0)', display: 'flex', alignItems: 'flex-end', padding: 4}}>
    <span className="mono" style={{fontSize: 8.5, color: 'rgba(255,255,255,.85)'}}>1284 × 2778</span></div>},
  {k: 'file', time: '1小时5分钟', body: <><b>design-notes.pdf</b><div className="mono sec" style={{fontSize: 8.5, marginTop: 3}}>~/Downloads/design-notes.pdf</div></>},
  {k: 'url', time: '2小时', body: <span className="mono" style={{fontSize: 10}}>https://developer.apple.com/design</span>},
];
const CB = {filters: [[1.92, 3], [2.88, 5], [3.84, 0]], pin: 4.56};
function ClipCard({c}) {
  const [label, color, icon] = KIND[c.k], I = Icon[icon];
  return <div className="row-glass kclip" data-k={c.k} style={{width: 168, height: 132, padding: 10, display: 'flex', flexDirection: 'column', borderRadius: 10}}>
    <div className="hstack" style={{gap: 5, fontSize: 10, fontWeight: 600, color}}><I size={10} />{label}<span className="spacer" />
      <span className="sec" style={{fontSize: 9, fontWeight: 400}}>{c.time}</span>
      <span className={'icon-btn' + (c.pin ? ' kpin' : '')} style={{borderRadius: 99, width: 20, height: 20, marginLeft: 4}}><Icon.pin size={10} /></span></div>
    <div style={{flex: 1, marginTop: 8, fontSize: 11, lineHeight: 1.45, overflow: 'hidden'}}>{c.body}</div>
    <div className="hstack"><span className="btn-secondary" style={{height: 22, fontSize: 10, padding: '0 9px'}}><Icon.copy size={10} />复制</span><span className="spacer" />
      <span className="icon-btn" style={{borderRadius: 99, width: 20, height: 20}}><Icon.trash size={9} /></span></div>
  </div>;
}
export function ClipboardView({shot: s}) {
  return <div className="stage">
    <Aura opacity={.55} />
    <TitleCol s={s} kicker="Clipboard history" />
    <div className="cam" style={{position: 'absolute', left: 790, top: 250}}>
      <div className="product zoomp proot" style={{zoom: 1.7, position: 'relative'}}>
        <div className="hstack" style={{gap: 5, marginBottom: 10}}>
          {FILTERS.map(n => <span key={n} className="btn-secondary kfilter" style={{height: 24, fontSize: 11, padding: '0 11px'}}>{n}</span>)}
          <span className="spacer" />
          <span className="btn-secondary" style={{height: 24, fontSize: 10.5, padding: '0 10px', color: 'var(--secondary)'}}><Icon.trash size={9} />清理未置顶</span>
        </div>
        <div style={{display: 'grid', gridTemplateColumns: 'repeat(3, 168px)', gap: 10}}>
          {CLIPS.map((c, i) => <ClipCard key={i} c={c} />)}
        </div>
        <Cursor id="clipboard" color="#fff" stroke="#10283F" />
      </div>
    </div>
    <DemoNote />
  </div>;
}
export const buildClipboard = tl => {
  const id = 'clipboard', s = shot(id), t = s.start;
  const root = q(id, '.proot'), cur = q(id, '.film-cursor'), filters = qa(id, '.kfilter'), cards = qa(id, '.kclip'), pin = q(id, '.kpin');
  const fp = CB.filters.map(([, i]) => productPoint(filters[i], root)), pp = productPoint(pin, root);
  entrance(id, 'cut'); driveAura(id);
  buildTitleCol(tl, id, t + .05);
  tl.fromTo(cards, {opacity: 0, y: -50, rotation: -2}, {opacity: 1, y: 0, rotation: 0, duration: .45, ease: 'expo.out', stagger: .07}, t + .2);
  tl.fromTo(filters, {opacity: 0, y: -8}, {opacity: 1, y: 0, duration: .3, ease: 'power3.out', stagger: .03}, t + .1);
  tl.fromTo(q(id, '.cam'), {scale: 1}, {scale: 1.03, duration: s.end - t - .5, ease: 'sine.inOut'}, t + .5);
  const pinned = pin.closest('.kclip');
  tl.fromTo(pinned, {boxShadow: 'inset 0 0 0 0 rgba(191,234,242,0)'}, {boxShadow: 'inset 0 0 0 1.2px rgba(191,234,242,.85), 0 0 22px rgba(105,199,221,.35)', duration: .3, ease: 'power3.out'}, t + CB.pin);
  const keys = [{at: 1.4, x: fp[0].x + 60, y: fp[0].y + 120}];
  CB.filters.forEach(([a], i) => keys.push({at: a - .3, ...fp[i]}, {at: a, ...fp[i]}));
  keys.push({at: CB.pin - .3, ...pp}, {at: CB.pin, ...pp});
  onRender(id, local => {
    let f = 0; CB.filters.forEach(([a, i]) => { if (local >= a) f = i; });
    filters.forEach((el, i) => { const on = i === f;
      el.style.background = on ? 'rgba(191,234,242,.2)' : 'var(--surface2)'; el.style.color = on ? 'var(--ice)' : '#E8EDF2';
      el.style.boxShadow = on ? 'inset 0 .5px 0 rgba(255,255,255,.3)' : 'none'; });
    const want = f === 0 ? null : FILTERS[f] === '网址' ? 'url' : 'image';
    cards.forEach(el => { const on = !want || el.dataset.k === want;
      el.style.filter = on ? '' : 'brightness(.35) blur(1.5px)'; el.style.scale = on && want ? '1.03' : on ? '1' : '.96'; });
    const p = local >= CB.pin;
    pin.style.color = p ? 'var(--ink)' : 'var(--secondary)'; pin.style.background = p ? 'var(--ice)' : 'var(--surface2)';
    paintCursor(cur, local, keys, [...CB.filters.map(([a]) => a), CB.pin], [1.4, 5.4]);
  });
};

// ---------------- 9 · scheduled cleanup (AutoCleanupRulesView) ----------------
const SC = {preview: .96, on: 2.4};
const PREVIEW = [['候选项', 23, v => String(Math.round(v))], ['当前大小', 12.4, v => v.toFixed(2) + ' GB'], ['可回收', 4.2, v => v.toFixed(2) + ' GB'], ['清理后', 8.2, v => v.toFixed(2) + ' GB']];
function RuleHead({on, cls = '', name, path, meta}) {
  return <div className="hstack" style={{gap: 10}}>
    <span className={'switch ' + (on ? 'on ' : '') + cls}><i /></span><span style={{color: 'var(--ice)'}}><Icon.folder size={14} /></span>
    <div><b style={{fontSize: 13}}>{name}</b><div className="mono sec" style={{fontSize: 9.5, marginTop: 2}}>{path}</div></div>
    <span className="spacer" /><div className="sec" style={{fontSize: 9, textAlign: 'right', lineHeight: 1.5}}>{meta}</div>
  </div>;
}
export function ScheduleView({shot: s}) {
  return <div className="stage">
    <Aura opacity={.5} />
    <TitleCol s={s} kicker="Scheduled cleanup" />
    <div className="cam" style={{position: 'absolute', left: 800, top: 196}}>
      <div className="product zoomp proot" style={{zoom: 1.6, position: 'relative'}}>
        <div className="win" style={{width: 520, padding: 16}}>
          <div className="hstack" style={{gap: 10, alignItems: 'flex-start'}}>
            <span style={{color: '#E8EDF2', paddingTop: 1}}><Icon.history size={18} /></span>
            <div style={{flex: 1}}><div className="hstack"><span style={{fontSize: 15, fontWeight: 600}}>定时清理任务</span><span className="spacer" />
              <span className="sstatus hstack" style={{gap: 4, fontSize: 10, fontWeight: 600, color: 'var(--success)', opacity: 0}}><Icon.check size={10} />自动清理已就绪</span></div>
              <div className="sec" style={{fontSize: 10, marginTop: 4, lineHeight: 1.45}}>仅处理所选目录的第一层内容并移入废纸篓；容量策略会保护最近一小时内仍有写入的项目。</div></div>
          </div>
          <div className="row-glass srule" style={{marginTop: 12, padding: 12}}>
            <RuleHead cls="sswitch" name="Downloads" path="~/Downloads" meta={<>上次执行：尚未执行</>} />
            <div className="divider" style={{margin: '10px 0'}} />
            <div className="hstack" style={{gap: 10}}>
              <span className="sec" style={{fontSize: 10}}>策略</span>
              <span className="seg"><span>容量上限</span><span className="on">保留最近</span></span>
              <span className="num" style={{fontSize: 12, padding: '3px 10px', borderRadius: 6, background: 'var(--surface1)'}}>30</span><span className="sec" style={{fontSize: 10}}>天</span>
              <span className="spacer" />
              <span className="btn-secondary spreview" style={{height: 24, fontSize: 11}}><Icon.eye size={10} />预览</span>
              <span className="btn-secondary" style={{height: 24, fontSize: 11, color: 'var(--danger)', background: 'rgba(229,102,114,.08)'}}><Icon.trash size={10} />立即清理</span>
            </div>
            <div className="spanel" style={{overflow: 'hidden', height: 0}}>
              <div style={{paddingTop: 10}}>
                <div style={{fontSize: 11, fontWeight: 600, marginBottom: 6}}>清理预览</div>
                <div style={{display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 6}}>
                  {PREVIEW.map(([k]) => <div key={k} style={{padding: '6px 8px', borderRadius: 7, background: 'var(--surface1)'}}>
                    <div className="sec" style={{fontSize: 9}}>{k}</div><div className="num sval" style={{fontSize: 13, fontWeight: 700, marginTop: 2, color: k === '可回收' ? 'var(--ice)' : '#F2F5F8'}}>0</div></div>)}
                </div>
              </div>
            </div>
            <div className="hstack sec" style={{gap: 8, marginTop: 10, fontSize: 10}}><span className="cb on"><svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="#10283F" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"><path d="M3.5 8.4l3 3 6-6.8" /></svg></span>我确认该目录只包含可再生内容</div>
          </div>
          <div className="row-glass srule" style={{marginTop: 8, padding: 12}}>
            <RuleHead on name="DerivedData" path="~/Library/Developer/Xcode/DerivedData" meta={<>容量上限 15.0 GB<br />已执行 8 次 · 累计清理 46.2 GB</>} />
          </div>
        </div>
        <Cursor id="schedule" color="#fff" stroke="#10283F" />
      </div>
    </div>
    <DemoNote />
  </div>;
}
export const buildSchedule = tl => {
  const id = 'schedule', s = shot(id), t = s.start;
  const root = q(id, '.proot'), cur = q(id, '.film-cursor'), sw = q(id, '.sswitch'), panel = q(id, '.spanel');
  const pPrev = productPoint(q(id, '.spreview'), root), pSw = productPoint(sw, root);
  entrance(id, 'cut'); driveAura(id);
  buildTitleCol(tl, id, t + .05);
  tl.fromTo(q(id, '.win'), {opacity: 0, y: 40}, {opacity: 1, y: 0, duration: .4, ease: 'expo.out'}, t + .05);
  tl.fromTo(qa(id, '.srule'), {opacity: 0, x: 24}, {opacity: 1, x: 0, duration: .3, ease: 'power3.out', stagger: .08}, t + .15);
  tl.fromTo(q(id, '.sstatus'), {opacity: 0, x: 8}, {opacity: 1, x: 0, duration: .25, ease: 'power3.out'}, t + SC.on);
  tl.fromTo(q(id, '.cam'), {scale: 1}, {scale: 1.03, duration: s.end - t - .3, ease: 'sine.inOut'}, t + .3);
  const vals = qa(id, '.sval');
  onRender(id, local => {
    panel.style.height = 74 * easeOut(span(local, SC.preview + .05, SC.preview + .35)) + 'px';
    vals.forEach((el, i) => { const [, to, fmt] = PREVIEW[i]; el.textContent = fmt(to * easeOut(span(local, SC.preview + .1, SC.preview + .9 + i * .08))); });
    sw.classList.toggle('on', local >= SC.on);
    paintCursor(cur, local, [{at: .4, x: pPrev.x + 70, y: pPrev.y + 60}, {at: .8, ...pPrev}, {at: 2.0, ...pPrev}, {at: 2.3, ...pSw}], [SC.preview, SC.on], [.4, 3.3]);
  });
};

// ---------------- 10 · duplicate files (AnalyzeSectionViews · duplicates) ----------------
const DP = {scanEnd: 1.2, ticks: [2.4, 2.88]};
const DUPS = [
  {title: '第 1 组 · 3 个完全重复文件', rows: [['onboarding-final.mov', '~/Movies/onboarding-final.mov', '1.70 GB'],
    ['onboarding-final copy.mov', '~/Downloads/onboarding-final copy.mov', '1.70 GB', 0], ['onboarding-final.mov', '~/Desktop/导出/onboarding-final.mov', '1.70 GB', 1]]},
  {title: '第 2 组 · 2 个完全重复文件', rows: [['macOS-sdk.dmg', '~/Downloads/macOS-sdk.dmg', '2.90 GB'], ['macOS-sdk (1).dmg', '~/Downloads/macOS-sdk (1).dmg', '2.90 GB']]},
  {title: '第 3 组 · 4 个完全重复文件', rows: []},
];
const DUP_SEL = ['逐项勾选需要删除的文件，每组至少保留一份。', '已选 1 项 · 文件大小合计 1.70 GB', '已选 2 项 · 文件大小合计 3.40 GB'];
export function DuplicatesView({shot: s}) {
  return <div className="stage">
    <Aura opacity={.5} />
    <TitleCol s={s} kicker="Duplicate finder" />
    <div className="cam" style={{position: 'absolute', left: 800, top: 170}}>
      <div className="product zoomp proot" style={{zoom: 1.6, position: 'relative'}}>
        <div className="win" style={{width: 520, padding: 14}}>
          <div className="hstack" style={{gap: 8}}>
            <span style={{color: 'var(--ice)'}}><Icon.copy size={15} /></span><span style={{fontSize: 14, fontWeight: 600}}>重复文件</span>
            <span className="sec dsummary" style={{fontSize: 10, marginLeft: 4, opacity: 0}}>3 组 · 最多可释放 6.80 GB</span>
            <span className="spacer" /><span className="seg"><span className="on">完全重复</span><span>相似图片</span></span>
            <span className="btn-secondary" style={{height: 24, fontSize: 11}}><Icon.eye size={10} />重新查重</span>
          </div>
          <div style={{marginTop: 10}}>
            <div className="hstack" style={{fontSize: 10}}><span className="dstatus num sec">正在校验 0 / 1920 个候选</span><span className="spacer" /><span className="mono sec dpct" style={{fontSize: 9.5}}>0%</span></div>
            <div className="bar" style={{marginTop: 5}}><i className="dbar" style={{width: '0%', background: 'var(--ice)'}} /></div>
          </div>
          <div className="dgroups" style={{position: 'relative', marginTop: 10, display: 'flex', flexDirection: 'column', gap: 6}}>
            <div className="dwait" style={{position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 6}}>
              <span style={{fontSize: 13, fontWeight: 600}}>正在比较文件…</span>
              <span className="sec" style={{fontSize: 10}}>文件较多时需要一些时间，可随时取消扫描。</span>
            </div>
            {DUPS.map(g => <div key={g.title} className="row-glass dgroup" style={{padding: '8px 10px'}}>
              <div className="hstack" style={{fontSize: 11, fontWeight: 600}}>{g.title}<span className="spacer" /><span className="sec" style={{fontSize: 9.5, fontWeight: 400}}>每组至少保留一份</span></div>
              {g.rows.map(([n, path, size, tick], i) => <div key={i} className="hstack drow" data-tick={tick ?? ''} style={{gap: 8, marginTop: 6, padding: '4px 6px', borderRadius: 7}}>
                <span className="dcb"><span className="cb"><svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="#10283F" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"><path d="M3.5 8.4l3 3 6-6.8" /></svg></span></span>
                <span className="sec"><Icon.file size={12} /></span>
                <div style={{minWidth: 0}}><div style={{fontSize: 11, fontWeight: 500}}>{n}</div><div className="mono sec" style={{fontSize: 9, marginTop: 1}}>{path}</div></div>
                <span className="spacer" /><span className="size num dsize">{size}</span>
              </div>)}
            </div>)}
          </div>
          <div className="divider" style={{margin: '10px -14px 0'}} />
          <div className="hstack" style={{paddingTop: 10}}>
            <span className="dsel sec" style={{fontSize: 10.5}}>{DUP_SEL[0]}</span><span className="spacer" />
            <span className="btn-primary" style={{height: 30, fontSize: 12}}><Icon.trash size={11} />移入废纸篓</span>
          </div>
        </div>
        <Cursor id="duplicates" color="#fff" stroke="#10283F" />
      </div>
    </div>
    <DemoNote />
  </div>;
}
export const buildDuplicates = tl => {
  const id = 'duplicates', s = shot(id), t = s.start;
  const root = q(id, '.proot'), cur = q(id, '.film-cursor');
  const tickRows = DP.ticks.map((_, i) => q(id, `.drow[data-tick="${i}"]`));
  const pts = tickRows.map(r => productPoint(r.querySelector('.cb'), root));
  entrance(id, 'cut'); driveAura(id);
  buildTitleCol(tl, id, t + .05);
  tl.fromTo(q(id, '.win'), {opacity: 0, y: 40}, {opacity: 1, y: 0, duration: .4, ease: 'expo.out'}, t + .05);
  tl.fromTo(qa(id, '.dgroup'), {opacity: 0, y: 14}, {opacity: 0, y: 14}, t);
  tl.to(qa(id, '.dgroup'), {opacity: 1, y: 0, duration: .3, ease: 'expo.out', stagger: .08}, t + DP.scanEnd);
  tl.fromTo(q(id, '.dsummary'), {opacity: 0}, {opacity: 1, duration: .25}, t + DP.scanEnd);
  tl.to(q(id, '.dwait'), {opacity: 0, duration: .15}, t + DP.scanEnd - .05);
  tl.fromTo(q(id, '.cam'), {scale: 1}, {scale: 1.03, duration: s.end - t - .3, ease: 'sine.inOut'}, t + .3);
  const status = q(id, '.dstatus'), pct = q(id, '.dpct'), bar = q(id, '.dbar'), sel = q(id, '.dsel');
  onRender(id, local => {
    const k = span(local, .1, DP.scanEnd);
    status.textContent = local >= DP.scanEnd ? '找到 3 组' : `正在校验 ${Math.round(1920 * k)} / 1920 个候选`;
    status.style.color = local >= DP.scanEnd ? 'var(--success)' : '';
    pct.textContent = Math.round(k * 100) + '%'; bar.style.width = k * 100 + '%';
    let n = 0;
    tickRows.forEach((r, i) => { const on = local >= DP.ticks[i]; if (on) n++;
      r.querySelector('.cb').classList.toggle('on', on); r.querySelector('.dsize').classList.toggle('on', on);
      r.style.background = on ? 'rgba(191,234,242,.11)' : 'transparent'; });
    sel.textContent = DUP_SEL[n]; sel.style.color = n ? '#F2F5F8' : '';
    paintCursor(cur, local, [{at: 1.7, x: pts[0].x + 80, y: pts[0].y + 70}, {at: 2.2, ...pts[0]}, {at: 2.6, ...pts[0]}, {at: 2.8, ...pts[1]}], DP.ticks, [1.7, 3.6]);
  });
};

// ---------------- 11 · montage: one feature per beat ----------------
const BEAT = 60 / 125;
const MORE = [['灵动岛', 'Dynamic Island', 'cpu'], ['软件卸载', 'Uninstaller', 'appx'], ['磁盘分析', 'Disk analyzer', 'eye'], ['图片瘦身', 'Image slimming', 'sparkles'],
  ['模拟器设备', 'Simulator devices', 'hammer'], ['Docker 明细', 'Docker breakdown', 'folder'], ['进程', 'Processes', 'memory'], ['流量', 'Network traffic', 'globe']];
const TINT = ['var(--ribbon-blue)', 'var(--ribbon-gold)', 'var(--ribbon-lilac)'];
export function MontageView({shot: s}) {
  return <div className="stage">
    <Aura opacity={.8} />
    <div className="kicker" style={{position: 'absolute', left: 0, right: 0, top: 170, textAlign: 'center', margin: 0}}>And more · 还有</div>
    {MORE.map(([zh, en, icon], i) => { const I = Icon[icon];
      return <div key={zh} className="mitem" style={{position: 'absolute', left: 0, right: 0, top: 290, textAlign: 'center', opacity: 0}}>
        <div style={{width: 132, height: 132, margin: '0 auto', borderRadius: 66, display: 'flex', alignItems: 'center', justifyContent: 'center', color: TINT[i % 3],
          background: 'rgba(255,255,255,.08)', backdropFilter: 'blur(18px)', boxShadow: 'inset 0 1px 0 rgba(255,255,255,.22), inset 0 0 0 1px rgba(255,255,255,.06)'}}><I size={64} /></div>
        <div style={{fontFamily: 'var(--zh)', fontSize: 120, fontWeight: 600, marginTop: 34, lineHeight: 1.1}}>{zh}</div>
        <div style={{fontFamily: 'var(--en)', fontSize: 40, fontWeight: 600, color: 'var(--ice)', marginTop: 14}}>{en}</div>
      </div>; })}
    <div className="hstack" style={{position: 'absolute', left: 0, right: 0, top: 870, justifyContent: 'center', gap: 16}}>
      {MORE.map((_, i) => <i key={i} className="mdot" style={{width: 12, height: 12, borderRadius: 6, background: 'rgba(255,255,255,.18)'}} />)}
    </div>
  </div>;
}
export const buildMontage = tl => {
  const id = 'montage';
  entrance(id, 'cut'); driveAura(id);
  const items = qa(id, '.mitem'), dots = qa(id, '.mdot');
  onRender(id, local => {
    const k = Math.min(MORE.length - 1, Math.max(0, Math.floor(local / BEAT)));
    items.forEach((el, i) => {
      if (i !== k) { el.style.opacity = '0'; return; }
      const p = easeOut((local - i * BEAT) / .16);
      el.style.opacity = String(p);
      el.style.transform = `translateX(${70 * (1 - p)}px)`;
      el.style.filter = p < 1 ? `blur(${10 * (1 - p)}px)` : '';
    });
    dots.forEach((el, i) => { el.style.background = i <= k ? TINT[i % 3] : 'rgba(255,255,255,.18)'; el.style.transform = i === k ? 'scale(1.35)' : ''; });
  });
};
