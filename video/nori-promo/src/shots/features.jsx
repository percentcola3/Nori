import React from 'react';
import {Split, reveal} from '../kit/text.jsx';
import {shot, onRender} from '../engine.js';
import {Cursor, paintCursor} from '../kit/cursor.jsx';
import {q, qa, Aura, driveAura, Ribbons, entrance, Mascot, driveMascots, TitleCol, buildTitleCol, DemoNote,
  Icon, Checkbox, TitleBar, Tabs, counter, span, easeOut} from '../ui.jsx';

/** Centre of `el` in product points (the product root is zoomed). Call before any tween is placed. */
function productPoint(el, root) {
  const r = el.getBoundingClientRect(), b = root.getBoundingClientRect(), z = b.width / root.offsetWidth;
  return {x: (r.left + r.width / 2 - b.left) / z, y: (r.top + r.height / 2 - b.top) / z};
}
const Chev = ({open = true}) => <span className="chev" style={{transform: open ? 'none' : 'rotate(-90deg)'}}><Icon.chevron size={9} /></span>;

// ---------------- name wall: the "recognises all of these" opener shared by both signature shots ----------------
function NameWall({en, zh, names}) {
  return <div className="wall" style={{position: 'absolute', inset: 0}}>
    <div style={{position: 'absolute', left: 0, right: 0, top: 150, textAlign: 'center'}}>
      <div className="h-en wall-en" style={{fontSize: 60}}><Split text={en} lang="en" /></div>
      <div className="h-zh wall-zh" style={{fontSize: 52}}><Split text={zh} lang="zh-CN" /></div>
    </div>
    <div style={{position: 'absolute', left: 170, right: 170, top: 430, display: 'flex', flexWrap: 'wrap', justifyContent: 'center', gap: 14}}>
      {names.map(n => <span key={n} className="wchip" style={{fontFamily: 'var(--en)', fontSize: 28, fontWeight: 600, padding: '12px 26px', borderRadius: 99, color: '#EAF6F9',
        background: 'rgba(255,255,255,.08)', backdropFilter: 'blur(14px)', boxShadow: 'inset 0 1px 0 rgba(255,255,255,.18), inset 0 0 0 1px rgba(255,255,255,.06)'}}>{n}</span>)}
    </div>
  </div>;
}
function buildWall(tl, id, t, out) {
  reveal(tl, q(id, '.wall-en'), t + .1, {stagger: .012});
  reveal(tl, q(id, '.wall-zh'), t + .25, {stagger: .035});
  const chips = qa(id, '.wchip');
  tl.fromTo(chips, {opacity: 0, y: 30, scale: .85, filter: 'blur(8px)'},
    {opacity: 1, y: 0, scale: 1, filter: 'blur(0px)', duration: .4, ease: 'expo.out', stagger: .8 / chips.length}, t + .1);
  tl.to(q(id, '.wall'), {opacity: 0, y: -50, filter: 'blur(12px)', duration: .25, ease: 'power2.in'}, t + out - .25);
}

// ---------------- 3 · AI agents (AgentsTabView) ----------------
const AGENT_NAMES = ['Claude Code', 'Claude Desktop', 'Codex CLI', 'Codex App', 'Cursor', 'Cursor CLI', 'Copilot CLI', 'Gemini CLI',
  'Antigravity', 'OpenCode', 'Grok CLI', 'pi', 'Kimi', 'Factory Droid', 'Devin', 'Windsurf', 'Zed', 'Warp', 'Chrome DevTools MCP',
  'Qoder', 'Kiro', 'Trae', 'Amp', 'Crush'];
