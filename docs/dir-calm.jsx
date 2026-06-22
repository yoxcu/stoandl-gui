/* Kirigami-calm — KDE/Breeze native (FormCard + NavigationTabBar, Plasma blue),
   but with the calm GNOME-like rhythm the user liked: symbolic monochrome icons
   (no colored tiles), generous whitespace, neutral section headers, clamped feel.
   Goal: feels at home on Plasma Mobile, reads as quiet as a libadwaita app. */

const CALM = {
  win: '#222528', view: '#191b1d', card: '#26292d', head: '#26292d',
  text: '#f4f5f6', dim: '#9ba0a8', faint: 'rgba(255,255,255,0.26)',
  div: 'rgba(255,255,255,0.07)', accent: '#3daee9', accentDim: 'rgba(61,174,233,0.16)',
  good: '#4bbd7a', danger: '#e15c6a',
  font: '"Noto Sans","Segoe UI",system-ui,sans-serif',
};

function CSwitch({ on, onClick }) {
  return (
    <button onClick={onClick} style={{ width: 44, height: 25, borderRadius: 13, border: 'none', cursor: 'pointer', flex: '0 0 auto', padding: 0, background: on ? CALM.accent : 'rgba(255,255,255,0.14)', position: 'relative', transition: 'background .16s' }}>
      <span style={{ position: 'absolute', top: 3, left: on ? 22 : 3, width: 19, height: 19, borderRadius: 10, background: '#fff', transition: 'left .16s', boxShadow: '0 1px 2px rgba(0,0,0,0.35)' }} />
    </button>
  );
}

function CCard({ children, style }) {
  return (
    <div style={{ background: CALM.card, borderRadius: 12, overflow: 'hidden', ...style }}>
      {React.Children.map(children, (c, i) => (
        <React.Fragment>
          {i > 0 && <div style={{ height: 1, background: CALM.div, marginLeft: 18 }} />}
          {c}
        </React.Fragment>
      ))}
    </div>
  );
}
function CHead({ children }) {
  return <div style={{ fontSize: 12, fontWeight: 700, color: CALM.dim, letterSpacing: 0.5, padding: '0 6px 9px', textTransform: 'uppercase' }}>{children}</div>;
}
// Symbolic monochrome row — no colored icon tile (GNOME action-row vibe).
function CRow({ icon, title, subtitle, trailing, onClick, danger }) {
  return (
    <div onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 15, padding: '15px 18px', cursor: onClick ? 'pointer' : 'default', color: danger ? CALM.danger : CALM.text }}>
      {icon && <span style={{ color: danger ? CALM.danger : CALM.dim, flex: '0 0 auto', display: 'flex' }}><Icon name={icon} size={20} stroke={1.8} /></span>}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 15, fontWeight: 500, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</div>
        {subtitle && <div style={{ fontSize: 12.5, color: CALM.dim, marginTop: 3, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{subtitle}</div>}
      </div>
      {trailing}
    </div>
  );
}
function CChip({ children, tone }) {
  const colors = { active: CALM.accent, system: CALM.faint, config: '#b07cc6', sideloaded: '#cf9b54' };
  const c = colors[tone] || CALM.faint;
  const solid = tone === 'active';
  return <span style={{ fontSize: 10, fontWeight: 700, padding: '2px 7px', borderRadius: 6, background: solid ? CALM.accentDim : 'transparent', color: solid ? CALM.accent : c, border: solid ? 'none' : `1px solid ${c}` }}>{children}</span>;
}

