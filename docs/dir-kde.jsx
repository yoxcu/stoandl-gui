/* KDE · Plasma Mobile — Kirigami, by the book.
   Per KDE HIG: ≤5 destinations → Kirigami.NavigationTabBar (bottom).
   FormCard delegates, page header toolbar, floating action button,
   passive (non-invasive) notification toast. Breeze Dark palette.
   Includes worked interaction STATES (pixel targets for the QML build):
   pairing dialog, firmware-flash progress, language-install progress,
   factory-reset typed-confirm, extension uninstall (keep-config),
   and row action sheets (launch/configure/remove · repair/unpair). */

const BRZ = {
  win: '#2a2e32', view: '#1f2226', card: '#26292e', head: '#31363b',
  text: '#fcfcfc', dim: '#a7adba', faint: 'rgba(255,255,255,0.30)',
  div: 'rgba(255,255,255,0.08)', accent: '#3daee9', accentDim: 'rgba(61,174,233,0.16)',
  good: '#27ae60', danger: '#da4453', warn: '#f67400', purple: '#9b59b6',
  font: '"Noto Sans","Segoe UI",system-ui,sans-serif',
};

if (typeof document !== 'undefined' && !document.getElementById('kde-anim')) {
  const s = document.createElement('style'); s.id = 'kde-anim';
  s.textContent = '@keyframes kspin{to{transform:rotate(360deg)}}@keyframes ksheet{from{transform:translateY(100%)}to{transform:translateY(0)}}@keyframes kfade{from{opacity:0}to{opacity:1}}@keyframes kbar{0%{left:-40%}100%{left:100%}}';
  document.head.appendChild(s);
}

function BSwitch({ on, onClick }) {
  return (
    <button onClick={onClick} style={{ width: 44, height: 24, borderRadius: 4, border: 'none', cursor: 'pointer', flex: '0 0 auto', padding: 0, background: on ? BRZ.accent : 'rgba(255,255,255,0.16)', position: 'relative', transition: 'background .16s' }}>
      <span style={{ position: 'absolute', top: 3, left: on ? 23 : 3, width: 18, height: 18, borderRadius: 3, background: '#fff', transition: 'left .16s', boxShadow: '0 1px 2px rgba(0,0,0,0.4)' }} />
    </button>
  );
}

function FormCard({ children, style }) {
  return (
    <div style={{ background: BRZ.card, borderRadius: 8, border: `1px solid ${BRZ.div}`, overflow: 'hidden', ...style }}>
      {React.Children.map(children, (c, i) => c && (
        <React.Fragment>
          {i > 0 && <div style={{ height: 1, background: BRZ.div, marginLeft: 14 }} />}
          {c}
        </React.Fragment>
      ))}
    </div>
  );
}
function FormHeader({ children }) {
  return <div style={{ fontSize: 12.5, fontWeight: 700, color: BRZ.accent, letterSpacing: 0.3, padding: '0 4px 7px' }}>{children}</div>;
}
function FormDelegate({ icon, iconTone, title, subtitle, trailing, onClick, danger }) {
  const tone = danger ? BRZ.danger : (iconTone || BRZ.accent);
  return (
    <div onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '12px 14px', cursor: onClick ? 'pointer' : 'default' }}>
      {icon && <span style={{ width: 32, height: 32, borderRadius: 6, flex: '0 0 auto', display: 'flex', alignItems: 'center', justifyContent: 'center', background: danger ? 'rgba(218,68,83,0.16)' : BRZ.accentDim, color: tone }}><Icon name={icon} size={18} stroke={1.9} /></span>}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 14.5, fontWeight: 500, color: danger ? BRZ.danger : BRZ.text, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</div>
        {subtitle && <div style={{ fontSize: 12, color: BRZ.dim, marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{subtitle}</div>}
      </div>
      {trailing}
    </div>
  );
}

function BChip({ children, tone }) {
  const map = { active: BRZ.accent, system: 'rgba(255,255,255,0.16)', config: BRZ.purple, sideloaded: BRZ.warn };
  const c = map[tone] || 'rgba(255,255,255,0.16)';
  const solid = tone === 'active';
  return <span style={{ fontSize: 10, fontWeight: 700, padding: '2px 6px', borderRadius: 4, background: solid ? c : 'transparent', color: solid ? '#06151d' : c, border: solid ? 'none' : `1px solid ${c}` }}>{children}</span>;
}