const AGENTS = [
  {tool: 'Claude Code', total: '3.00 GB', items: [
    {item: '旧版本 CLI', risk: 'safe', size: '1.20 GB', tick: 2.88}, {item: '会话记录', risk: 'warning', size: '1.80 GB'}]},
  {tool: 'Codex CLI', total: '1.38 GB', items: [
    {item: '日志', risk: 'safe', size: '420.0 MB', tick: 3.36}, {item: '归档会话', risk: 'warning', size: '960.0 MB'}]},
  {tool: 'Cursor', total: '1.50 GB', items: [
    {item: '缓存', risk: 'safe', size: '860.0 MB', tick: 3.84}, {item: '检查点', risk: 'warning', size: '640.0 MB'}]},
];
const AGENT_LABEL = ['清理', '清理 1 项 · 1.20 GB', '清理 2 项 · 1.62 GB', '清理 3 项 · 2.48 GB'];
const PANEL_AT = 1.92;
export function AgentsView({shot: s}) {
  return <div className="stage">
    <Aura opacity={.55} />
    <NameWall en="24 AI tools, recognized" zh="24 款 AI 工具，逐个识别" names={AGENT_NAMES} />
    <div className="panel-side">
      <TitleCol s={s} kicker="AI agent cleanup" />
      <div className="cam" style={{position: 'absolute', left: 800, top: 132}}>
        <div className="product zoomp proot" style={{zoom: 1.7}}>
          <div className="win" style={{width: 500}}>
            <TitleBar /><Tabs selected="Agent" />
            <div style={{padding: '0 12px 12px', display: 'flex', flexDirection: 'column', gap: 6}}>
              <div className="sec arow" style={{fontSize: 10.5, marginBottom: 2}}>清理前请退出相关 Agent；已卸载 Agent 的残留在「清理」页处理。</div>
              {AGENTS.map(g => <React.Fragment key={g.tool}>
                <div className="row-glass hstack arow" style={{gap: 8, padding: '0 10px', height: 30}}>
                  <span style={{color: '#DCE6EE'}}><Icon.brain size={14} /></span><b style={{fontSize: 13}}>{g.tool}</b><span className="spacer" />
                  <span className="sec" style={{fontSize: 10}}>可清理 {g.total}</span><span className="sec"><Icon.chevron size={10} /></span>
                </div>
                {g.items.map(a => <div key={a.item} className={'row-glass hstack arow aitem ' + a.risk} style={{gap: 8, padding: '0 10px', height: 32, marginLeft: 12}}>
                  <Checkbox /><span style={{fontSize: 12, fontWeight: 500}}>{a.item}</span><span className="sec" style={{fontSize: 10}}>1</span>
                  <span className={'tag ' + a.risk}>{a.risk === 'safe' ? 'Safe' : 'Warning'}</span><span className="spacer" />
                  <span className="size num">{a.size}</span><Chev />
                </div>)}
              </React.Fragment>)}
            </div>
            <div className="divider" />
            <div className="hstack" style={{padding: '10px 16px'}}>
              <span className="spacer" /><span className="btn-primary"><Icon.trash size={12} /><span className="aapply num">清理</span></span>
            </div>
          </div>
        </div>
      </div>
      <DemoNote />
    </div>
  </div>;
}
export const buildAgents = tl => {
  const id = 'agents', s = shot(id), t = s.start;
  entrance(id, 'cut'); driveAura(id);
  buildWall(tl, id, t, PANEL_AT);
  tl.fromTo(q(id, '.panel-side'), {opacity: 0}, {opacity: 1, duration: .01}, t + PANEL_AT - .01);
  buildTitleCol(tl, id, t + PANEL_AT);
  tl.fromTo(q(id, '.win'), {opacity: 0, y: 50}, {opacity: 1, y: 0, duration: .5, ease: 'expo.out'}, t + PANEL_AT);
  tl.fromTo(qa(id, '.arow'), {opacity: 0, x: 24}, {opacity: 1, x: 0, duration: .35, ease: 'power3.out', stagger: .045}, t + PANEL_AT + .1);
  tl.fromTo(q(id, '.cam'), {scale: 1}, {scale: 1.03, duration: s.end - t - PANEL_AT, ease: 'sine.inOut'}, t + PANEL_AT);
  const items = qa(id, '.aitem'), warns = items.filter(el => el.classList.contains('warning'));
  const others = qa(id, '.arow').filter(el => !warns.includes(el));
  const W = 4.56;
  tl.to(others, {opacity: .4, duration: .3, ease: 'power2.out'}, t + W);
  tl.fromTo(warns, {scale: 1, boxShadow: 'inset 0 0 0 0px rgba(227,164,60,0), 0 0 0 0 rgba(227,164,60,0)'},
    {scale: 1.03, boxShadow: 'inset 0 0 0 1.2px rgba(227,164,60,.95), 0 0 22px 2px rgba(227,164,60,.35)', duration: .35, ease: 'power3.out', stagger: .06}, t + W);
  tl.to(others, {opacity: 1, duration: .35, ease: 'power2.inOut'}, t + 6.5);
  tl.to(warns, {scale: 1, boxShadow: 'inset 0 0 0 .6px rgba(227,164,60,.6), 0 0 0 0 rgba(227,164,60,0)', duration: .35, ease: 'power2.inOut'}, t + 6.5);
  const label = q(id, '.aapply'), flat = AGENTS.flatMap(g => g.items);
  onRender(id, local => {
    let n = 0;
    flat.forEach((a, i) => {
      const on = a.tick !== undefined && local >= a.tick; if (on) n++;
      items[i].querySelector('.cb').classList.toggle('on', on);
      items[i].querySelector('.size').classList.toggle('on', on);
      items[i].classList.toggle('sel', on);
    });
    label.textContent = AGENT_LABEL[n];
  });
};