function CalmApp() {
  const S = window.STO;
  const [tab, setTab] = React.useState('watch');
  const [seg, setSeg] = React.useState('faces');
  const [sync, setSync] = React.useState(() => Object.fromEntries(S.sync.map(s => [s.id, s.on])));
  const [ext, setExt] = React.useState(() => Object.fromEntries(S.extensions.map(e => [e.name, e.enabled])));
  const [ws, setWs] = React.useState(S.watchSettings);

  const tabs = [['watch', 'watch', 'Watch'], ['apps', 'apps', 'Apps'], ['ext', 'puzzle', 'Plugins'], ['settings', 'sliders', 'Sync'], ['system', 'tools', 'System']];
  const titles = { watch: 'Watch', apps: 'Apps & Faces', ext: 'Extensions', settings: 'Sync & Settings', system: 'System' };

  const scroll = (children) => <div style={{ flex: 1, overflowY: 'auto', padding: '8px 16px 24px' }}>{children}</div>;

  let body;
  if (tab === 'watch') {
    body = scroll(<>
      <div style={{ textAlign: 'center', padding: '14px 0 22px' }}>
        <WatchGlyph size={78} accent={CALM.accent} />
        <div style={{ fontSize: 21, fontWeight: 700, marginTop: 8 }}>{S.watch.name}</div>
        <div style={{ fontSize: 13, color: CALM.dim, marginTop: 3 }}>{S.watch.model}</div>
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 7, marginTop: 12, background: 'rgba(75,189,122,0.14)', borderRadius: 20, padding: '5px 13px' }}>
          <span style={{ width: 6, height: 6, borderRadius: 3, background: CALM.good }} />
          <span style={{ fontSize: 12, color: CALM.good, fontWeight: 600 }}>Connected · {S.watch.transport}</span>
        </div>
      </div>
      <CCard style={{ marginBottom: 22 }}>
        <CRow icon="battery" title="Battery" trailing={<span style={{ fontSize: 14, fontWeight: 600, color: CALM.good }}>{S.watch.battery}%</span>} />
        <CRow icon="download" title="Firmware" subtitle={S.firmware.updateAvailable ? 'Update available' : 'Up to date'} trailing={<span style={{ fontSize: 13.5, color: CALM.dim }}>{S.watch.firmware}</span>} onClick={() => setTab('system')} />
        <CRow icon="sync" title="Last sync" trailing={<span style={{ fontSize: 13.5, color: CALM.dim }}>{S.watch.lastSync}</span>} />
      </CCard>
      <CHead>Known watches</CHead>
      <CCard>
        {S.knownWatches.map(w => (
          <CRow key={w.code} icon="watch" title={`${w.name} · ${w.code}`} subtitle={`${w.model} · ${w.transport}`}
            trailing={w.connected ? <CChip tone="active">active</CChip> : <span style={{ fontSize: 13, color: CALM.accent, fontWeight: 600 }}>Connect</span>} />
        ))}
        <CRow icon="plus" title="Pair new watch" onClick={() => {}} trailing={<Icon name="chevron" size={16} style={{ color: CALM.faint }} />} />
      </CCard>
    </>);
  } else if (tab === 'apps') {
    const list = seg === 'faces' ? S.faces : S.apps;
    body = scroll(<>
      <div style={{ display: 'flex', gap: 8, marginBottom: 18, padding: '4px 0' }}>
        {[['faces', 'Watchfaces'], ['apps', 'Apps']].map(([k, l]) => (
          <button key={k} onClick={() => setSeg(k)} style={{ flex: 1, padding: '9px 0', borderRadius: 20, border: `1px solid ${seg === k ? 'transparent' : CALM.div}`, cursor: 'pointer', fontFamily: CALM.font, fontSize: 13, fontWeight: 600, background: seg === k ? CALM.accentDim : 'transparent', color: seg === k ? CALM.accent : CALM.dim }}>{l}</button>
        ))}
      </div>
      <CCard>
        {list.map(item => (
          <CRow key={item.uuid} icon={item.flags.includes('active') ? 'star' : (seg === 'faces' ? 'watch' : 'apps')}
            title={item.name} subtitle={item.uuid}
            trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>{item.flags.map(f => <CChip key={f} tone={f}>{f}</CChip>)}<Icon name="kebab" size={17} style={{ color: CALM.faint }} /></div>} />
        ))}
        <CRow icon="download" title={`Install ${seg === 'faces' ? 'watchface' : 'app'} (.pbw)`} onClick={() => {}} trailing={<Icon name="chevron" size={16} style={{ color: CALM.faint }} />} />
      </CCard>
    </>);
  } else if (tab === 'ext') {
    body = scroll(<>
      <CHead>Companion apps</CHead>
      <CCard>
        {S.extensions.map(e => (
          <CRow key={e.name} icon="puzzle" title={e.name} subtitle={e.desc}
            trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>{ext[e.name] && <span style={{ width: 6, height: 6, borderRadius: 3, background: CALM.good }} />}<CSwitch on={ext[e.name]} onClick={() => setExt(p => ({ ...p, [e.name]: !p[e.name] }))} /></div>} />
        ))}
        <CRow icon="plus" title="Install extension" onClick={() => {}} trailing={<Icon name="chevron" size={16} style={{ color: CALM.faint }} />} />
      </CCard>
    </>);
  } else if (tab === 'settings') {
    body = scroll(<>
      <CHead>Sync services</CHead>
      <CCard style={{ marginBottom: 22 }}>
        {S.sync.map(s => <CRow key={s.id} icon={syncIcon(s.id)} title={s.name} subtitle={s.desc} trailing={<CSwitch on={sync[s.id]} onClick={() => setSync(p => ({ ...p, [s.id]: !p[s.id] }))} />} />)}
      </CCard>
      <CHead>Watch settings</CHead>
      <CCard style={{ marginBottom: 22 }}>
        <CRow icon="power" title="Quick launch · Up" trailing={<ComboC value={ws.quickLaunchUp} />} />
        <CRow icon="power" title="Quick launch · Down" trailing={<ComboC value={ws.quickLaunchDown} />} />
        <CRow icon="sun" title="Backlight" subtitle={`Timeout ${ws.backlightTimeout}s`} trailing={<CSwitch on={ws.backlight} onClick={() => setWs(p => ({ ...p, backlight: !p.backlight }))} />} />
        <CRow icon="sun" title="Motion backlight" subtitle="Wake on wrist flick" trailing={<CSwitch on={ws.motionBacklight} onClick={() => setWs(p => ({ ...p, motionBacklight: !p.motionBacklight }))} />} />
      </CCard>
      <CCard>
        <div style={{ padding: '16px 18px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 14, fontWeight: 500 }}><span>Ambient light threshold</span><span style={{ color: CALM.accent, fontWeight: 600 }}>{ws.ambientThreshold} lx</span></div>
          <div style={{ marginTop: 13 }}><SliderC value={ws.ambientThreshold} min={0} max={400} onChange={v => setWs(p => ({ ...p, ambientThreshold: v }))} /></div>
        </div>
      </CCard>
    </>);
  } else {
    body = scroll(<>
      {S.firmware.updateAvailable && (
        <CCard style={{ marginBottom: 22 }}>
          <div style={{ padding: '18px' }}>
            <div style={{ fontSize: 16, fontWeight: 700 }}>Firmware update</div>
            <div style={{ fontSize: 13, color: CALM.dim, marginTop: 4 }}>{S.firmware.current} → {S.firmware.latest} · {S.firmware.channel}</div>
            <button style={{ width: '100%', marginTop: 14, padding: '11px 0', borderRadius: 10, border: 'none', background: CALM.accent, color: '#06151d', fontFamily: CALM.font, fontSize: 14.5, fontWeight: 700, cursor: 'pointer' }}>Flash {S.firmware.latest}</button>
          </div>
        </CCard>
      )}
      <CHead>System</CHead>
      <CCard style={{ marginBottom: 22 }}>
        <CRow icon="globe" title="Language pack" subtitle={S.language.current} onClick={() => {}} trailing={<Icon name="chevron" size={16} style={{ color: CALM.faint }} />} />
        <CRow icon="archive" title="Backup & restore" subtitle={`${S.backup.last} · ${S.backup.size}`} onClick={() => {}} trailing={<Icon name="chevron" size={16} style={{ color: CALM.faint }} />} />
      </CCard>
      <CHead>Diagnostics</CHead>
      <CCard style={{ marginBottom: 22 }}>
        <CRow icon="camera" title="Capture screenshot" onClick={() => {}} />
        <CRow icon="file" title="Pull watch logs" onClick={() => {}} />
        <CRow icon="archive" title="Support bundle" subtitle="Redacted .tar.gz" onClick={() => {}} />
      </CCard>
      <CHead>Danger zone</CHead>
      <CCard>
        <CRow icon="refresh" danger title="Reboot to recovery (PRF)" onClick={() => {}} />
        <CRow icon="alert" danger title="Factory reset" subtitle="Irreversible · wipes the watch" onClick={() => {}} />
      </CCard>
    </>);
  }

  return (
    <PhoneFrame bg={CALM.win}>
      <div style={{ display: 'flex', flexDirection: 'column', height: '100%', fontFamily: CALM.font, color: CALM.text, position: 'relative' }}>
        <StatusBar />
        <div style={{ height: 52, flex: '0 0 52px', display: 'flex', alignItems: 'center', padding: '0 8px', background: CALM.win }}>
          <div style={{ flex: 1, fontSize: 19, fontWeight: 700, paddingLeft: 10 }}>{titles[tab]}</div>
          <button style={{ background: 'none', border: 'none', color: CALM.dim, cursor: 'pointer', padding: 9, display: 'flex' }}><Icon name="search" size={20} /></button>
        </div>
        {body}
        <div style={{ flex: '0 0 auto', display: 'flex', background: CALM.head, borderTop: `1px solid ${CALM.div}`, padding: '6px 2px 9px' }}>
          {tabs.map(([k, icon, label]) => {
            const on = tab === k;
            return (
              <button key={k} onClick={() => setTab(k)} style={{ flex: 1, background: 'none', border: 'none', cursor: 'pointer', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, padding: '5px 0', color: on ? CALM.accent : CALM.faint }}>
                <span style={{ display: 'flex', padding: '2px 14px', borderRadius: 12, background: on ? CALM.accentDim : 'transparent' }}><Icon name={icon} size={20} stroke={on ? 2.1 : 1.8} /></span>
                <span style={{ fontSize: 10.5, fontWeight: on ? 700 : 500 }}>{label}</span>
              </button>
            );
          })}
        </div>
      </div>
    </PhoneFrame>
  );
}

function ComboC({ value }) { return <span style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 13.5, color: CALM.dim }}>{value}<Icon name="chevron" size={14} style={{ transform: 'rotate(90deg)' }} /></span>; }
function SliderC({ value, min, max, onChange }) {
  const ref = React.useRef(null);
  const pct = (value - min) / (max - min);
  const set = (x) => { const r = ref.current.getBoundingClientRect(); onChange(Math.round((Math.min(1, Math.max(0, (x - r.left) / r.width)) * (max - min) + min) / 10) * 10); };
  return (
    <div ref={ref} onPointerDown={e => { e.currentTarget.setPointerCapture(e.pointerId); set(e.clientX); }} onPointerMove={e => { if (e.buttons) set(e.clientX); }} style={{ height: 22, display: 'flex', alignItems: 'center', cursor: 'pointer', touchAction: 'none' }}>
      <div style={{ flex: 1, height: 5, borderRadius: 3, background: 'rgba(255,255,255,0.14)', position: 'relative' }}>
        <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: `${pct * 100}%`, background: CALM.accent, borderRadius: 3 }} />
        <div style={{ position: 'absolute', left: `calc(${pct * 100}% - 9px)`, top: -7, width: 18, height: 18, borderRadius: 9, background: '#fff', boxShadow: '0 1px 3px rgba(0,0,0,0.4)' }} />
      </div>
    </div>
  );
}

window.CalmApp = CalmApp;