function Spinner({ size = 22, stroke = 3, color = BRZ.accent }) {
  return <span style={{ width: size, height: size, borderRadius: '50%', border: `${stroke}px solid rgba(255,255,255,0.15)`, borderTopColor: color, display: 'inline-block', animation: 'kspin .8s linear infinite' }} />;
}
function Bar({ pct, indeterminate, color = BRZ.accent }) {
  return (
    <div style={{ height: 6, borderRadius: 3, background: 'rgba(255,255,255,0.13)', position: 'relative', overflow: 'hidden' }}>
      {indeterminate
        ? <div style={{ position: 'absolute', top: 0, bottom: 0, width: '40%', borderRadius: 3, background: color, animation: 'kbar 1.1s ease-in-out infinite' }} />
        : <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: `${pct}%`, background: color, borderRadius: 3, transition: 'width .25s' }} />}
    </div>
  );
}

// Breeze-style centered dialog (Kirigami.PromptDialog).
function Modal({ onClose, children }) {
  return (
    <div onClick={onClose} style={{ position: 'absolute', inset: 0, zIndex: 30, background: 'rgba(0,0,0,0.55)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 18, animation: 'kfade .15s ease' }}>
      <div onClick={e => e.stopPropagation()} style={{ width: '100%', maxWidth: 282, background: BRZ.card, borderRadius: 10, border: `1px solid ${BRZ.div}`, boxShadow: '0 16px 50px rgba(0,0,0,0.6)', overflow: 'hidden' }}>{children}</div>
    </div>
  );
}
function DlgFoot({ children }) {
  return <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, padding: '12px 14px', borderTop: `1px solid ${BRZ.div}` }}>{children}</div>;
}
// Bottom action sheet (row overflow menu).
function ActionSheet({ title, actions, onClose }) {
  return (
    <div onClick={onClose} style={{ position: 'absolute', inset: 0, zIndex: 30, background: 'rgba(0,0,0,0.5)', display: 'flex', alignItems: 'flex-end', animation: 'kfade .15s ease' }}>
      <div onClick={e => e.stopPropagation()} style={{ width: '100%', background: BRZ.card, borderTopLeftRadius: 14, borderTopRightRadius: 14, borderTop: `1px solid ${BRZ.div}`, paddingBottom: 8, animation: 'ksheet .22s cubic-bezier(.2,.8,.3,1)' }}>
        <div style={{ width: 36, height: 4, borderRadius: 2, background: 'rgba(255,255,255,0.2)', margin: '9px auto 4px' }} />
        <div style={{ fontSize: 12.5, fontWeight: 700, color: BRZ.dim, padding: '6px 18px 8px' }}>{title}</div>
        {actions.map((a, i) => (
          <div key={i} onClick={() => { onClose(); a.onClick && a.onClick(); }} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '13px 18px', cursor: 'pointer', color: a.danger ? BRZ.danger : BRZ.text }}>
            <Icon name={a.icon} size={19} stroke={1.9} style={{ color: a.danger ? BRZ.danger : BRZ.dim }} />
            <span style={{ fontSize: 14.5, fontWeight: 500 }}>{a.label}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

const LANG_CATALOG = [
  { id: 'en_US', name: 'English (US)', source: 'rebble', installed: true },
  { id: 'de_DE', name: 'Deutsch', source: 'rebble', installed: false },
  { id: 'ja_JP', name: '日本語 (Japanese)', source: 'github', installed: false },
];

function KdeApp() {
  const S = window.STO;
  const [tab, setTab] = React.useState('watch');
  const [seg, setSeg] = React.useState('faces');
  const [sync, setSync] = React.useState(() => Object.fromEntries(S.sync.map(s => [s.id, s.on])));
  const [ext, setExt] = React.useState(() => Object.fromEntries(S.extensions.map(e => [e.name, e.enabled])));
  const [ws, setWs] = React.useState(S.watchSettings);
  const [toast, setToast] = React.useState(null);
  const [dlg, setDlg] = React.useState(null);          // {type, ...}
  const [sheet, setSheet] = React.useState(null);      // {title, actions}
  const [pairPhase, setPairPhase] = React.useState('searching');
  const [fw, setFw] = React.useState({ phase: 'idle', pct: 0 });
  const [lang, setLang] = React.useState({ id: null, phase: 'idle', pct: 0 });
  const [langDone, setLangDone] = React.useState({});
  const [confirmText, setConfirmText] = React.useState('');
  const [keepCfg, setKeepCfg] = React.useState(false);
  const timers = React.useRef([]);
  const clearTimers = () => { timers.current.forEach(clearTimeout); timers.current.forEach(clearInterval); timers.current = []; };
  const ping = (msg) => { setToast(msg); clearTimeout(window.__kdeT); window.__kdeT = setTimeout(() => setToast(null), 2200); };

  // ── Pairing flow (Pair → poll PairStatus: searching → confirm → paired) ──
  const startPair = () => {
    clearTimers(); setPairPhase('searching'); setDlg({ type: 'pair' });
    timers.current.push(setTimeout(() => setPairPhase('confirm'), 1500));
    timers.current.push(setTimeout(() => setPairPhase('paired'), 4300));
  };
  // ── Firmware flash (UpdateFirmware → poll FirmwareStatus) ──
  const startFlash = () => {
    clearTimers(); setFw({ phase: 'downloading', pct: 0 });
    timers.current.push(setTimeout(() => {
      setFw({ phase: 'flashing', pct: 0 });
      let p = 0; const iv = setInterval(() => {
        p += Math.random() * 9 + 4;
        if (p >= 100) { clearInterval(iv); setFw({ phase: 'flashing', pct: 100 }); timers.current.push(setTimeout(() => setFw({ phase: 'reboot', pct: 100 }), 600)); }
        else setFw({ phase: 'flashing', pct: Math.round(p) });
      }, 280); timers.current.push(iv);
    }, 1200));
  };
  // ── Language install (InstallLanguage → poll LanguageStatus) ──
  const startLang = (id) => {
    clearTimers(); setLang({ id, phase: 'downloading', pct: 0 });
    timers.current.push(setTimeout(() => {
      let p = 0; const iv = setInterval(() => {
        p += Math.random() * 11 + 6;
        if (p >= 100) { clearInterval(iv); setLang({ id, phase: 'done', pct: 100 }); setLangDone(d => ({ ...d, [id]: true })); timers.current.push(setTimeout(() => setLang({ id: null, phase: 'idle', pct: 0 }), 1400)); }
        else setLang({ id, phase: 'installing', pct: Math.round(p) });
      }, 240); timers.current.push(iv);
    }, 900));
  };
  const closeDlg = () => { clearTimers(); setDlg(null); setConfirmText(''); setKeepCfg(false); };

  const tabs = [['watch', 'watch', 'Watch'], ['apps', 'apps', 'Apps'], ['ext', 'puzzle', 'Plugins'], ['settings', 'sliders', 'Sync'], ['system', 'tools', 'System']];
  const titles = { watch: 'Watch', apps: 'Apps & Faces', ext: 'Extensions', settings: 'Sync & Settings', system: 'System' };
  const fab = { watch: 'Pair watch', apps: 'Install', ext: 'Add extension', settings: null, system: null };
  const onFab = { watch: startPair, apps: () => ping('Choose a .pbw to install…'), ext: () => ping('Choose an extension archive…') };

  const scroll = (children) => <div style={{ flex: 1, overflowY: 'auto', padding: '14px 14px 78px' }}>{children}</div>;

  let body;
  if (tab === 'watch') {
    body = scroll(<>
      <FormCard style={{ marginBottom: 16 }}>
        <div style={{ padding: '16px 14px', display: 'flex', alignItems: 'center', gap: 14 }}>
          <WatchGlyph size={50} accent={BRZ.accent} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 16.5, fontWeight: 700 }}>{S.watch.name}</div>
            <div style={{ fontSize: 12.5, color: BRZ.dim, marginTop: 2 }}>{S.watch.model}</div>
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, marginTop: 8, background: 'rgba(39,174,96,0.16)', borderRadius: 4, padding: '2px 8px' }}>
              <span style={{ width: 6, height: 6, borderRadius: 3, background: BRZ.good }} />
              <span style={{ fontSize: 11.5, color: BRZ.good, fontWeight: 700 }}>Connected · {S.watch.transport}</span>
            </div>
          </div>
          <div style={{ textAlign: 'center' }}>
            <BatteryGlyph level={S.watch.battery} size={28} color={BRZ.dim} />
            <div style={{ fontSize: 13.5, fontWeight: 700, marginTop: 3 }}>{S.watch.battery}%</div>
          </div>
        </div>
      </FormCard>
      <FormHeader>HARDWARE</FormHeader>
      <FormCard style={{ marginBottom: 16 }}>
        <FormDelegate icon="info" title="Model" subtitle={S.watch.model} trailing={<BChip tone="system">{S.watch.platform}</BChip>} />
        <FormDelegate icon="bluetooth" title="Transport" subtitle={S.watch.transport} />
        <FormDelegate icon="download" title="Firmware" subtitle={S.watch.firmware} trailing={<Icon name="chevron" size={16} style={{ color: BRZ.faint }} />} onClick={() => setTab('system')} />
      </FormCard>
      <FormHeader>KNOWN WATCHES</FormHeader>
      <FormCard>
        {S.knownWatches.map(w => (
          <FormDelegate key={w.code} icon="watch" iconTone={w.connected ? BRZ.good : BRZ.dim}
            title={`${w.name} · ${w.code}`} subtitle={`${w.model} · ${w.transport}`}
            trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              {w.connected ? <BChip tone="active">active</BChip> : <button style={btnB()} onClick={() => ping(`Connecting to ${w.name}…`)}>Connect</button>}
              <button style={iconBtnSm} onClick={() => setSheet({ title: `${w.name} · ${w.code}`, actions: [
                { label: 'Re-pair', icon: 'link', onClick: startPair },
                { label: 'Rename', icon: 'file', onClick: () => ping('Rename watch…') },
                { label: 'Forget watch', icon: 'trash', danger: true, onClick: () => ping(`Forgot ${w.name}`) },
              ] })}><Icon name="kebab" size={17} style={{ color: BRZ.faint }} /></button>
            </div>} />
        ))}
      </FormCard>
    </>);
  } else if (tab === 'apps') {
    const list = seg === 'faces' ? S.faces : S.apps;
    body = scroll(<>
      <div style={{ display: 'flex', background: BRZ.view, borderRadius: 7, padding: 3, marginBottom: 16, border: `1px solid ${BRZ.div}` }}>
        {[['faces', `Watchfaces · ${S.faces.length}`], ['apps', `Apps · ${S.apps.length}`]].map(([k, l]) => (
          <button key={k} onClick={() => setSeg(k)} style={{ flex: 1, padding: '8px 0', borderRadius: 5, border: 'none', cursor: 'pointer', fontFamily: BRZ.font, fontSize: 13, fontWeight: 700, background: seg === k ? BRZ.accent : 'transparent', color: seg === k ? '#06151d' : BRZ.dim }}>{l}</button>
        ))}
      </div>
      <FormCard>
        {list.map(item => {
          const sys = item.flags.includes('system'), cfg = item.flags.includes('config');
          return (
            <FormDelegate key={item.uuid} icon={item.flags.includes('active') ? 'star' : (seg === 'faces' ? 'watch' : 'apps')}
              iconTone={item.flags.includes('active') ? BRZ.accent : BRZ.dim} title={item.name} subtitle={item.uuid}
              trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                {item.flags.map(f => <BChip key={f} tone={f}>{f}</BChip>)}
                <button style={iconBtnSm} onClick={() => setSheet({ title: item.name, actions: [
                  { label: 'Launch on watch', icon: 'play', onClick: () => ping(`Launching ${item.name}…`) },
                  ...(cfg ? [{ label: 'Configure (Clay)', icon: 'sliders', onClick: () => ping('Opening config page…') }] : []),
                  { label: sys ? 'Remove (system app)' : 'Remove', icon: 'trash', danger: !sys, onClick: () => ping(sys ? 'System apps can’t be removed' : `Removed ${item.name}`) },
                ] })}><Icon name="kebab" size={17} style={{ color: BRZ.faint }} /></button>
              </div>} />
          );
        })}
      </FormCard>
    </>);
  } else if (tab === 'ext') {
    body = scroll(<>
      <FormHeader>COMPANION APPS</FormHeader>
      <FormCard>
        {S.extensions.map(e => (
          <FormDelegate key={e.name} icon="puzzle" iconTone={ext[e.name] ? BRZ.purple : BRZ.dim}
            title={e.name} subtitle={e.desc}
            trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
              {ext[e.name] && <span style={{ fontSize: 9.5, fontWeight: 700, color: BRZ.good, border: `1px solid ${BRZ.good}`, borderRadius: 3, padding: '1px 5px' }}>RUN</span>}
              <BSwitch on={ext[e.name]} onClick={() => { setExt(p => ({ ...p, [e.name]: !p[e.name] })); ping(ext[e.name] ? `${e.name} stopped` : `${e.name} started`); }} />
              <button style={iconBtnSm} onClick={() => setSheet({ title: e.name, actions: [
                { label: 'Restart', icon: 'refresh', onClick: () => ping(`Restarted ${e.name}`) },
                { label: 'Uninstall', icon: 'trash', danger: true, onClick: () => { setKeepCfg(false); setDlg({ type: 'extUninstall', name: e.name }); } },
              ] })}><Icon name="kebab" size={17} style={{ color: BRZ.faint }} /></button>
            </div>} />
        ))}
      </FormCard>
      <div style={{ fontSize: 12, color: BRZ.faint, padding: '10px 6px 0', lineHeight: 1.5 }}>Host-side companions that drive watch notifications with quick replies & actions.</div>
    </>);
  } else if (tab === 'settings') {
    body = scroll(<>
      <FormHeader>SYNC SERVICES</FormHeader>
      <FormCard style={{ marginBottom: 16 }}>
        {S.sync.map(s => <FormDelegate key={s.id} icon={syncIcon(s.id)} title={s.name} subtitle={s.desc} trailing={<BSwitch on={sync[s.id]} onClick={() => { setSync(p => ({ ...p, [s.id]: !p[s.id] })); ping(sync[s.id] ? `${s.name} sync off` : `${s.name} sync on`); }} />} />)}
      </FormCard>
      <FormHeader>WATCH SETTINGS</FormHeader>
      <FormCard style={{ marginBottom: 16 }}>
        <FormDelegate icon="power" title="Quick launch · Up" trailing={<ComboB value={ws.quickLaunchUp} />} />
        <FormDelegate icon="power" title="Quick launch · Down" trailing={<ComboB value={ws.quickLaunchDown} />} />
        <FormDelegate icon="sun" title="Backlight" subtitle={`Timeout ${ws.backlightTimeout}s`} trailing={<BSwitch on={ws.backlight} onClick={() => setWs(p => ({ ...p, backlight: !p.backlight }))} />} />
        <FormDelegate icon="sun" title="Motion backlight" subtitle="Wake on wrist flick" trailing={<BSwitch on={ws.motionBacklight} onClick={() => setWs(p => ({ ...p, motionBacklight: !p.motionBacklight }))} />} />
      </FormCard>
      <FormCard>
        <div style={{ padding: '14px 14px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13.5, fontWeight: 600 }}><span>Ambient light threshold</span><span style={{ color: BRZ.accent }}>{ws.ambientThreshold} lx</span></div>
          <div style={{ marginTop: 12 }}><SliderB value={ws.ambientThreshold} min={0} max={400} onChange={v => setWs(p => ({ ...p, ambientThreshold: v }))} /></div>
        </div>
      </FormCard>
    </>);
  } else {
    body = scroll(<>
      <FormCard style={{ marginBottom: 16, borderColor: S.firmware.updateAvailable ? 'rgba(246,116,0,0.4)' : BRZ.div }}>
        <div style={{ padding: '15px 14px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{ width: 36, height: 36, borderRadius: 7, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(246,116,0,0.18)', color: BRZ.warn }}><Icon name="download" size={20} /></span>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 14.5, fontWeight: 700 }}>{fw.phase === 'reboot' ? 'Flashed — rebooting' : S.firmware.updateAvailable ? 'Update available' : 'Up to date'}</div>
              <div style={{ fontSize: 12, color: BRZ.dim, marginTop: 2 }}>{S.firmware.current}{S.firmware.updateAvailable ? ` → ${S.firmware.latest}` : ''} · {S.firmware.channel}</div>
            </div>
          </div>
          {/* Flash button → inline progress (FirmwareStatus polling) */}
          {fw.phase === 'idle' && S.firmware.updateAvailable && (
            <button style={{ ...btnB('solid', BRZ.warn), width: '100%', justifyContent: 'center', padding: '9px 0', marginTop: 12 }} onClick={startFlash}>Flash {S.firmware.latest}</button>
          )}
          {fw.phase !== 'idle' && (
            <div style={{ marginTop: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 7, color: BRZ.dim }}>
                <span>{fw.phase === 'downloading' ? 'Downloading…' : fw.phase === 'reboot' ? 'Rebooting watch ✓' : 'Installing — keep on charger'}</span>
                {fw.phase === 'flashing' && <span style={{ color: BRZ.text, fontWeight: 700 }}>{fw.pct}%</span>}
              </div>
              <Bar pct={fw.pct} indeterminate={fw.phase === 'downloading'} color={fw.phase === 'reboot' ? BRZ.good : BRZ.warn} />
            </div>
          )}
        </div>
      </FormCard>

      <FormHeader>LANGUAGE PACKS</FormHeader>
      <FormCard style={{ marginBottom: 16 }}>
        {LANG_CATALOG.map(L => {
          const installed = L.installed || langDone[L.id];
          const active = lang.id === L.id && lang.phase !== 'idle';
          return (
            <div key={L.id} style={{ padding: '11px 14px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <span style={{ width: 32, height: 32, borderRadius: 6, flex: '0 0 auto', display: 'flex', alignItems: 'center', justifyContent: 'center', background: BRZ.accentDim, color: BRZ.accent }}><Icon name="globe" size={18} /></span>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 14.5, fontWeight: 500 }}>{L.name}</div>
                  <div style={{ fontSize: 11.5, color: BRZ.faint, marginTop: 2 }}>{L.id} · {L.source}</div>
                </div>
                {installed ? <BChip tone="active">installed</BChip>
                  : active ? <span style={{ fontSize: 12, color: BRZ.dim, fontWeight: 600 }}>{lang.phase === 'downloading' ? '…' : `${lang.pct}%`}</span>
                  : <button style={btnB()} onClick={() => startLang(L.id)}>Install</button>}
              </div>
              {active && <div style={{ marginTop: 10 }}><Bar pct={lang.pct} indeterminate={lang.phase === 'downloading'} /></div>}
            </div>
          );
        })}
      </FormCard>

      <FormHeader>DIAGNOSTICS</FormHeader>
      <FormCard style={{ marginBottom: 16 }}>
        <FormDelegate icon="camera" title="Screenshot" onClick={() => ping('Screenshot saved')} />
        <FormDelegate icon="file" title="Pull watch logs" onClick={() => ping('Pulling logs…')} />
        <FormDelegate icon="archive" title="Support bundle" subtitle="Redacted .tar.gz" onClick={() => ping('Building support bundle…')} />
        <FormDelegate icon="archive" title="Backup & restore" subtitle={`${S.backup.last} · ${S.backup.size}`} trailing={<Icon name="chevron" size={16} style={{ color: BRZ.faint }} />} onClick={() => ping('via stoandl CLI')} />
      </FormCard>
      <FormHeader>DANGER ZONE</FormHeader>
      <FormCard>
        <FormDelegate icon="refresh" danger title="Reboot to recovery (PRF)" onClick={() => setDlg({ type: 'recovery' })} />
        <FormDelegate icon="alert" danger title="Factory reset" subtitle="Irreversible · wipes the watch" onClick={() => { setConfirmText(''); setDlg({ type: 'factory' }); }} />
      </FormCard>
    </>);
  }

  return (
    <PhoneFrame bg={BRZ.win}>
      <div style={{ display: 'flex', flexDirection: 'column', height: '100%', fontFamily: BRZ.font, color: BRZ.text, position: 'relative' }}>
        <StatusBar />
        <div style={{ height: 50, flex: '0 0 50px', background: BRZ.head, display: 'flex', alignItems: 'center', padding: '0 6px 0 14px', borderBottom: `1px solid ${BRZ.div}` }}>
          <div style={{ flex: 1, fontSize: 18, fontWeight: 700 }}>{titles[tab]}</div>
          <button style={iconBtnB} onClick={() => ping('Syncing all services…')}><Icon name="sync" size={20} /></button>
          <button style={iconBtnB}><Icon name="kebab" size={20} /></button>
        </div>

        {body}

        {fab[tab] && (
          <button onClick={onFab[tab]} style={{ position: 'absolute', right: 16, bottom: 74, height: 48, borderRadius: 24, border: 'none', cursor: 'pointer', background: BRZ.accent, color: '#06151d', display: 'flex', alignItems: 'center', gap: 7, padding: '0 18px', fontFamily: BRZ.font, fontSize: 14, fontWeight: 700, boxShadow: '0 4px 14px rgba(0,0,0,0.4)', zIndex: 5 }}>
            <Icon name="plus" size={19} stroke={2.6} />{fab[tab]}
          </button>
        )}

        <div style={{ position: 'absolute', left: 14, right: 14, bottom: 70, zIndex: 8, display: 'flex', justifyContent: 'center', pointerEvents: 'none', opacity: toast ? 1 : 0, transform: toast ? 'translateY(0)' : 'translateY(8px)', transition: 'opacity .2s, transform .2s' }}>
          {toast && <div style={{ background: '#0d0f11', color: '#fff', borderRadius: 6, padding: '9px 14px', fontSize: 12.5, fontWeight: 500, boxShadow: '0 4px 16px rgba(0,0,0,0.5)', border: `1px solid ${BRZ.div}`, maxWidth: '100%' }}>{toast}</div>}
        </div>

        <div style={{ flex: '0 0 auto', display: 'flex', background: BRZ.head, borderTop: `1px solid ${BRZ.div}`, padding: '4px 2px 7px' }}>
          {tabs.map(([k, icon, label]) => {
            const on = tab === k;
            return (
              <button key={k} onClick={() => setTab(k)} style={{ flex: 1, background: 'none', border: 'none', cursor: 'pointer', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, padding: '5px 0 3px', color: on ? BRZ.accent : BRZ.dim, position: 'relative' }}>
                <div style={{ width: 40, height: 4, borderRadius: 2, background: on ? BRZ.accent : 'transparent', position: 'absolute', top: 0 }} />
                <Icon name={icon} size={21} stroke={on ? 2.2 : 1.8} />
                <span style={{ fontSize: 10.5, fontWeight: on ? 700 : 600 }}>{label}</span>
              </button>
            );
          })}
        </div>

        {/* ── Row action sheet ── */}
        {sheet && <ActionSheet title={sheet.title} actions={sheet.actions} onClose={() => setSheet(null)} />}

        {/* ── Pairing dialog ── */}
        {dlg && dlg.type === 'pair' && (
          <Modal onClose={pairPhase === 'paired' ? closeDlg : undefined}>
            <div style={{ padding: '22px 18px 18px', textAlign: 'center' }}>
              {pairPhase === 'searching' && <>
                <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 14 }}><Spinner size={34} /></div>
                <div style={{ fontSize: 16, fontWeight: 700 }}>Searching for watches</div>
                <div style={{ fontSize: 12.5, color: BRZ.dim, marginTop: 6, lineHeight: 1.5 }}>Put your Pebble in Bluetooth pairing range. A ~2-minute window is open.</div>
              </>}
              {pairPhase === 'confirm' && <>
                <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 10 }}><WatchGlyph size={44} accent={BRZ.accent} /></div>
                <div style={{ fontSize: 15.5, fontWeight: 700 }}>Confirm on your watch</div>
                <div style={{ fontSize: 12.5, color: BRZ.dim, marginTop: 6 }}>Does the watch show this code?</div>
                <div style={{ fontSize: 30, fontWeight: 700, letterSpacing: 4, margin: '12px 0 4px', fontVariantNumeric: 'tabular-nums', color: BRZ.accent }}>814 372</div>
                <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, marginTop: 8, color: BRZ.dim, fontSize: 12 }}><Spinner size={14} stroke={2} /> Waiting for confirmation…</div>
              </>}
              {pairPhase === 'paired' && <>
                <div style={{ width: 46, height: 46, borderRadius: 23, margin: '0 auto 12px', background: 'rgba(39,174,96,0.18)', color: BRZ.good, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon name="check" size={26} stroke={2.6} /></div>
                <div style={{ fontSize: 16, fontWeight: 700 }}>Paired</div>
                <div style={{ fontSize: 12.5, color: BRZ.dim, marginTop: 6 }}>Pebble Time 2 is connected and syncing your locker.</div>
              </>}
            </div>
            <DlgFoot>
              {pairPhase === 'paired'
                ? <button style={btnB('solid')} onClick={closeDlg}>Done</button>
                : <button style={btnB()} onClick={closeDlg}>Cancel</button>}
            </DlgFoot>
          </Modal>
        )}

        {/* ── Factory reset typed-confirm ── */}
        {dlg && dlg.type === 'factory' && (
          <Modal onClose={closeDlg}>
            <div style={{ padding: '18px 18px 14px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
                <span style={{ width: 34, height: 34, borderRadius: 17, background: 'rgba(218,68,83,0.16)', color: BRZ.danger, display: 'flex', alignItems: 'center', justifyContent: 'center', flex: '0 0 auto' }}><Icon name="alert" size={19} /></span>
                <div style={{ fontSize: 16, fontWeight: 700 }}>Factory reset</div>
              </div>
              <div style={{ fontSize: 13, color: BRZ.dim, lineHeight: 1.55 }}>This erases all apps, settings and the host pairing on <b style={{ color: BRZ.text }}>{S.watch.name}</b>. You’ll need to pair it again. This cannot be undone.</div>
              <div style={{ fontSize: 12, color: BRZ.dim, margin: '14px 0 6px' }}>Type <b style={{ color: BRZ.text }}>yes</b> to confirm</div>
              <input value={confirmText} onChange={e => setConfirmText(e.target.value)} placeholder="yes" autoFocus
                style={{ width: '100%', padding: '9px 11px', borderRadius: 6, border: `1px solid ${confirmText === 'yes' ? BRZ.danger : BRZ.div}`, background: BRZ.view, color: BRZ.text, fontFamily: BRZ.font, fontSize: 14, outline: 'none' }} />
            </div>
            <DlgFoot>
              <button style={btnB()} onClick={closeDlg}>Cancel</button>
              <button disabled={confirmText !== 'yes'} onClick={() => { closeDlg(); ping('Factory reset sent to watch'); }}
                style={{ ...btnB('solid', BRZ.danger), opacity: confirmText === 'yes' ? 1 : 0.4, cursor: confirmText === 'yes' ? 'pointer' : 'not-allowed' }}>Wipe watch</button>
            </DlgFoot>
          </Modal>
        )}

        {/* ── Reboot to recovery confirm ── */}
        {dlg && dlg.type === 'recovery' && (
          <Modal onClose={closeDlg}>
            <div style={{ padding: '18px 18px 14px' }}>
              <div style={{ fontSize: 16, fontWeight: 700, marginBottom: 8 }}>Reboot to recovery?</div>
              <div style={{ fontSize: 13, color: BRZ.dim, lineHeight: 1.55 }}>The watch restarts into recovery (PRF) firmware. Use this to recover from a bad flash — you can reflash normal firmware afterwards.</div>
            </div>
            <DlgFoot>
              <button style={btnB()} onClick={closeDlg}>Cancel</button>
              <button style={btnB('solid', BRZ.warn)} onClick={() => { closeDlg(); ping('Rebooting to recovery…'); }}>Reboot</button>
            </DlgFoot>
          </Modal>
        )}

        {/* ── Extension uninstall (keep-config) ── */}
        {dlg && dlg.type === 'extUninstall' && (
          <Modal onClose={closeDlg}>
            <div style={{ padding: '18px 18px 14px' }}>
              <div style={{ fontSize: 16, fontWeight: 700, marginBottom: 8 }}>Remove {dlg.name}?</div>
              <div style={{ fontSize: 13, color: BRZ.dim, lineHeight: 1.55 }}>Stops the extension, removes it from the run-list, and deletes its files{dlg.name ? '' : ''}.</div>
              <label style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 14, cursor: 'pointer' }} onClick={() => setKeepCfg(k => !k)}>
                <span style={{ width: 20, height: 20, borderRadius: 4, flex: '0 0 auto', border: `1.5px solid ${keepCfg ? BRZ.accent : BRZ.faint}`, background: keepCfg ? BRZ.accent : 'transparent', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#06151d' }}>{keepCfg && <Icon name="check" size={14} stroke={3} />}</span>
                <span style={{ fontSize: 13.5 }}>Keep configuration for a later reinstall</span>
              </label>
            </div>
            <DlgFoot>
              <button style={btnB()} onClick={closeDlg}>Cancel</button>
              <button style={btnB('solid', BRZ.danger)} onClick={() => { const n = dlg.name; closeDlg(); ping(keepCfg ? `Removed ${n} (config kept)` : `Removed ${n}`); }}>Remove</button>
            </DlgFoot>
          </Modal>
        )}
      </div>
    </PhoneFrame>
  );
}

