/* Direction A — "Phosh" · libadwaita / GNOME mobile.
   Header bar + drill-in navigation, boxed preference lists, Adwaita switches. */

const ADW = {
  win: '#242424', view: '#303030', head: '#2e2e2e', row: '#383838',
  text: '#ffffff', dim: 'rgba(255,255,255,0.55)', faint: 'rgba(255,255,255,0.38)',
  div: 'rgba(255,255,255,0.08)', accent: '#3584e4', danger: '#f66151', good: '#57e389',
  font: '"Cantarell","Noto Sans",system-ui,sans-serif',
};

function AdwSwitch({ on, onClick }) {
  return (
    <button onClick={onClick} style={{
      width: 46, height: 26, borderRadius: 13, border: 'none', cursor: 'pointer', flex: '0 0 auto',
      background: on ? ADW.accent : 'rgba(255,255,255,0.16)', position: 'relative', transition: 'background .18s', padding: 0,
    }}>
      <span style={{
        position: 'absolute', top: 3, left: on ? 23 : 3, width: 20, height: 20, borderRadius: 10,
        background: '#fff', transition: 'left .18s', boxShadow: '0 1px 2px rgba(0,0,0,0.3)',
      }} />
    </button>
  );
}

function AdwGroup({ title, action, children }) {
  return (
    <div style={{ marginBottom: 20 }}>
      {(title || action) && (
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 4px 8px' }}>
          {title && <div style={{ fontSize: 13, fontWeight: 700, color: ADW.dim, letterSpacing: 0.3 }}>{title}</div>}
          {action}
        </div>
      )}
      <div style={{ background: ADW.view, borderRadius: 13, overflow: 'hidden', boxShadow: '0 1px 2px rgba(0,0,0,0.18)' }}>
        {React.Children.map(children, (c, i) => (
          <React.Fragment>
            {i > 0 && <div style={{ height: 1, background: ADW.div, marginLeft: 16 }} />}
            {c}
          </React.Fragment>
        ))}
      </div>
    </div>
  );
}

