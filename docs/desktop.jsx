/* Desktop / convergent views — how stoandl looks on a Plasma or GNOME desktop.
   GNOME: AdwNavigationSplitView (sidebar + clamped boxed-list content).
   KDE:   Kirigami GlobalDrawer made persistent (modal:false) as a sidebar. */

// ── Desktop window chrome ──────────────────────────────────────────────
function DesktopWindow({ w = 900, h = 580, bg, children, controls = 'gnome', titlebar }) {
  return (
    <div style={{ width: w, height: h, background: bg, borderRadius: 12, overflow: 'hidden', boxShadow: '0 30px 80px rgba(0,0,0,0.45)', display: 'flex', flexDirection: 'column', position: 'relative' }}>
      {children}
      {controls === 'kde' && (
        <div style={{ position: 'absolute', top: 9, right: 10, display: 'flex', gap: 6, zIndex: 10 }}>
          {['menu', 'x'].map((_, i) => null)}
        </div>
      )}
    </div>
  );
}

// GNOME window controls: minimize + close, round, far right.
function GnomeControls() {
  const btn = { width: 26, height: 26, borderRadius: 13, border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(255,255,255,0.1)', color: 'rgba(255,255,255,0.7)' };
  return (
    <div style={{ display: 'flex', gap: 8 }}>
      <button style={btn}><svg width="10" height="10" viewBox="0 0 10 10"><rect x="1" y="4.5" width="8" height="1.4" rx="0.7" fill="currentColor" /></svg></button>
      <button style={btn}><svg width="10" height="10" viewBox="0 0 10 10"><path d="M2 2l6 6M8 2l-6 6" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" /></svg></button>
    </div>
  );
}
// KDE Breeze window controls: minimize, maximize, close.
function KdeControls() {
  const btn = (c) => ({ width: 22, height: 22, borderRadius: 11, border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(255,255,255,0.08)', color: c || 'rgba(255,255,255,0.6)' });
  return (
    <div style={{ display: 'flex', gap: 7 }}>
      <button style={btn()}><svg width="9" height="9" viewBox="0 0 10 10"><rect x="1" y="5" width="8" height="1.3" rx="0.6" fill="currentColor" /></svg></button>
      <button style={btn()}><svg width="9" height="9" viewBox="0 0 10 10"><rect x="1.5" y="1.5" width="7" height="7" rx="1" stroke="currentColor" strokeWidth="1.2" fill="none" /></svg></button>
      <button style={btn('#fff')} ><svg width="9" height="9" viewBox="0 0 10 10" style={{ }}><path d="M2 2l6 6M8 2l-6 6" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" /></svg></button>
    </div>
  );
}

/* ═══════════ GNOME desktop (libadwaita AdwNavigationSplitView) ═══════════ */
const GD = { win: '#242424', side: '#2b2b2b', view: '#1e1e1e', card: '#303030', head: '#2e2e2e', text: '#fff', dim: 'rgba(255,255,255,0.55)', faint: 'rgba(255,255,255,0.36)', div: 'rgba(255,255,255,0.08)', accent: '#3584e4', good: '#57e389', danger: '#f66151', font: '"Cantarell","Noto Sans",system-ui,sans-serif' };

function GBoxed({ children, style }) {
  return <div style={{ background: GD.card, borderRadius: 12, overflow: 'hidden', boxShadow: '0 1px 2px rgba(0,0,0,0.2)', ...style }}>
    {React.Children.map(children, (c, i) => <React.Fragment>{i > 0 && <div style={{ height: 1, background: GD.div, marginLeft: 16 }} />}{c}</React.Fragment>)}
  </div>;
}
function GRow({ icon, title, subtitle, trailing, danger, onClick, accentIcon }) {
  return (
    <div onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '12px 16px', cursor: onClick ? 'pointer' : 'default', color: danger ? GD.danger : GD.text }}>
      {icon && <span style={{ color: danger ? GD.danger : accentIcon ? GD.accent : GD.dim, display: 'flex', flex: '0 0 auto' }}><Icon name={icon} size={19} stroke={1.9} /></span>}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 14.5, fontWeight: 500 }}>{title}</div>
        {subtitle && <div style={{ fontSize: 12, color: GD.dim, marginTop: 2 }}>{subtitle}</div>}
      </div>
      {trailing}
    </div>
  );
}
function GSwitch({ on, onClick }) {
  return <button onClick={onClick} style={{ width: 44, height: 25, borderRadius: 13, border: 'none', cursor: 'pointer', flex: '0 0 auto', padding: 0, background: on ? GD.accent : 'rgba(255,255,255,0.16)', position: 'relative' }}>
    <span style={{ position: 'absolute', top: 3, left: on ? 22 : 3, width: 19, height: 19, borderRadius: 10, background: '#fff', transition: 'left .15s' }} />
  </button>;
}