function ComboB({ value }) { return <span style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 13.5, color: BRZ.dim }}>{value}<Icon name="chevron" size={14} style={{ transform: 'rotate(90deg)' }} /></span>; }
function SliderB({ value, min, max, onChange }) {
  const ref = React.useRef(null);
  const pct = (value - min) / (max - min);
  const set = (x) => { const r = ref.current.getBoundingClientRect(); onChange(Math.round((Math.min(1, Math.max(0, (x - r.left) / r.width)) * (max - min) + min) / 10) * 10); };
  return (
    <div ref={ref} onPointerDown={e => { e.currentTarget.setPointerCapture(e.pointerId); set(e.clientX); }} onPointerMove={e => { if (e.buttons) set(e.clientX); }} style={{ height: 20, display: 'flex', alignItems: 'center', cursor: 'pointer', touchAction: 'none' }}>
      <div style={{ flex: 1, height: 4, borderRadius: 2, background: 'rgba(255,255,255,0.16)', position: 'relative' }}>
        <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: `${pct * 100}%`, background: BRZ.accent, borderRadius: 2 }} />
        <div style={{ position: 'absolute', left: `calc(${pct * 100}% - 8px)`, top: -6, width: 16, height: 16, borderRadius: 8, background: BRZ.accent, border: '2px solid #fff' }} />
      </div>
    </div>
  );
}
const iconBtnB = { background: 'none', border: 'none', color: BRZ.text, cursor: 'pointer', padding: 9, display: 'flex' };
const iconBtnSm = { background: 'none', border: 'none', cursor: 'pointer', padding: 4, display: 'flex', flex: '0 0 auto' };
function btnB(variant, bg) {
  const solid = variant === 'solid';
  return { display: 'inline-flex', alignItems: 'center', gap: 5, background: solid ? (bg || BRZ.accent) : 'transparent', color: solid ? '#06151d' : BRZ.accent, border: solid ? 'none' : `1px solid ${BRZ.accent}`, borderRadius: 5, padding: '6px 12px', fontSize: 12.5, fontWeight: 700, cursor: 'pointer', fontFamily: BRZ.font };
}

Object.assign(window, { KdeApp, BRZ, FormCard, FormHeader, FormDelegate, BSwitch, BChip, ComboB, SliderB, btnB });