function AdwRow({ icon, title, subtitle, trailing, onClick, chevron, danger, accentIcon }) {
  return (
    <div onClick={onClick} style={{
      display: 'flex', alignItems: 'center', gap: 13, padding: '12px 16px', cursor: onClick ? 'pointer' : 'default',
      color: danger ? ADW.danger : ADW.text,
    }}>
      {icon && (
        <span style={{ color: danger ? ADW.danger : accentIcon ? ADW.accent : ADW.dim, flex: '0 0 auto', display: 'flex' }}>
          <Icon name={icon} size={20} stroke={1.9} />
        </span>
      )}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 15, fontWeight: 500, lineHeight: 1.25, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</div>
        {subtitle && <div style={{ fontSize: 12.5, color: ADW.dim, marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{subtitle}</div>}
      </div>
      {trailing}
      {chevron && <Icon name="chevron" size={17} stroke={2} style={{ color: ADW.faint, flex: '0 0 auto' }} />}
    </div>
  );
}

function AdwBadge({ children, tone }) {
  const map = { active: ADW.accent, system: 'rgba(255,255,255,0.16)', config: '#c061cb', sideloaded: '#e9a64b' };
  const bg = map[tone] || 'rgba(255,255,255,0.16)';
  const solid = tone === 'active';
  return (
    <span style={{
      fontSize: 10.5, fontWeight: 700, letterSpacing: 0.3, padding: '2px 7px', borderRadius: 6, textTransform: 'lowercase',
      background: solid ? bg : 'transparent', color: solid ? '#fff' : bg, border: solid ? 'none' : `1px solid ${bg}`,
    }}>{children}</span>
  );
}

function PhoshApp() {
  const S = window.STO;
  const [page, setPage] = React.useState('home');
  const [sync, setSync] = React.useState(() => Object.fromEntries(S.sync.map(s => [s.id, s.on])));
  const [ext, setExt] = React.useState(() => Object.fromEntries(S.extensions.map(e => [e.name, e.enabled])));
  const [ws, setWs] = React.useState(S.watchSettings);

  const titles = { home: 'stoandl', watch: 'Watch', apps: 'Apps & Faces', ext: 'Extensions', settings: 'Sync & Settings', system: 'System' };

  const scroll = (children) => (
    <div style={{ flex: 1, overflowY: 'auto', padding: '16px 14px 28px' }}>{children}</div>
  );

  let body;
  if (page === 'home') {
    body = scroll(<>
      <div onClick={() => setPage('watch')} style={{
        background: `linear-gradient(135deg,${ADW.view},#2a2a2a)`, borderRadius: 15, padding: '16px 16px',
        display: 'flex', alignItems: 'center', gap: 14, marginBottom: 22, cursor: 'pointer',
        boxShadow: '0 2px 6px rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.05)',
      }}>
        <WatchGlyph size={50} accent={ADW.accent} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 17, fontWeight: 700 }}>{S.watch.name}</div>
          <div style={{ fontSize: 12.5, color: ADW.dim, marginTop: 2 }}>{S.watch.model}</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 8 }}>
            <span style={{ width: 7, height: 7, borderRadius: 4, background: ADW.good }} />
            <span style={{ fontSize: 12, color: ADW.good, fontWeight: 600 }}>Connected</span>
            <span style={{ fontSize: 12, color: ADW.dim }}>· {S.watch.transport}</span>
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
          <BatteryGlyph level={S.watch.battery} size={28} color={ADW.dim} />
          <span style={{ fontSize: 13, fontWeight: 700 }}>{S.watch.battery}%</span>
        </div>
      </div>
      <AdwGroup>
        <AdwRow icon="watch" title="Watch" subtitle="Pairing, battery, firmware" chevron onClick={() => setPage('watch')} />
        <AdwRow icon="apps" title="Apps & Faces" subtitle={`${S.faces.length} faces · ${S.apps.length} apps`} chevron onClick={() => setPage('apps')} />
        <AdwRow icon="puzzle" title="Extensions" subtitle="Matrix, Find My Phone, +2" chevron onClick={() => setPage('ext')} />
        <AdwRow icon="sliders" title="Sync & Settings" subtitle="Notifications, weather, calendar…" chevron onClick={() => setPage('settings')} />
        <AdwRow icon="tools" title="System" subtitle="Firmware, language, backup" chevron onClick={() => setPage('system')} />
      </AdwGroup>
      <div style={{ textAlign: 'center', fontSize: 11.5, color: ADW.faint, marginTop: 6 }}>daemon running · stoandl 0.8.0</div>
    </>);
  } else if (page === 'watch') {
    body = scroll(<>
      <AdwGroup title="Active watch">
        <AdwRow icon="info" title={S.watch.model} subtitle={`Platform ${S.watch.platform}`} />
        <AdwRow icon="bluetooth" title="Transport" subtitle={S.watch.transport} accentIcon />
        <AdwRow icon="battery" title="Battery" trailing={<span style={{ fontSize: 14, fontWeight: 600, color: ADW.good }}>{S.watch.battery}%</span>} />
        <AdwRow icon="sync" title="Last sync" trailing={<span style={{ fontSize: 13, color: ADW.dim }}>{S.watch.lastSync}</span>} />
      </AdwGroup>
      <AdwGroup title="Known watches" action={<button style={btnA(ADW.accent)}><Icon name="plus" size={14} stroke={2.6} />Pair</button>}>
        {S.knownWatches.map(w => (
          <AdwRow key={w.code} icon="watch" title={`${w.name} · ${w.code}`} subtitle={`${w.model} · ${w.transport}`}
            trailing={w.connected
              ? <span style={{ fontSize: 12.5, fontWeight: 700, color: ADW.good }}>active</span>
              : <button style={btnA('transparent', ADW.accent)}>Connect</button>} />
        ))}
      </AdwGroup>
      <AdwGroup title="Actions">
        <AdwRow icon="camera" title="Capture screenshot" subtitle="Save watch screen to PNG" chevron />
        <AdwRow icon="link" title="Re-pair watch" subtitle="Forget and pair again" chevron />
      </AdwGroup>
    </>);
  } else if (page === 'apps') {
    body = scroll(<>
      <AdwGroup title="Watchfaces" action={<button style={btnA(ADW.accent)}><Icon name="plus" size={14} stroke={2.6} />Install</button>}>
        {S.faces.map(f => <LockerRowAdw key={f.uuid} item={f} />)}
      </AdwGroup>
      <AdwGroup title="Apps">
        {S.apps.map(a => <LockerRowAdw key={a.uuid} item={a} />)}
      </AdwGroup>
    </>);
  } else if (page === 'ext') {
    body = scroll(<>
      <AdwGroup title="Companion apps" action={<button style={btnA(ADW.accent)}><Icon name="plus" size={14} stroke={2.6} />Add</button>}>
        {S.extensions.map(e => (
          <AdwRow key={e.name} icon="puzzle" title={e.name} subtitle={e.desc}
            trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              {ext[e.name] && <span style={{ width: 7, height: 7, borderRadius: 4, background: ADW.good }} />}
              <AdwSwitch on={ext[e.name]} onClick={() => setExt(p => ({ ...p, [e.name]: !p[e.name] }))} />
            </div>} />
        ))}
      </AdwGroup>
      <div style={{ fontSize: 12, color: ADW.faint, padding: '0 6px', lineHeight: 1.5 }}>
        Extensions are small host-side programs that drive watch notifications with replies & actions — in any language.
      </div>
    </>);
  } else if (page === 'settings') {
    body = scroll(<>
      <AdwGroup title="Sync">
        {S.sync.map(s => (
          <AdwRow key={s.id} icon={syncIcon(s.id)} title={s.name} subtitle={s.desc}
            trailing={<AdwSwitch on={sync[s.id]} onClick={() => setSync(p => ({ ...p, [s.id]: !p[s.id] }))} />} />
        ))}
      </AdwGroup>
      <AdwGroup title="Watch settings">
        <AdwRow icon="power" title="Quick launch · Up" trailing={<ComboA value={ws.quickLaunchUp} />} />
        <AdwRow icon="power" title="Quick launch · Down" trailing={<ComboA value={ws.quickLaunchDown} />} />
        <AdwRow icon="sun" title="Backlight" subtitle={`Timeout ${ws.backlightTimeout}s`}
          trailing={<AdwSwitch on={ws.backlight} onClick={() => setWs(p => ({ ...p, backlight: !p.backlight }))} />} />
        <AdwRow icon="sun" title="Motion backlight" subtitle="Wake on wrist flick"
          trailing={<AdwSwitch on={ws.motionBacklight} onClick={() => setWs(p => ({ ...p, motionBacklight: !p.motionBacklight }))} />} />
      </AdwGroup>
      <AdwGroup title="Ambient light threshold">
        <div style={{ padding: '14px 16px' }}>
          <SliderA value={ws.ambientThreshold} min={0} max={400} onChange={v => setWs(p => ({ ...p, ambientThreshold: v }))} accent={ADW.accent} />
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, color: ADW.faint, marginTop: 7 }}>
            <span>Dark</span><span style={{ color: ADW.text, fontWeight: 600 }}>{ws.ambientThreshold} lx</span><span>Bright</span>
          </div>
        </div>
      </AdwGroup>
    </>);
  } else {
    body = scroll(<>
      <AdwGroup title="Firmware">
        {S.firmware.updateAvailable ? (
          <div style={{ padding: '14px 16px' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <span style={{ color: ADW.accent, display: 'flex' }}><Icon name="download" size={20} /></span>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 15, fontWeight: 600 }}>Update available</div>
                <div style={{ fontSize: 12.5, color: ADW.dim, marginTop: 2 }}>{S.firmware.current} → {S.firmware.latest} · {S.firmware.channel}</div>
              </div>
            </div>
            <button style={{ ...btnA(ADW.accent), width: '100%', justifyContent: 'center', marginTop: 12, padding: '10px 0', fontSize: 14 }}>Flash {S.firmware.latest}</button>
          </div>
        ) : <AdwRow icon="check" title="Firmware up to date" subtitle={S.firmware.current} />}
      </AdwGroup>
      <AdwGroup title="System">
        <AdwRow icon="globe" title="Language pack" subtitle={S.language.current} chevron />
        <AdwRow icon="archive" title="Backup & restore" subtitle={`Last: ${S.backup.last} · ${S.backup.size}`} chevron />
      </AdwGroup>
      <AdwGroup title="Diagnostics">
        <AdwRow icon="camera" title="Screenshot" chevron />
        <AdwRow icon="file" title="Pull watch logs" chevron />
        <AdwRow icon="archive" title="Support bundle" subtitle="Redacted .tar.gz for bug reports" chevron />
      </AdwGroup>
      <AdwGroup title="Danger zone">
        <AdwRow icon="refresh" title="Reboot to recovery (PRF)" danger chevron />
        <AdwRow icon="alert" title="Factory reset" subtitle="Irreversible · wipes the watch" danger chevron />
      </AdwGroup>
    </>);
  }

  return (
    <PhoneFrame bg={ADW.win}>
      <div style={{ display: 'flex', flexDirection: 'column', height: '100%', fontFamily: ADW.font, color: ADW.text }}>
        <StatusBar />
        <div style={{
          height: 50, flex: '0 0 50px', background: ADW.head, display: 'flex', alignItems: 'center', padding: '0 8px',
          boxShadow: '0 1px 0 rgba(0,0,0,0.4)', position: 'relative', zIndex: 2,
        }}>
          {page !== 'home'
            ? <button onClick={() => setPage('home')} style={{ background: 'none', border: 'none', color: ADW.text, cursor: 'pointer', padding: 8, display: 'flex' }}><Icon name="back" size={22} /></button>
            : <button style={{ background: 'none', border: 'none', color: ADW.text, cursor: 'pointer', padding: 8, display: 'flex' }}><Icon name="menu" size={22} /></button>}
          <div style={{ flex: 1, textAlign: 'center', fontSize: 16, fontWeight: 700, letterSpacing: 0.2 }}>{titles[page]}</div>
          <button style={{ background: 'none', border: 'none', color: ADW.text, cursor: 'pointer', padding: 8, display: 'flex' }}>
            <Icon name={page === 'home' ? 'search' : 'kebab'} size={20} />
          </button>
        </div>
        {body}
      </div>
    </PhoneFrame>
  );
}