function GnomeDesktop() {
  const S = window.STO;
  const [page, setPage] = React.useState('apps');
  const [sync, setSync] = React.useState(() => Object.fromEntries(S.sync.map(s => [s.id, s.on])));
  const nav = [['watch', 'watch', 'Watch'], ['apps', 'apps', 'Apps & Faces'], ['ext', 'puzzle', 'Extensions'], ['settings', 'sliders', 'Sync & Settings'], ['system', 'tools', 'System']];
  const titles = { watch: 'Watch', apps: 'Apps & Faces', ext: 'Extensions', settings: 'Sync & Settings', system: 'System' };

  let content;
  if (page === 'apps') {
    content = <>
      <div style={{ fontSize: 13, fontWeight: 700, color: GD.dim, padding: '0 2px 8px' }}>Watchfaces</div>
      <GBoxed style={{ marginBottom: 24 }}>
        {S.faces.map(f => <GRow key={f.uuid} icon={f.flags.includes('active') ? 'star' : 'watch'} accentIcon={f.flags.includes('active')} title={f.name} subtitle={f.uuid}
          trailing={<div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>{f.flags.map(x => <DBadge key={x} tone={x} c={GD} />)}<Icon name="kebab" size={17} style={{ color: GD.faint }} /></div>} />)}
        <GRow icon="plus" accentIcon title="Install watchface…" onClick={() => {}} />
      </GBoxed>
      <div style={{ fontSize: 13, fontWeight: 700, color: GD.dim, padding: '0 2px 8px' }}>Apps</div>
      <GBoxed>
        {S.apps.map(a => <GRow key={a.uuid} icon="apps" title={a.name} subtitle={a.uuid}
          trailing={<div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>{a.flags.map(x => <DBadge key={x} tone={x} c={GD} />)}<Icon name="kebab" size={17} style={{ color: GD.faint }} /></div>} />)}
        <GRow icon="plus" accentIcon title="Install app…" onClick={() => {}} />
      </GBoxed>
    </>;
  } else if (page === 'settings') {
    content = <>
      <div style={{ fontSize: 13, fontWeight: 700, color: GD.dim, padding: '0 2px 8px' }}>Sync</div>
      <GBoxed>{S.sync.map(s => <GRow key={s.id} icon={syncIcon(s.id)} title={s.name} subtitle={s.desc} trailing={<GSwitch on={sync[s.id]} onClick={() => setSync(p => ({ ...p, [s.id]: !p[s.id] }))} />} />)}</GBoxed>
    </>;
  } else if (page === 'watch') {
    content = <>
      <GBoxed style={{ marginBottom: 24 }}>
        <div style={{ padding: 18, display: 'flex', alignItems: 'center', gap: 16 }}>
          <WatchGlyph size={58} accent={GD.accent} />
          <div style={{ flex: 1 }}><div style={{ fontSize: 18, fontWeight: 700 }}>{S.watch.name}</div><div style={{ fontSize: 13, color: GD.dim, marginTop: 2 }}>{S.watch.model} · {S.watch.platform}</div>
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, marginTop: 8 }}><span style={{ width: 7, height: 7, borderRadius: 4, background: GD.good }} /><span style={{ fontSize: 12.5, color: GD.good, fontWeight: 600 }}>Connected · {S.watch.transport}</span></div>
          </div>
          <div style={{ textAlign: 'center' }}><BatteryGlyph level={S.watch.battery} size={32} color={GD.dim} /><div style={{ fontSize: 14, fontWeight: 700, marginTop: 4 }}>{S.watch.battery}%</div></div>
        </div>
      </GBoxed>
      <div style={{ fontSize: 13, fontWeight: 700, color: GD.dim, padding: '0 2px 8px' }}>Known watches</div>
      <GBoxed>{S.knownWatches.map(w => <GRow key={w.code} icon="watch" title={`${w.name} · ${w.code}`} subtitle={`${w.model} · ${w.transport}`} trailing={w.connected ? <span style={{ fontSize: 12.5, fontWeight: 700, color: GD.good }}>active</span> : <button style={dbtn(GD)}>Connect</button>} />)}</GBoxed>
    </>;
  } else if (page === 'ext') {
    content = <GBoxed>{S.extensions.map(e => <GRow key={e.name} icon="puzzle" title={e.name} subtitle={e.desc} trailing={<GSwitch on={e.enabled} onClick={() => {}} />} />)}</GBoxed>;
  } else {
    content = <>
      <GBoxed style={{ marginBottom: 24 }}>
        <GRow icon="download" accentIcon title="Firmware update available" subtitle={`${S.firmware.current} → ${S.firmware.latest} · ${S.firmware.channel}`} trailing={<button style={dbtn(GD, true)}>Flash</button>} />
      </GBoxed>
      <GBoxed><GRow icon="globe" title="Language pack" subtitle={S.language.current} /><GRow icon="archive" title="Backup & restore" subtitle={`${S.backup.last} · ${S.backup.size}`} /></GBoxed>
    </>;
  }

  return (
    <DesktopWindow bg={GD.win}>
      <div style={{ display: 'flex', height: '100%', fontFamily: GD.font, color: GD.text }}>
        {/* Sidebar */}
        <div style={{ width: 232, flex: '0 0 232px', background: GD.side, display: 'flex', flexDirection: 'column', borderRight: `1px solid ${GD.div}` }}>
          <div style={{ height: 47, flex: '0 0 47px', display: 'flex', alignItems: 'center', padding: '0 14px', borderBottom: `1px solid ${GD.div}` }}>
            <button style={{ background: 'none', border: 'none', color: GD.text, display: 'flex', cursor: 'pointer', padding: 6 }}><Icon name="menu" size={20} /></button>
            <span style={{ fontSize: 15, fontWeight: 700, marginLeft: 6 }}>stoandl</span>
          </div>
          <div style={{ padding: 8, flex: 1 }}>
            {nav.map(([k, icon, label]) => (
              <div key={k} onClick={() => setPage(k)} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 12px', borderRadius: 9, cursor: 'pointer', marginBottom: 2, background: page === k ? GD.accent : 'transparent', color: '#fff' }}>
                <Icon name={icon} size={19} stroke={1.9} style={{ opacity: page === k ? 1 : 0.7 }} />
                <span style={{ fontSize: 14.5, fontWeight: page === k ? 600 : 500 }}>{label}</span>
              </div>
            ))}
          </div>
          <div style={{ padding: '10px 16px', fontSize: 11.5, color: GD.faint, borderTop: `1px solid ${GD.div}`, display: 'flex', alignItems: 'center', gap: 7 }}>
            <span style={{ width: 7, height: 7, borderRadius: 4, background: GD.good }} />daemon running · 0.8.0
          </div>
        </div>
        {/* Content pane */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, background: GD.win }}>
          <div style={{ height: 47, flex: '0 0 47px', background: GD.head, display: 'flex', alignItems: 'center', padding: '0 14px', borderBottom: `1px solid ${GD.div}` }}>
            <span style={{ flex: 1, fontSize: 15, fontWeight: 700 }}>{titles[page]}</span>
            <button style={{ background: 'none', border: 'none', color: GD.text, display: 'flex', cursor: 'pointer', padding: 7, marginRight: 4 }}><Icon name="search" size={19} /></button>
            <GnomeControls />
          </div>
          <div style={{ flex: 1, overflowY: 'auto', padding: '28px 0' }}>
            {/* AdwClamp: constrain content width and center it */}
            <div style={{ maxWidth: 560, margin: '0 auto', padding: '0 24px' }}>{content}</div>
          </div>
        </div>
      </div>
    </DesktopWindow>
  );
}