// ---------------- 4 · developer junk (CleanupTabView) ----------------
const TOOLS = ['Xcode', 'iOS 模拟器', 'SwiftPM', 'CocoaPods', 'npm', 'pnpm', 'Yarn', 'Bun', 'pip', 'uv', 'Poetry', 'Conda',
  'Gradle', 'Maven', 'Cargo', 'Go', 'Homebrew', 'Docker', 'NuGet', 'Flutter'];
const DEV_ROWS = [['Xcode 构建缓存', 18.4], ['iOS 模拟器缓存', 6.2], ['npm 缓存', 5.8], ['Gradle 缓存', 4.6], ['Go 构建缓存', 2.9], ['pip 缓存', 2.3], ['Yarn 缓存', 2.1]];
function GroupRow({icon, title, count, bytes, open}) {
  return <div className="row-glass hstack crow" style={{gap: 8, padding: '0 10px', height: 30}}>
    <Checkbox on /><span className="icon-circle">{icon}</span>
    <span style={{fontSize: 12, fontWeight: 600}}>{title}</span><span className="count">{count}</span>
    <span className="spacer" />
    <span className="num" data-to={bytes} style={{fontSize: 11, fontWeight: 600, color: 'var(--ice)'}}>0.00 GB</span>
    <Chev open={open} />
  </div>;
}
function SubRow({title, bytes}) {
  return <div className="row-glass hstack crow" style={{gap: 8, padding: '0 10px', height: 28, marginLeft: 12}}>
    <Checkbox on /><span style={{fontSize: 12, fontWeight: 500}}>{title}</span><span className="sec" style={{fontSize: 10}}>1</span>
    <span className="tag safe">Safe</span><span className="spacer" />
    <span className="size on num" data-to={bytes}>0.00 GB</span>
    <span className="icon-btn"><Icon.history size={11} /></span><Chev />
  </div>;
}
const DJ = {click: 4.8, success: 5.1};
export function DevjunkView({shot: s}) {
  return <div className="stage">
    <Aura opacity={.5} />
    <NameWall en="Every toolchain, recognized" zh="从 Xcode 到 Cargo，一眼识别" names={TOOLS} />
    <div className="panel-side">
      <TitleCol s={s} kicker="Developer junk" />
      <div className="cam" style={{position: 'absolute', left: 800, top: 112}}>
        <div className="product zoomp proot" style={{zoom: 1.6, position: 'relative'}}>
          <div className="win" style={{width: 500}}>
            <TitleBar /><Tabs selected="清理" />
            <div style={{position: 'relative', padding: '0 12px 10px'}}>
              <div className="clist" style={{display: 'flex', flexDirection: 'column', gap: 5}}>
                <GroupRow icon={<Icon.hammer size={11} />} title="开发环境垃圾" count="7" bytes={42.3} open />
                {DEV_ROWS.map(([n, b]) => <SubRow key={n} title={n} bytes={b} />)}
                <GroupRow icon={<Icon.sparkles size={11} />} title="缓存垃圾" count="3" bytes={6.1} open={false} />
                <GroupRow icon={<Icon.appx size={11} />} title="卸载残余垃圾" count="1" bytes={1.6} open={false} />
              </div>
              <div className="csuccess" style={{position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', opacity: 0}}>
                <Mascot mood="success" size={170} />
                <div style={{fontSize: 16, fontWeight: 600, marginTop: 4}}>清理完成</div>
                <div className="sec" style={{fontSize: 11, marginTop: 4}}>已清理 11 个项目 · 50.00 GB</div>
              </div>
            </div>
            <div className="divider" />
            <div className="hstack" style={{padding: '10px 16px'}}>
              <span className="spacer" />
              <span className="btn-primary capply"><Icon.trash size={12} /><span>清理 <span className="num capply-n">0.00 GB</span></span></span>
            </div>
          </div>
          <Cursor id="devjunk" color="#fff" stroke="#10283F" />
        </div>
      </div>
      <DemoNote />
    </div>
  </div>;
}
export const buildDevjunk = async tl => {
  const id = 'devjunk', s = shot(id), t = s.start;
  const root = q(id, '.proot'), btn = q(id, '.capply'), cur = q(id, '.film-cursor');
  const target = productPoint(btn, root);
  entrance(id, 'cut'); driveAura(id);
  buildWall(tl, id, t, PANEL_AT);
  tl.fromTo(q(id, '.panel-side'), {opacity: 0}, {opacity: 1, duration: .01}, t + PANEL_AT - .01);
  buildTitleCol(tl, id, t + PANEL_AT);
  tl.fromTo(q(id, '.win'), {opacity: 0, y: 50}, {opacity: 1, y: 0, duration: .5, ease: 'expo.out'}, t + PANEL_AT);
  tl.fromTo(qa(id, '.crow'), {opacity: 0, x: 24}, {opacity: 1, x: 0, duration: .35, ease: 'power3.out', stagger: .045}, t + PANEL_AT + .1);
  tl.fromTo(q(id, '.cam'), {scale: 1}, {scale: 1.03, duration: s.end - t - PANEL_AT, ease: 'sine.inOut'}, t + PANEL_AT);
  tl.fromTo(btn, {scale: 1}, {keyframes: {scale: [1, .955, 1]}, duration: .25, ease: 'power2.out'}, t + DJ.click);
  tl.to(q(id, '.clist'), {opacity: 0, filter: 'blur(8px)', y: -8, duration: .25, ease: 'power2.in'}, t + DJ.success);
  tl.to(btn, {opacity: 0, duration: .2}, t + DJ.success);
  tl.fromTo(q(id, '.csuccess'), {opacity: 0, y: 10}, {opacity: 1, y: 0, duration: .4, ease: 'power3.out'}, t + DJ.success + .1);
  const nums = qa(id, '[data-to]'), total = q(id, '.capply-n');
  onRender(id, local => {
    nums.forEach((el, i) => counter(el, local, 2.0 + i * .045, 3.0 + i * .045, 0, Number(el.dataset.to), v => v.toFixed(2) + ' GB'));
    counter(total, local, 2.0, 3.4, 0, 50, v => v.toFixed(2) + ' GB');
    paintCursor(cur, local, [{at: 3.9, x: target.x + 150, y: target.y + 70}, {at: 4.6, x: target.x, y: target.y}], [DJ.click], [3.9, 5.3]);
  });
  await driveMascots(id, {success: DJ.success});
};

// ---------------- 5 · dev environment maintenance (DevEnvTabView) ----------------
const Radio = ({size = 12}) => <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
  <circle cx="8" cy="8" r="1.4" fill="currentColor" /><path d="M5.2 5.2a4 4 0 0 0 0 5.6M10.8 5.2a4 4 0 0 1 0 5.6M3.2 3.2a6.8 6.8 0 0 0 0 9.6M12.8 3.2a6.8 6.8 0 0 1 0 9.6" /></svg>;
const Term = ({size = 12}) => <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
  <rect x="1.8" y="2.6" width="12.4" height="10.8" rx="2" /><path d="M4.6 6.4l2 1.6-2 1.6M8.4 10h3" /></svg>;
function EnvCard({icon, title, status, children, foot}) {
  return <div className="row-glass ecard" style={{width: 250, height: 196, padding: '11px 12px', borderRadius: 12, display: 'flex', flexDirection: 'column'}}>
    <div className="hstack" style={{gap: 7}}><span style={{color: 'var(--ice)'}}>{icon}</span><b style={{fontSize: 13}}>{title}</b><span className="spacer" />{status}</div>
    <div style={{flex: 1, marginTop: 9, display: 'flex', flexDirection: 'column', gap: 5}}>{children}</div>
    {foot && <div className="sec" style={{fontSize: 9.5, marginTop: 6}}>{foot}</div>}
  </div>;
}
const KV = ({k, v, cls = ''}) => <div className={'hstack ' + cls} style={{gap: 6, padding: '4px 7px', borderRadius: 6, background: 'var(--surface1)', fontSize: 10}}>
  <span className="mono" style={{fontWeight: 600, color: '#F2F5F8'}}>{k}</span><span className="spacer" /><span className="mono sec" style={{fontSize: 9.5}}>{v}</span></div>;
const EV = {shell: 1.44, hosts: 2.4, runtime: 3.36, path: 4.32};
export function DevenvView({shot: s}) {
  return <><div className="stage">
    <Aura opacity={.5} />
    <TitleCol s={s} kicker="Dev environment" />
    <div className="cam" style={{position: 'absolute', left: 790, top: 214}}>
      <div className="product zoomp proot" style={{zoom: 1.6, position: 'relative'}}>
        <div style={{display: 'grid', gridTemplateColumns: '250px 250px', gap: 12}}>
          <EnvCard icon={<Term size={13} />} title="环境与 Shell" status={<span className="sec" style={{fontSize: 9.5}}>~/.zshrc · 已读取</span>}
            foot={<span className="eshell-foot">在新 Shell 中生效；现有终端继续运行。</span>}>
            <KV k="JAVA_HOME" v="/Library/Java/…/Home" cls="eshell-row" />
            <KV k="ANDROID_HOME" v="~/Library/Android/sdk" />
            <KV k="GOPATH" v="~/go" />
            <div className="hstack eshell-toast" style={{gap: 5, fontSize: 10, fontWeight: 600, color: 'var(--success)', marginTop: 2, opacity: 0}}><Icon.check size={10} />已保存 JAVA_HOME · 原文件已备份</div>
          </EnvCard>
          <EnvCard icon={<Icon.globe size={13} />} title="网络与 hosts" status={<span className="sec ehosts-count" style={{fontSize: 9.5}}>3 条自定义映射</span>}
            foot="代理 · 未启用 HTTP / HTTPS / SOCKS / PAC">
            <KV k="127.0.0.1" v="api.local" />
            <KV k="127.0.0.1" v="admin.local" />
            <KV k="10.0.0.12" v="db.dev" />
            <div className="ehosts-new"><KV k="127.0.0.1" v="web.local" /></div>
          </EnvCard>
          <EnvCard icon={<Icon.hammer size={13} />} title="运行时清理" status={<span className="sec" style={{fontSize: 9.5}}>nvm</span>}
            foot={<span className="eruntime-foot">保留当前 / 默认 nvm；旧版本可移入废纸篓。</span>}>
            <div className="hstack" style={{gap: 7, padding: '5px 7px', borderRadius: 6, background: 'var(--surface1)'}}>
              <span className="sec"><Icon.lock size={11} /></span><b style={{fontSize: 11}}>v22.14.0</b><span style={{fontSize: 9.5, color: 'var(--warning)'}}>当前 / 默认</span>
              <span className="spacer" /><span className="size num">210.0 MB</span></div>
            <div className="hstack eruntime-row" style={{gap: 7, padding: '5px 7px', borderRadius: 6, background: 'var(--surface1)'}}>
              <span className="eruntime-cb"><Checkbox /></span><b style={{fontSize: 11}}>v20.18.0</b>
              <span className="spacer" /><span className="size num eruntime-size">480.0 MB</span></div>
            <div className="hstack" style={{gap: 7, padding: '5px 7px', borderRadius: 6, background: 'var(--surface1)'}}>
              <Checkbox /><b style={{fontSize: 11}}>v18.20.4</b><span className="spacer" /><span className="size num">410.0 MB</span></div>
          </EnvCard>
          <EnvCard icon={<Term size={13} />} title="CLI 工具" status={<span className="sec" style={{fontSize: 9.5}}>已发现 18 个工具</span>}
            foot={<span className="hstack" style={{gap: 6}}><span className="btn-secondary" style={{height: 20, fontSize: 9.5, padding: '0 8px'}}>仅看问题</span>
              <span className="btn-secondary" style={{height: 20, fontSize: 9.5, padding: '0 8px'}}><Icon.copy size={9} />复制 Nori PATH</span></span>}>
            <KV k="node" v="22.14.0 · ~/.nvm" />
            <div className="epath-row" style={{borderRadius: 6}}><KV k="python3" v="3.12.4 · /opt/homebrew" /></div>
            <div className="hstack epath-chip" style={{gap: 5, fontSize: 9.5, fontWeight: 600, color: 'var(--warning)', paddingLeft: 7, opacity: 0}}>⚠︎ PATH 多来源 · 另有 /usr/bin/python3</div>
            <KV k="git" v="2.45.2 · /usr/bin" />
          </EnvCard>
        </div>
        <Cursor id="devenv" color="#fff" stroke="#10283F" />
      </div>
    </div>
    <DemoNote />
  </div><Ribbons /></>;
}
export const buildDevenv = tl => {
  const id = 'devenv', s = shot(id), t = s.start;
  const root = q(id, '.proot'), cb = q(id, '.eruntime-cb .cb'), cur = q(id, '.film-cursor');
  const pCb = productPoint(cb, root);
  entrance(id, 'wipe'); driveAura(id);
  buildTitleCol(tl, id, t + .25);
  const cards = qa(id, '.ecard');
  tl.fromTo(cards, {opacity: 0, y: 40, scale: .96}, {opacity: 1, y: 0, scale: 1, duration: .4, ease: 'expo.out', stagger: .09}, t + .15);
  tl.fromTo(q(id, '.cam'), {scale: 1}, {scale: 1.03, duration: s.end - t - .6, ease: 'sine.inOut'}, t + .6);
  tl.fromTo(q(id, '.eshell-toast'), {opacity: 0, y: 6}, {opacity: 1, y: 0, duration: .3, ease: 'power3.out'}, t + EV.shell);
  tl.fromTo(q(id, '.eshell-row'), {boxShadow: 'inset 0 0 0 0 rgba(83,198,140,0)'}, {boxShadow: 'inset 0 0 0 1px rgba(83,198,140,.8)', duration: .3}, t + EV.shell);
  tl.fromTo(q(id, '.ehosts-new'), {opacity: 0, x: 16}, {opacity: 1, x: 0, duration: .35, ease: 'expo.out'}, t + EV.hosts);
  tl.fromTo(q(id, '.ehosts-new > div'), {boxShadow: 'inset 0 0 0 1px rgba(191,234,242,.9)'}, {boxShadow: 'inset 0 0 0 1px rgba(191,234,242,0)', duration: 1.2, ease: 'power2.in'}, t + EV.hosts + .3);
  tl.fromTo(q(id, '.epath-chip'), {opacity: 0, y: -4}, {opacity: 1, y: 0, duration: .3, ease: 'power3.out'}, t + EV.path);
  tl.fromTo(q(id, '.epath-row'), {boxShadow: 'inset 0 0 0 0 rgba(227,164,60,0)'}, {boxShadow: 'inset 0 0 0 1.2px rgba(227,164,60,.9)', duration: .3}, t + EV.path);
  const focus = [EV.shell, EV.hosts, EV.runtime, EV.path], hostsCount = q(id, '.ehosts-count');
  const rRow = q(id, '.eruntime-row'), rSize = q(id, '.eruntime-size'), rFoot = q(id, '.eruntime-foot');
  onRender(id, local => {
    let f = -1; focus.forEach((at, i) => { if (local >= at - .3) f = i; });
    cards.forEach((el, i) => {
      const on = f === i, k = on ? easeOut(span(local, focus[i] - .3, focus[i])) : 0;
      el.style.boxShadow = on ? `inset 0 0 0 ${1.2 * k}px rgba(191,234,242,.7), 0 0 ${26 * k}px rgba(105,199,221,${.3 * k})` : '';
      el.style.filter = f >= 0 && !on ? 'brightness(.62)' : '';
    });
    hostsCount.textContent = local >= EV.hosts ? '4 条自定义映射' : '3 条自定义映射';
    const ticked = local >= EV.runtime;
    cb.classList.toggle('on', ticked); rSize.classList.toggle('on', ticked);
    rRow.style.background = ticked ? 'rgba(191,234,242,.11)' : 'var(--surface1)';
    rFoot.textContent = ticked ? '已选 1 个版本 · 480.0 MB' : '保留当前 / 默认 nvm；旧版本可移入废纸篓。';
    paintCursor(cur, local, [{at: 2.6, x: pCb.x + 90, y: pCb.y + 60}, {at: 3.2, x: pCb.x, y: pCb.y}], [EV.runtime], [2.6, 4.0]);
  });
};

// ---------------- 6 · ports (ProcessesTabView · PortsTabView) ----------------
const PORTS = [['3000', 'node', '127.0.0.1:3000', 48213], ['5173', 'node', '127.0.0.1:5173', 48377], ['8080', 'java', '*:8080', 31902],
  ['5432', 'postgres', '127.0.0.1:5432', 812], ['6379', 'redis-server', '127.0.0.1:6379', 907], ['11434', 'ollama', '127.0.0.1:11434', 1544]];
const PT = {click: 1.2, confirm: 1.92};
const Danger = ({cls = '', children}) => <span className={'hstack ' + cls} style={{height: 24, padding: '0 11px', borderRadius: 99, fontSize: 11, fontWeight: 600,
  color: 'var(--danger)', background: 'rgba(229,102,114,.14)', boxShadow: 'inset 0 0 0 .5px rgba(229,102,114,.35)'}}>{children}</span>;
export function PortsView({shot: s}) {
  return <div className="stage">
    <Aura opacity={.5} />
    <TitleCol s={s} kicker="Port manager" />
    <div className="cam" style={{position: 'absolute', left: 800, top: 210}}>
      <div className="product zoomp proot" style={{zoom: 1.64, position: 'relative'}}>
        <div className="win" style={{width: 510}}>
          <TitleBar /><Tabs selected="端口" />
          <div style={{padding: '0 12px 12px', display: 'flex', flexDirection: 'column'}}>
            {PORTS.map(([port, proc, ep, pid], i) => <div key={port} className="prow-wrap" style={{overflow: 'hidden'}}>
              <div className="hstack prow" style={{gap: 10, padding: '0 12px', height: 40, borderRadius: 9, background: 'var(--surface2)', marginBottom: 6}}>
                <span style={{color: 'var(--ice)'}}><Radio size={14} /></span>
                <div><div style={{fontSize: 12, fontWeight: 500}}>端口 {port} · {proc}</div>
                  <div className="sec mono" style={{fontSize: 9.5, marginTop: 2}}>{ep} · PID {pid}</div></div>
                <span className="spacer" />
                <Danger cls={i === 0 ? 'pclose' : ''}>关闭</Danger>
              </div>
            </div>)}
          </div>
        </div>
        <div className="pconfirm win" style={{position: 'absolute', left: 115, top: 120, width: 280, padding: 16, textAlign: 'center', opacity: 0, background: 'rgba(22,48,72,.9)'}}>
          <div style={{fontSize: 13, fontWeight: 600}}>关闭 PID 48213 占用的端口？</div>
          <div className="sec" style={{fontSize: 10.5, marginTop: 6}}>端口 3000 · node</div>
          <div className="hstack" style={{gap: 8, marginTop: 14, justifyContent: 'center'}}>
            <span className="btn-secondary" style={{height: 26, fontSize: 11, padding: '0 18px'}}>取消</span>
            <Danger cls="pok">关闭</Danger>
          </div>
        </div>
        <Cursor id="ports" color="#fff" stroke="#10283F" />
      </div>
    </div>
    <DemoNote />
  </div>;
}
export const buildPorts = tl => {
  const id = 'ports', s = shot(id), t = s.start;
  const root = q(id, '.proot'), cur = q(id, '.film-cursor');
  const p1 = productPoint(q(id, '.pclose'), root), p2 = productPoint(q(id, '.pok'), root);
  entrance(id, 'cut'); driveAura(id);
  buildTitleCol(tl, id, t + .05);
  tl.fromTo(q(id, '.win'), {opacity: 0, y: 40}, {opacity: 1, y: 0, duration: .45, ease: 'expo.out'}, t + .05);
  tl.fromTo(qa(id, '.prow'), {opacity: 0, x: 24}, {opacity: 1, x: 0, duration: .3, ease: 'power3.out', stagger: .05}, t + .15);
  tl.fromTo(q(id, '.pconfirm'), {opacity: 0, scale: .92}, {opacity: 1, scale: 1, duration: .25, ease: 'expo.out'}, t + PT.click + .1);
  tl.to(q(id, '.pconfirm'), {opacity: 0, scale: .96, duration: .18, ease: 'power2.in'}, t + PT.confirm + .08);
  tl.fromTo(q(id, '.pclose'), {scale: 1}, {keyframes: {scale: [1, .9, 1]}, duration: .2}, t + PT.click);
  tl.fromTo(q(id, '.pok'), {scale: 1}, {keyframes: {scale: [1, .9, 1]}, duration: .2}, t + PT.confirm);
  const first = q(id, '.prow-wrap'), row = first.querySelector('.prow'), h = 46;
  onRender(id, local => {
    const k = easeOut(span(local, PT.confirm + .1, PT.confirm + .45));
    first.style.height = (h * (1 - k)) + 'px';
    row.style.opacity = String(1 - k);
    row.style.transform = `translateX(${-30 * k}px)`;
    paintCursor(cur, local, [{at: .5, x: p1.x + 80, y: p1.y + 70}, {at: 1.0, x: p1.x, y: p1.y}, {at: 1.35, x: p1.x, y: p1.y}, {at: 1.75, x: p2.x, y: p2.y}], [PT.click, PT.confirm], [.5, 2.8]);
  });
};