function LockerRowAdw({ item }) {
  const isFace = true;
  return (
    <AdwRow icon={item.flags.includes('active') ? 'star' : 'apps'} accentIcon={item.flags.includes('active')}
      title={item.name}
      subtitle={item.uuid}
      trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        {item.flags.map(f => <AdwBadge key={f} tone={f}>{f}</AdwBadge>)}
        <Icon name="kebab" size={18} style={{ color: ADW.faint }} />
      </div>} />
  );
}

function ComboA({ value }) {
  return <span style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 13.5, color: ADW.dim }}>{value}<Icon name="chevron" size={15} style={{ transform: 'rotate(90deg)' }} /></span>;
}

function SliderA({ value, min, max, onChange, accent }) {
  const ref = React.useRef(null);
  const pct = (value - min) / (max - min);
  const set = (clientX) => {
    const r = ref.current.getBoundingClientRect();
    onChange(Math.round((Math.min(1, Math.max(0, (clientX - r.left) / r.width)) * (max - min) + min) / 10) * 10);
  };
  return (
    <div ref={ref} onPointerDown={e => { e.currentTarget.setPointerCapture(e.pointerId); set(e.clientX); }}
      onPointerMove={e => { if (e.buttons) set(e.clientX); }}
      style={{ height: 22, display: 'flex', alignItems: 'center', cursor: 'pointer', touchAction: 'none' }}>
      <div style={{ flex: 1, height: 5, borderRadius: 3, background: 'rgba(255,255,255,0.15)', position: 'relative' }}>
        <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: `${pct * 100}%`, background: accent, borderRadius: 3 }} />
        <div style={{ position: 'absolute', left: `calc(${pct * 100}% - 9px)`, top: -7, width: 18, height: 18, borderRadius: 9, background: '#fff', boxShadow: '0 1px 3px rgba(0,0,0,0.4)' }} />
      </div>
    </div>
  );
}

function btnA(bg, fg) {
  return {
    display: 'inline-flex', alignItems: 'center', gap: 5, background: bg, color: fg || '#fff',
    border: bg === 'transparent' ? `1px solid ${fg || ADW.accent}` : 'none', borderRadius: 8, padding: '6px 12px',
    fontSize: 13, fontWeight: 600, cursor: 'pointer', fontFamily: ADW.font,
  };
}

window.PhoshApp = PhoshApp;