/* ═══════════ KDE desktop (persistent GlobalDrawer sidebar) ═══════════ */
function KdeDesktop() {
  const S = window.STO;
  const B = window.BRZ;
  const [page, setPage] = React.useState('apps');
  const [sync, setSync] = React.useState(() => Object.fromEntries(S.sync.map(s => [s.id, s.on])));
  const FormCard = window.FormCard, FormDelegate = window.FormDelegate, FormHeader = window.FormHeader, BChip = window.BChip, BSwitch = window.BSwitch;
  const nav = [['watch', 'watch', 'Watch'], ['apps', 'apps', 'Apps & Faces'], ['ext', 'puzzle', 'Extensions'], ['settings', 'sliders', 'Sync & Settings'], ['system', 'tools', 'System']];
  const titles = { watch: 'Watch', apps: 'Apps & Faces', ext: 'Extensions', settings: 'Sync & Settings', system: 'System' };

  let content;
  if (page === 'apps') {
    content = <div style={{ maxWidth: 640, margin: '0 auto' }}>
      <FormHeader>WATCHFACES</FormHeader>
      <FormCard style={{ marginBottom: 20 }}>
        {S.faces.map(f => <FormDelegate key={f.uuid} icon={f.flags.includes('active') ? 'star' : 'watch'} iconTone={f.flags.includes('active') ? B.accent : B.dim} title={f.name} subtitle={f.uuid}
          trailing={<div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>{f.flags.map(x => <BChip key={x} tone={x}>{x}</BChip>)}<Icon name="kebab" size={17} style={{ color: B.faint }} /></div>} />)}
      </FormCard>
      <FormHeader>APPS</FormHeader>
      <FormCard>
        {S.apps.map(a => <FormDelegate key={a.uuid} icon="apps" iconTone={B.dim} title={a.name} subtitle={a.uuid}
          trailing={<div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>{a.flags.map(x => <BChip key={x} tone={x}>{x}</BChip>)}<Icon name="kebab" size={17} style={{ color: B.faint }} /></div>} />)}
      </FormCard>
    </div>;
  } else if (page === 'settings') {
    content = <div style={{ maxWidth: 640, margin: '0 auto' }}><FormHeader>SYNC SERVICES</FormHeader><FormCard>{S.sync.map(s => <FormDelegate key={s.id} icon={syncIcon(s.id)} title={s.name} subtitle={s.desc} trailing={<BSwitch on={sync[s.id]} onClick={() => setSync(p => ({ ...p, [s.id]: !p[s.id] }))} />} />)}</FormCard></div>;
  } else if (page === 'watch') {
    content = <div style={{ maxWidth: 640, margin: '0 auto' }}>
      <FormCard style={{ marginBottom: 20 }}><div style={{ padding: 18, display: 'flex', alignItems: 'center', gap: 16 }}>
        <WatchGlyph size={58} accent={B.accent} />
        <div style={{ flex: 1 }}><div style={{ fontSize: 18, fontWeight: 700 }}>{S.watch.name}</div><div style={{ fontSize: 13, color: B.dim, marginTop: 2 }}>{S.watch.model} · {S.watch.platform}</div>
          <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, marginTop: 8 }}><span style={{ width: 7, height: 7, borderRadius: 4, background: B.good }} /><span style={{ fontSize: 12.5, color: B.good, fontWeight: 700 }}>Connected · {S.watch.transport}</span></div></div>
        <div style={{ textAlign: 'center' }}><BatteryGlyph level={S.watch.battery} size={32} color={B.dim} /><div style={{ fontSize: 14, fontWeight: 700, marginTop: 4 }}>{S.watch.battery}%</div></div>
      </div></FormCard>
      <FormHeader>KNOWN WATCHES</FormHeader>
      <FormCard>{S.knownWatches.map(w => <FormDelegate key={w.code} icon="watch" iconTone={w.connected ? B.good : B.dim} title={`${w.name} · ${w.code}`} subtitle={`${w.model} · ${w.transport}`} trailing={w.connected ? <BChip tone="active">active</BChip> : <button style={window.btnB()}>Connect</button>} />)}</FormCard>
    </div>;
  } else if (page === 'ext') {
    content = <div style={{ maxWidth: 640, margin: '0 auto' }}><FormHeader>COMPANION APPS</FormHeader><FormCard>{S.extensions.map(e => <FormDelegate key={e.name} icon="puzzle" iconTone={e.enabled ? B.purple : B.dim} title={e.name} subtitle={e.desc} trailing={<BSwitch on={e.enabled} onClick={() => {}} />} />)}</FormCard></div>;
  } else {
    content = <div style={{ maxWidth: 640, margin: '0 auto' }}>
      <FormCard style={{ marginBottom: 20, borderColor: 'rgba(246,116,0,0.4)' }}><FormDelegate icon="download" iconTone={B.warn} title="Firmware update available" subtitle={`${S.firmware.current} → ${S.firmware.latest} · ${S.firmware.channel}`} trailing={<button style={window.btnB('solid', B.warn)}>Flash</button>} /></FormCard>
      <FormHeader>SYSTEM</FormHeader>
      <FormCard><FormDelegate icon="globe" title="Language pack" subtitle={S.language.current} /><FormDelegate icon="archive" title="Backup & restore" subtitle={`${S.backup.last} · ${S.backup.size}`} /></FormCard>
    </div>;
  }

  return (
    <DesktopWindow bg={B.win} controls="kde">
      <div style={{ display: 'flex', flexDirection: 'column', height: '100%', fontFamily: B.font, color: B.text }}>
        {/* Breeze titlebar */}
        <div style={{ height: 38, flex: '0 0 38px', background: B.head, display: 'flex', alignItems: 'center', padding: '0 12px', borderBottom: `1px solid ${B.div}` }}>
          <span style={{ flex: 1, textAlign: 'center', fontSize: 13, fontWeight: 600, color: B.dim }}>stoandl — Pebble Manager</span>
          <KdeControls />
        </div>
        <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
          {/* Persistent GlobalDrawer (modal:false) */}
          <div style={{ width: 240, flex: '0 0 240px', background: B.view, borderRight: `1px solid ${B.div}`, display: 'flex', flexDirection: 'column' }}>
            <div style={{ padding: '16px 14px', borderBottom: `1px solid ${B.div}`, display: 'flex', alignItems: 'center', gap: 12 }}>
              <WatchGlyph size={36} accent={B.accent} />
              <div><div style={{ fontSize: 14.5, fontWeight: 700 }}>{S.watch.name}</div><div style={{ fontSize: 11.5, color: B.good, fontWeight: 600, marginTop: 2 }}>● Connected</div></div>
            </div>
            <div style={{ padding: 8, flex: 1 }}>
              {nav.map(([k, icon, label]) => (
                <div key={k} onClick={() => setPage(k)} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 12px', borderRadius: 6, cursor: 'pointer', marginBottom: 2, background: page === k ? B.accentDim : 'transparent', color: page === k ? B.accent : B.text }}>
                  <Icon name={icon} size={19} stroke={1.9} /><span style={{ fontSize: 14, fontWeight: page === k ? 700 : 500 }}>{label}</span>
                </div>
              ))}
            </div>
            <div style={{ padding: '10px 14px', borderTop: `1px solid ${B.div}`, fontSize: 11.5, color: B.faint }}>daemon running · 0.8.0</div>
          </div>
          {/* Main page */}
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
            <div style={{ height: 46, flex: '0 0 46px', background: B.win, display: 'flex', alignItems: 'center', padding: '0 16px', borderBottom: `1px solid ${B.div}` }}>
              <span style={{ flex: 1, fontSize: 16, fontWeight: 700 }}>{titles[page]}</span>
              <button style={{ ...window.btnB('solid'), padding: '7px 13px' }}><Icon name="plus" size={15} stroke={2.4} />Install</button>
            </div>
            <div style={{ flex: 1, overflowY: 'auto', padding: 24, background: B.win }}>{content}</div>
          </div>
        </div>
      </div>
    </DesktopWindow>
  );
}

// shared desktop helpers
function DBadge({ tone, c }) {
  const map = { active: c.accent, system: 'rgba(255,255,255,0.16)', config: '#c061cb', sideloaded: '#e9a64b' };
  const col = map[tone] || 'rgba(255,255,255,0.16)';
  const solid = tone === 'active';
  return <span style={{ fontSize: 10, fontWeight: 700, padding: '2px 6px', borderRadius: 5, background: solid ? col : 'transparent', color: solid ? '#fff' : col, border: solid ? 'none' : `1px solid ${col}` }}>{tone}</span>;
}
function dbtn(c, solid) { return { display: 'inline-flex', alignItems: 'center', background: solid ? c.accent : 'transparent', color: solid ? '#fff' : c.accent, border: solid ? 'none' : `1px solid ${c.accent}`, borderRadius: 7, padding: '5px 12px', fontSize: 12.5, fontWeight: 600, cursor: 'pointer', fontFamily: c.font }; }

Object.assign(window, { GnomeDesktop, KdeDesktop });
