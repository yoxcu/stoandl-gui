/* stoandl — KDE "by the book" (Kirigami HIG-verified).
   Sources checked: develop.kde.org/hig/layout_and_nav
   - ≤5 destinations → Kirigami.NavigationTabBar (below content on mobile,
     ABOVE content on desktop). Launch view (Watch) is first.
   - Page actions live in the toolbar/header (NOT a Material FAB).
   - Kirigami spacing scale: gridUnit 18; largeSpacing between groups,
     smallSpacing within a group; IconSizes.medium for list items w/ subtitle.
   - Content on desktop is width-constrained & centered (Kirigami form pattern).
   Breeze Dark palette (matches BreezeDark-dev-preview.kdeglobals). */

const KB = {
  win: '#2a2e32', card: '#31363b', view: '#232629', header: '#31363b',
  text: '#fcfcfc', dim: '#a1a9b1', faint: 'rgba(255,255,255,0.34)',
  sep: 'rgba(255,255,255,0.10)', accent: '#3daee9', accentText: '#06151d',
  accentDim: 'rgba(61,174,233,0.15)', good: '#27ae60', danger: '#da4453',
  warn: '#f67400', purple: '#9b59b6',
  font: '"Noto Sans","Segoe UI",system-ui,sans-serif',
};
// Kirigami unit scale (gridUnit = 18)
const U = { grid: 18, small: 6, medium: 10, large: 18, radius: 6 };

if (typeof document !== 'undefined' && !document.getElementById('kb-anim')) {
  const s = document.createElement('style'); s.id = 'kb-anim';
  s.textContent = '@keyframes kbspin{to{transform:rotate(360deg)}}@keyframes kbfade{from{opacity:0}to{opacity:1}}';
  document.head.appendChild(s);
}

function KBSwitch({ on, onClick }) {
  return (
    <button onClick={onClick} style={{ width: 42, height: 23, borderRadius: 4, border: 'none', cursor: 'pointer', flex: '0 0 auto', padding: 0, background: on ? KB.accent : 'rgba(255,255,255,0.17)', position: 'relative', transition: 'background .15s' }}>
      <span style={{ position: 'absolute', top: 3, left: on ? 22 : 3, width: 17, height: 17, borderRadius: 3, background: '#fff', transition: 'left .15s' }} />
    </button>
  );
}
function KBSpinner({ size = 22, stroke = 3 }) {
  return <span style={{ width: size, height: size, borderRadius: '50%', border: `${stroke}px solid rgba(255,255,255,0.16)`, borderTopColor: KB.accent, display: 'inline-block', animation: 'kbspin .8s linear infinite' }} />;
}
function KBCard({ children, style }) {
  return (
    <div style={{ background: KB.card, borderRadius: 8, border: `1px solid ${KB.sep}`, overflow: 'hidden', ...style }}>
      {React.Children.map(children, (c, i) => c && (
        <React.Fragment>{i > 0 && <div style={{ height: 1, background: KB.sep, marginLeft: 14 }} />}{c}</React.Fragment>
      ))}
    </div>
  );
}
// Section header (FormHeader). Uses largeSpacing above, smallSpacing below.
function KBHeader({ children, style }) {
  return <div style={{ fontSize: 13, fontWeight: 700, color: KB.dim, padding: `0 4px ${U.small}px`, letterSpacing: 0.3, ...style }}>{children}</div>;
}
// FormDelegate. Icon size = medium (22) when subtitle present.
function KBRow({ icon, iconColor, title, subtitle, trailing, onClick, danger }) {
  return (
    <div onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '11px 14px', cursor: onClick ? 'pointer' : 'default' }}>
      {icon && <span style={{ width: 22, height: 22, flex: '0 0 auto', display: 'flex', alignItems: 'center', justifyContent: 'center', color: danger ? KB.danger : (iconColor || KB.dim) }}><Icon name={icon} size={22} stroke={1.85} /></span>}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 14.5, fontWeight: 500, color: danger ? KB.danger : KB.text, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</div>
        {subtitle && <div style={{ fontSize: 12, color: KB.dim, marginTop: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{subtitle}</div>}
      </div>
      {trailing}
    </div>
  );
}
function KBChip({ children, tone }) {
  const map = { active: KB.accent, system: 'rgba(255,255,255,0.16)', config: KB.purple, sideloaded: KB.warn };
  const c = map[tone] || 'rgba(255,255,255,0.16)';
  const solid = tone === 'active';
  return <span style={{ fontSize: 10, fontWeight: 700, padding: '2px 6px', borderRadius: 4, background: solid ? c : 'transparent', color: solid ? KB.accentText : c, border: solid ? 'none' : `1px solid ${c}` }}>{children}</span>;
}
function KBBtn({ children, solid, tone, onClick, icon }) {
  const bg = tone === 'danger' ? KB.danger : tone === 'warn' ? KB.warn : KB.accent;
  return (
    <button onClick={onClick} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, background: solid ? bg : 'transparent', color: solid ? KB.accentText : KB.text, border: solid ? 'none' : `1px solid ${KB.sep}`, borderRadius: U.radius, padding: '7px 12px', fontSize: 13, fontWeight: 600, cursor: 'pointer', fontFamily: KB.font, whiteSpace: 'nowrap' }}>
      {icon && <Icon name={icon} size={16} stroke={2.2} />}{children}
    </button>
  );
}
const NAV = [
  ['watch', 'watch', 'Watch'], ['health', 'heart', 'Health'], ['apps', 'apps', 'Apps'],
  ['notif', 'bell', 'Notifications'], ['settings', 'sliders', 'Settings'],
];

// Kirigami.InlineMessage analogue — banner with icon, text, and inline actions.
function InlineMessage({ tone = 'info', icon, title, body, actions = [] }) {
  const c = tone === 'warn' ? KB.warn : tone === 'good' ? KB.good : KB.accent;
  const bg = tone === 'warn' ? 'rgba(246,116,0,0.13)' : tone === 'good' ? 'rgba(39,174,96,0.13)' : 'rgba(61,174,233,0.12)';
  return (
    <div style={{ display: 'flex', gap: 12, background: bg, border: `1px solid ${c}55`, borderRadius: 8, padding: '13px 14px', marginBottom: U.large }}>
      {icon && <span style={{ color: c, flex: '0 0 auto', marginTop: 1 }}><Icon name={icon} size={20} /></span>}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 14, fontWeight: 700, color: KB.text }}>{title}</div>
        {body && <div style={{ fontSize: 12.5, color: KB.dim, marginTop: 3, lineHeight: 1.5 }}>{body}</div>}
        {actions.length > 0 && (
          <div style={{ display: 'flex', gap: 14, marginTop: 10 }}>
            {actions.map(a => (
              <button key={a.label} onClick={a.onClick} style={{ display: 'inline-flex', alignItems: 'center', gap: 5, background: 'none', border: 'none', cursor: 'pointer', padding: 0, color: c, fontFamily: KB.font, fontSize: 13, fontWeight: 700 }}>
                {a.icon && <Icon name={a.icon} size={15} stroke={2.1} />}{a.label}
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
const TITLES = { watch: 'Watch', health: 'Health', apps: 'Apps & Faces', notif: 'Notifications', settings: 'Settings' };

// ── Shared screen bodies (used by BOTH mobile & desktop) ────────────────
function useStoState() {
  const S = window.STO;
  const [sync, setSync] = React.useState(() => Object.fromEntries(S.sync.map(s => [s.id, s.on])));
  const [ext, setExt] = React.useState(() => Object.fromEntries(S.extensions.map(e => [e.name, e.enabled])));
  const [ws, setWs] = React.useState(S.watchSettings);
  const [seg, setSeg] = React.useState('faces');
  const [daemon, setDaemon] = React.useState(() => Object.fromEntries((S.daemonSettings || []).map(d => [d.key, d.value])));
  return { S, sync, setSync, ext, setExt, ws, setWs, seg, setSeg, daemon, setDaemon };
}

function ScreenBody({ tab, st, ping, onPair, onMenu, goTo, onInfo, onRemove }) {
  const { S, sync, setSync, ext, setExt, ws, setWs, seg, setSeg, daemon, setDaemon } = st;
  if (tab === 'watch') {
    return (<>
      {S.firmware.updateAvailable && (
        <InlineMessage tone="info" icon="download"
          title={`PebbleOS ${S.firmware.latest} available`}
          body={`You’re on ${S.firmware.current}. Update to get the latest features and fixes.`}
          actions={[
            { label: 'Update now', primary: true, onClick: () => ping(`Updating to PebbleOS ${S.firmware.latest}…`) },
            { label: 'What’s new', icon: 'link', onClick: () => window.open(S.firmware.changelogUrl, '_blank', 'noopener') },
          ]} />
      )}
      <KBCard style={{ marginBottom: U.large }}>
        <div onClick={onInfo} style={{ padding: '15px 14px', display: 'flex', alignItems: 'center', gap: 14, cursor: 'pointer' }}>
          <WatchGlyph size={48} accent={KB.accent} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 16, fontWeight: 700 }}>{S.watch.name}</div>
            <div style={{ fontSize: 12.5, color: KB.dim, marginTop: 1 }}>{S.watch.model}</div>
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, marginTop: 7, background: 'rgba(39,174,96,0.15)', borderRadius: 4, padding: '2px 8px' }}>
              <span style={{ width: 6, height: 6, borderRadius: 3, background: KB.good }} />
              <span style={{ fontSize: 11.5, color: KB.good, fontWeight: 700 }}>Connected · {S.watch.transport}</span>
            </div>
          </div>
          <div style={{ textAlign: 'center' }}>
            <BatteryGlyph level={S.watch.battery} size={28} color={KB.dim} />
            <div style={{ fontSize: 13.5, fontWeight: 700, marginTop: 3 }}>{S.watch.battery}%</div>
          </div>
          <Icon name="chevron" size={18} style={{ color: KB.faint, flex: '0 0 auto' }} />
        </div>
      </KBCard>
      <KBHeader>KNOWN WATCHES</KBHeader>
      <KBCard>
        {S.knownWatches.map(w => (
          <KBRow key={w.code} icon="watch" iconColor={w.connected ? KB.good : KB.dim}
            title={`${w.name} · ${w.code}`} subtitle={`${w.model} · ${w.transport}`}
            trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              {w.connected ? <KBChip tone="active">active</KBChip> : <KBBtn onClick={() => ping(`Connecting to ${w.name}…`)}>Connect</KBBtn>}
              <button style={iconBtnKB} title="Forget watch" onClick={() => onRemove(w, 'watch')}><Icon name="trash" size={18} style={{ color: KB.faint }} /></button>
            </div>} />
        ))}
      </KBCard>
    </>);
  }
  if (tab === 'apps') {
    return (<>
      <div style={{ display: 'flex', background: KB.view, borderRadius: U.radius, padding: 3, marginBottom: U.large, border: `1px solid ${KB.sep}` }}>
        {[['faces', `Faces · ${S.faces.length}`], ['apps', `Apps · ${S.apps.length}`], ['ext', `Extensions · ${S.extensions.length}`]].map(([k, l]) => (
          <button key={k} onClick={() => setSeg(k)} style={{ flex: 1, padding: '8px 0', borderRadius: 4, border: 'none', cursor: 'pointer', fontFamily: KB.font, fontSize: 12.5, fontWeight: 700, background: seg === k ? KB.accent : 'transparent', color: seg === k ? KB.accentText : KB.dim }}>{l}</button>
        ))}
      </div>
      {seg === 'ext' ? (<>
        <KBCard>
          {S.extensions.map(e => (
            <KBRow key={e.name} icon="puzzle" iconColor={ext[e.name] ? KB.purple : KB.dim} title={e.name} subtitle={e.desc}
              trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 6 }} onClick={ev => ev.stopPropagation()}>
                <KBSwitch on={ext[e.name]} onClick={() => { setExt(p => ({ ...p, [e.name]: !p[e.name] })); ping(ext[e.name] ? `${e.name} stopped` : `${e.name} started`); }} />
                <button style={iconBtnKB} title="Settings" onClick={() => ping(`Opening ${e.name} settings…`)}><Icon name="sliders" size={18} style={{ color: KB.dim }} /></button>
                <button style={iconBtnKB} title="Uninstall" onClick={() => onRemove({ ...e, flags: [] }, 'ext')}><Icon name="trash" size={18} style={{ color: KB.faint }} /></button>
              </div>} />
          ))}
        </KBCard>
        <div style={{ fontSize: 12, color: KB.faint, padding: '10px 6px 0', lineHeight: 1.5 }}>Extensions are host-side companions that drive watch notifications with quick replies & actions.</div>
      </>) : (
        <KBCard>
          {(seg === 'faces' ? S.faces : S.apps).map(item => {
            const sys = item.flags.includes('system');
            const cfg = item.flags.includes('config');
            const active = item.flags.includes('active');
            const isFace = seg === 'faces';
            return (
              <KBRow key={item.uuid} icon={active ? 'star' : (isFace ? 'watch' : 'apps')}
                iconColor={active ? KB.accent : KB.dim} title={item.name} subtitle={item.developer || item.uuid}
                onClick={() => ping(isFace ? `${item.name} — now active on watch` : `Launching ${item.name}…`)}
                trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 4 }} onClick={e => e.stopPropagation()}>
                  {item.flags.filter(f => f !== 'config' && f !== 'sideloaded').map(f => <KBChip key={f} tone={f}>{f}</KBChip>)}
                  {cfg && <button style={iconBtnKB} title="Settings" onClick={() => ping(`Opening ${item.name} settings…`)}><Icon name="sliders" size={18} style={{ color: KB.dim }} /></button>}
                  {!sys && <button style={iconBtnKB} title="Delete from locker" onClick={() => onRemove(item, isFace ? 'face' : 'app')}><Icon name="trash" size={18} style={{ color: KB.faint }} /></button>}
                </div>} />
            );
          })}
        </KBCard>
      )}
    </>);
  }
  if (tab === 'notif') {
    return <NotificationsScreen S={S} ping={ping} />;
  }
  if (tab === 'settings') {
    return (<>
      <KBHeader>SYNC SERVICES</KBHeader>
      <KBCard style={{ marginBottom: U.large }}>
        {S.sync.filter(s => s.id !== 'notif').map(s => <KBRow key={s.id} icon={syncIcon(s.id)} title={s.name} subtitle={s.desc} trailing={<KBSwitch on={sync[s.id]} onClick={() => { setSync(p => ({ ...p, [s.id]: !p[s.id] })); ping(sync[s.id] ? `${s.name} off` : `${s.name} on`); }} />} />)}
      </KBCard>
      <KBHeader>WATCH SETTINGS</KBHeader>
      <KBCard style={{ marginBottom: U.large }}>
        <KBRow icon="power" title="Quick launch · Up" trailing={<ComboKB value={ws.quickLaunchUp} />} />
        <KBRow icon="power" title="Quick launch · Down" trailing={<ComboKB value={ws.quickLaunchDown} />} />
        <KBRow icon="sun" title="Backlight" subtitle={`Timeout ${ws.backlightTimeout}s`} trailing={<KBSwitch on={ws.backlight} onClick={() => setWs(p => ({ ...p, backlight: !p.backlight }))} />} />
        <KBRow icon="sun" title="Motion backlight" subtitle="Wake on wrist flick" trailing={<KBSwitch on={ws.motionBacklight} onClick={() => setWs(p => ({ ...p, motionBacklight: !p.motionBacklight }))} />} />
      </KBCard>
      <KBCard style={{ marginBottom: U.large }}>
        <div style={{ padding: '14px 14px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13.5, fontWeight: 600 }}><span>Ambient light threshold</span><span style={{ color: KB.accent }}>{ws.ambientThreshold} lx</span></div>
          <div style={{ marginTop: 12 }}><SliderKB value={ws.ambientThreshold} min={0} max={400} onChange={v => setWs(p => ({ ...p, ambientThreshold: v }))} /></div>
        </div>
      </KBCard>
      <KBHeader>BACKUP</KBHeader>
      <KBCard style={{ marginBottom: U.large }}>
        <KBRow icon="archive" title="Backup & restore" subtitle={`${S.backup.last} · ${S.backup.size}`} trailing={<Icon name="chevron" size={16} style={{ color: KB.faint }} />} onClick={() => ping('Backup & restore…')} />
      </KBCard>
      <KBHeader>ADVANCED</KBHeader>
      <KBCard>
        {S.daemonSettings.map(dset => (
          <KBRow key={dset.key} icon="sliders" title={dset.label} subtitle={dset.desc}
            trailing={dset.type === 'toggle'
              ? <KBSwitch on={daemon[dset.key]} onClick={() => { setDaemon(p => ({ ...p, [dset.key]: !p[dset.key] })); ping(`${dset.label} ${daemon[dset.key] ? 'off' : 'on'}`); }} />
              : <ComboKB value={daemon[dset.key]} />} />
        ))}
      </KBCard>
      <div style={{ fontSize: 12, color: KB.faint, padding: '10px 6px 0', lineHeight: 1.5 }}>Daemon config, today only in <span style={{ fontFamily: 'monospace' }}>stoandl.conf</span>. Exposing it over D-Bus would let all of these be edited here.</div>
    </>);
  }
  if (tab === 'health') {
    return <HealthScreen S={S} ping={ping} />;
  }
  return null;
}

// Row overflow actions, flag-aware. System apps get no Remove (can't be removed).
function buildRowActions(item, kind, { ping, confirmRemove }) {
  if (kind === 'watch') {
    return [
      { label: 'Re-pair', icon: 'link', onClick: () => ping(`Re-pairing ${item.name}…`) },
      { label: 'Rename…', icon: 'file', onClick: () => ping('Rename watch') },
      { label: 'Forget watch', icon: 'trash', danger: true, onClick: () => confirmRemove(item, 'watch') },
    ];
  }
  if (kind === 'ext') {
    return [
      { label: 'Configure…', icon: 'sliders', onClick: () => ping(`Opening ${item.name} settings…`) },
      { label: item.running ? 'Restart' : 'Start', icon: 'refresh', onClick: () => ping(`${item.running ? 'Restarted' : 'Started'} ${item.name}`) },
      { label: 'Uninstall', icon: 'trash', danger: true, onClick: () => confirmRemove(item, 'ext') },
    ];
  }
  const sys = item.flags.includes('system');
  const cfg = item.flags.includes('config');
  const acts = [{ label: 'Launch on watch', icon: 'play', onClick: () => ping(`Launching ${item.name}…`) }];
  if (kind === 'face' && !item.flags.includes('active')) acts.push({ label: 'Set as active face', icon: 'star', onClick: () => ping(`${item.name} set active`) });
  if (cfg) acts.push({ label: 'Configure…', icon: 'sliders', onClick: () => ping(`Opening ${item.name} config…`) });
  if (!sys) acts.push({ label: 'Remove', icon: 'trash', danger: true, onClick: () => confirmRemove(item, kind) });
  return acts;
}

// Overflow menu: bottom sheet on mobile, centered popup on desktop (Kirigami ActionMenu analogue).
function RowMenu({ title, actions, variant, onClose }) {
  const isMobile = variant === 'mobile';
  return (
    <div onClick={onClose} style={{ position: 'absolute', inset: 0, zIndex: 42, background: 'rgba(0,0,0,0.5)', display: 'flex', alignItems: isMobile ? 'flex-end' : 'center', justifyContent: 'center', padding: isMobile ? 0 : 18, animation: 'kbfade .12s ease' }}>
      <div onClick={e => e.stopPropagation()} style={{ width: isMobile ? '100%' : 290, background: KB.card, borderRadius: isMobile ? '14px 14px 0 0' : 8, border: `1px solid ${KB.sep}`, boxShadow: '0 -8px 40px rgba(0,0,0,0.5)', overflow: 'hidden', paddingBottom: isMobile ? 8 : 6 }}>
        {isMobile && <div style={{ width: 36, height: 4, borderRadius: 2, background: 'rgba(255,255,255,0.2)', margin: '9px auto 4px' }} />}
        <div style={{ fontSize: 12.5, fontWeight: 700, color: KB.dim, padding: '10px 18px 8px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{title}</div>
        {actions.map((a, i) => (
          <div key={i} onClick={() => { onClose(); a.onClick && a.onClick(); }} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '12px 18px', cursor: 'pointer', color: a.danger ? KB.danger : KB.text }}>
            <Icon name={a.icon} size={19} stroke={1.9} style={{ color: a.danger ? KB.danger : KB.dim }} />
            <span style={{ fontSize: 14.5, fontWeight: 500 }}>{a.label}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function ConfirmDialog({ title, body, confirmLabel, onConfirm, onClose }) {
  return (
    <div onClick={onClose} style={{ position: 'absolute', inset: 0, zIndex: 46, background: 'rgba(0,0,0,0.55)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 18, animation: 'kbfade .12s ease' }}>
      <div onClick={e => e.stopPropagation()} style={{ width: '100%', maxWidth: 300, background: KB.card, borderRadius: 8, border: `1px solid ${KB.sep}`, boxShadow: '0 16px 50px rgba(0,0,0,0.6)', overflow: 'hidden' }}>
        <div style={{ padding: '18px 18px 14px' }}>
          <div style={{ fontSize: 16, fontWeight: 700, marginBottom: 8 }}>{title}</div>
          <div style={{ fontSize: 13, color: KB.dim, lineHeight: 1.55 }}>{body}</div>
        </div>
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, padding: '12px 14px', borderTop: `1px solid ${KB.sep}` }}>
          <KBBtn onClick={onClose}>Cancel</KBBtn>
          <KBBtn solid tone="danger" onClick={() => { onClose(); onConfirm(); }}>{confirmLabel}</KBBtn>
        </div>
      </div>
    </div>
  );
}

// Shared menu/confirm state for both form factors.
function useRowMenus(ping) {
  const [menu, setMenu] = React.useState(null);
  const [confirm, setConfirm] = React.useState(null);
  const confirmRemove = (item, kind) => setConfirm(
    kind === 'watch'
      ? { title: `Forget ${item.name}?`, body: 'This unpairs the watch from this host. You can pair it again later.', confirmLabel: 'Forget', onConfirm: () => ping(`Forgot ${item.name}`) }
      : kind === 'ext'
      ? { title: `Uninstall ${item.name}?`, body: 'Stops the extension and removes its files. Its configuration is kept so you can reinstall later.', confirmLabel: 'Uninstall', onConfirm: () => ping(`Uninstalled ${item.name}`) }
      : { title: `Remove ${item.name}?`, body: `This removes ${item.name} from the watch’s locker. You can reinstall it later.`, confirmLabel: 'Remove', onConfirm: () => ping(`Removed ${item.name}`) }
  );
  const openMenu = (item, kind) => setMenu({ title: kind === 'watch' ? `${item.name} · ${item.code}` : item.name, actions: buildRowActions(item, kind, { ping, confirmRemove }) });  return { menu, confirm, openMenu, confirmRemove, closeMenu: () => setMenu(null), closeConfirm: () => setConfirm(null) };
}

// Per-screen header actions (toolbar buttons — NOT a FAB).
function headerActions(tab, ping, onPair, seg) {
  switch (tab) {
    case 'watch': return [{ label: 'Pair new watch', icon: 'plus', primary: true, onClick: onPair }, { label: 'Ring', icon: 'bell', onClick: () => ping('Ringing watch…') }];
    case 'apps': return seg === 'ext'
      ? [{ label: 'Install extension', icon: 'plus', primary: true, onClick: () => ping('Choose archive…') }]
      : [{ label: 'Install .pbw', icon: 'plus', primary: true, onClick: () => ping('Choose a .pbw…') }];
    case 'notif': return [{ label: 'Add filter', icon: 'plus', primary: true, onClick: () => ping('New notification filter…') }];
    case 'settings': return [{ label: 'Sync all', icon: 'sync', onClick: () => ping('Syncing all…') }];
    default: return [];
  }
}

// ── Health charts ──────────────────────────────────────────────────────
function fmtMin(m) { return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, '0')}m`; }
function fmtSteps(n) { return n.toLocaleString('en-US'); }

function Ring({ value, size = 66, stroke = 7, color = KB.accent, label, sub }) {
  const r = (size - stroke) / 2, c = 2 * Math.PI * r;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ flex: '0 0 auto' }}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="rgba(255,255,255,0.12)" strokeWidth={stroke} />
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round"
        strokeDasharray={c} strokeDashoffset={c * (1 - Math.min(1, value / 100))} transform={`rotate(-90 ${size / 2} ${size / 2})`} />
      <text x="50%" y="48%" dominantBaseline="middle" textAnchor="middle" fill={KB.text} fontSize={size * 0.26} fontWeight="700" fontFamily={KB.font}>{label}</text>
      {sub && <text x="50%" y="66%" dominantBaseline="middle" textAnchor="middle" fill={KB.dim} fontSize={size * 0.13} fontFamily={KB.font}>{sub}</text>}
    </svg>
  );
}

function WeekBars({ values, labels, goal, color, todayIndex, height = 96, fmt = String }) {
  const present = values.filter(v => v != null);
  const max = Math.max(goal || 0, ...present, 1) * 1.14;
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 8, height, position: 'relative' }}>
        {goal != null && (
          <div style={{ position: 'absolute', left: 0, right: 0, bottom: `${(goal / max) * 100}%`, borderTop: `1px dashed ${KB.faint}`, pointerEvents: 'none' }}>
            <span style={{ position: 'absolute', right: 0, top: -15, fontSize: 9.5, color: KB.faint, fontWeight: 600 }}>goal {fmt(goal)}</span>
          </div>
        )}
        {values.map((v, i) => {
          const empty = v == null;
          const h = empty ? 0 : Math.max(3, (v / max) * height);
          const isToday = i === todayIndex;
          return (
            <div key={i} style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', height: '100%' }}>
              <div style={{ height: h, borderRadius: 4, background: empty ? 'rgba(255,255,255,0.07)' : isToday ? color : `${color}66`, transition: 'height .3s' }} title={empty ? '—' : fmt(v)} />
            </div>
          );
        })}
      </div>
      <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
        {labels.map((l, i) => <div key={i} style={{ flex: 1, textAlign: 'center', fontSize: 10.5, fontWeight: i === todayIndex ? 700 : 500, color: i === todayIndex ? KB.text : KB.faint }}>{l[0]}</div>)}
      </div>
    </div>
  );
}

function Sparkline({ data, color, height = 56, min, max }) {
  const lo = min != null ? min : Math.min(...data);
  const hi = max != null ? max : Math.max(...data);
  const span = hi - lo || 1;
  const n = data.length;
  const pts = data.map((v, i) => [(i / (n - 1)) * 100, height - ((v - lo) / span) * (height - 6) - 3]);
  const line = pts.map((p, i) => `${i ? 'L' : 'M'}${p[0].toFixed(2)} ${p[1].toFixed(2)}`).join(' ');
  const area = `${line} L100 ${height} L0 ${height} Z`;
  const id = 'sg' + color.replace(/[^a-z0-9]/gi, '');
  return (
    <svg width="100%" height={height} viewBox={`0 0 100 ${height}`} preserveAspectRatio="none" style={{ display: 'block' }}>
      <defs><linearGradient id={id} x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stopColor={color} stopOpacity="0.35" /><stop offset="100%" stopColor={color} stopOpacity="0" /></linearGradient></defs>
      <path d={area} fill={`url(#${id})`} />
      <path d={line} fill="none" stroke={color} strokeWidth="2" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
    </svg>
  );
}

function StatTile({ value, label }) {
  return (
    <div style={{ flex: 1, textAlign: 'center' }}>
      <div style={{ fontSize: 16, fontWeight: 700, color: KB.text }}>{value}</div>
      <div style={{ fontSize: 11, color: KB.dim, marginTop: 1 }}>{label}</div>
    </div>
  );
}
function Trend({ pct }) {
  const up = pct >= 0;
  return <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, fontSize: 12, fontWeight: 700, color: up ? KB.good : KB.warn }}>
    <span style={{ fontSize: 13 }}>{up ? '↑' : '↓'}</span>{Math.abs(pct)}%</span>;
}

const SLEEP_C = { deep: '#7d5fff', light: '#3daee9', rem: '#1abc9c' };

function HealthScreen({ S, ping }) {
  const H = S.health;
  const stepsPct = Math.round(H.steps.today / H.steps.goal * 100);
  const sl = H.sleep;
  const sleepParts = [['Deep', sl.deepMin, SLEEP_C.deep], ['Light', sl.lightMin, SLEEP_C.light], ['REM', sl.remMin, SLEEP_C.rem]];
  return (<>
    {/* Today summary */}
    <KBCard style={{ marginBottom: U.large }}>
      <div style={{ padding: '16px 14px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
          <Ring value={stepsPct} size={72} color={KB.accent} label={`${stepsPct}%`} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 24, fontWeight: 700, lineHeight: 1 }}>{fmtSteps(H.steps.today)}</div>
            <div style={{ fontSize: 12, color: KB.dim, marginTop: 3 }}>of {fmtSteps(H.steps.goal)} steps today</div>
          </div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 16, paddingTop: 14, borderTop: `1px solid ${KB.sep}` }}>
          <StatTile value={`${H.steps.distanceKm} km`} label="Distance" />
          <StatTile value={H.steps.kcal} label="Calories" />
          <StatTile value={`${H.steps.activeMin} min`} label="Active" />
        </div>
      </div>
    </KBCard>

    {/* Steps week */}
    <KBHeader>STEPS · THIS WEEK</KBHeader>
    <KBCard style={{ marginBottom: U.large }}>
      <div style={{ padding: '16px 14px 14px' }}>
        <WeekBars values={H.steps.week} labels={H.days} goal={H.steps.goal} color={KB.accent} todayIndex={H.todayIndex} fmt={fmtSteps} />
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 14, paddingTop: 12, borderTop: `1px solid ${KB.sep}` }}>
          <span style={{ fontSize: 12.5, color: KB.dim }}>Daily avg <b style={{ color: KB.text }}>{fmtSteps(H.steps.lastWeekAvg)}</b></span>
          <span style={{ fontSize: 12.5, color: KB.dim, display: 'inline-flex', gap: 6, alignItems: 'center' }}><Trend pct={H.steps.trendPct} /> vs last week</span>
        </div>
      </div>
    </KBCard>

    {/* Sleep */}
    <KBHeader>SLEEP · LAST NIGHT</KBHeader>
    <KBCard style={{ marginBottom: U.large }}>
      <div style={{ padding: '16px 14px 14px' }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ fontSize: 24, fontWeight: 700 }}>{fmtMin(sl.totalMin)}</span>
          <span style={{ fontSize: 12, color: KB.dim }}>asleep</span>
        </div>
        {/* stacked bar */}
        <div style={{ display: 'flex', height: 12, borderRadius: 6, overflow: 'hidden', marginTop: 12, gap: 2 }}>
          {sleepParts.map(([n, m, c]) => <div key={n} style={{ width: `${m / sl.totalMin * 100}%`, background: c }} title={`${n} ${fmtMin(m)}`} />)}
        </div>
        <div style={{ display: 'flex', gap: 14, marginTop: 10 }}>
          {sleepParts.map(([n, m, c]) => (
            <div key={n} style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <span style={{ width: 8, height: 8, borderRadius: 2, background: c }} />
              <span style={{ fontSize: 11.5, color: KB.dim }}>{n} <b style={{ color: KB.text }}>{fmtMin(m)}</b></span>
            </div>
          ))}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 14, paddingTop: 12, borderTop: `1px solid ${KB.sep}` }}>
          <span style={{ fontSize: 12.5, color: KB.dim }}>Weekly avg <b style={{ color: KB.text }}>{fmtMin(sl.avgMin)}</b></span>
          <span style={{ fontSize: 12.5, color: KB.dim, display: 'inline-flex', gap: 6, alignItems: 'center' }}><Trend pct={sl.trendPct} /> vs last week</span>
        </div>
      </div>
    </KBCard>

    {/* Heart rate */}
    <KBHeader>HEART RATE</KBHeader>
    <KBCard>
      <div style={{ padding: '16px 14px 14px' }}>
        <div style={{ display: 'flex', alignItems: 'flex-end', gap: 18 }}>
          <div><div style={{ fontSize: 24, fontWeight: 700, color: '#e84a5f' }}>{H.heart.resting}<span style={{ fontSize: 13, color: KB.dim, fontWeight: 500 }}> bpm</span></div><div style={{ fontSize: 11, color: KB.dim, marginTop: 1 }}>Resting</div></div>
          <div><div style={{ fontSize: 17, fontWeight: 700 }}>{H.heart.current}<span style={{ fontSize: 12, color: KB.dim, fontWeight: 500 }}> bpm</span></div><div style={{ fontSize: 11, color: KB.dim, marginTop: 1 }}>Now</div></div>
        </div>
        <div style={{ marginTop: 14 }}><Sparkline data={H.heart.day} color="#e84a5f" /></div>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 6, fontSize: 11, color: KB.faint }}>
          <span>24h · min {H.heart.min}</span><span>max {H.heart.max} bpm</span>
        </div>
      </div>
    </KBCard>
  </>);
}

// ── Notifications screen ───────────────────────────────────────────────
function NotificationsScreen({ S, ping }) {
  const N = S.notifications;
  const [forward, setForward] = React.useState(N.forward);
  const [muted, setMuted] = React.useState(N.mutedUntil);
  const [quiet, setQuiet] = React.useState(N.quietHours.on);
  const [quietNow, setQuietNow] = React.useState(null);
  const [apps, setApps] = React.useState(() => Object.fromEntries(N.apps.map(a => [a.name, { on: a.on, muted: a.muted, vibe: a.vibe, allowQuiet: false, tempMute: null }])));
  const [detail, setDetail] = React.useState(null);   // app name → deeper view
  const snoozes = [['30 min', '30 minutes'], ['1 hr', '1 hour'], ['Today', 'the rest of today']];
  const setApp = (name, patch) => setApps(p => ({ ...p, [name]: { ...p[name], ...patch } }));

  // ── Per-app deeper settings ──
  if (detail) {
    const a = apps[detail];
    const meta = N.apps.find(x => x.name === detail);
    return (<>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: U.large }}>
        <button style={iconBtnKB} onClick={() => setDetail(null)}><Icon name="back" size={22} style={{ color: KB.text }} /></button>
        <span style={{ fontSize: 17, fontWeight: 700 }}>{detail}</span>
      </div>
      <KBCard style={{ marginBottom: U.large }}>
        <KBRow icon="bell" iconColor={a.on ? KB.accent : KB.dim} title="Notifications" subtitle={a.on ? 'Forwarded to watch' : 'Off'}
          trailing={<KBSwitch on={a.on} onClick={() => setApp(detail, { on: !a.on })} />} />
        <div style={{ padding: '12px 14px', borderTop: `1px solid ${KB.sep}` }}>
          <div style={{ fontSize: 12.5, fontWeight: 700, color: KB.dim, marginBottom: 8 }}>{a.tempMute ? `Muted for ${a.tempMute}` : 'Mute temporarily'}</div>
          <div style={{ display: 'flex', gap: 8 }}>
            {a.tempMute
              ? <KBBtn onClick={() => { setApp(detail, { tempMute: null }); ping(`${detail} unmuted`); }}>Resume</KBBtn>
              : snoozes.map(([s, full]) => <KBBtn key={s} onClick={() => { setApp(detail, { tempMute: full }); ping(`${detail} muted for ${full}`); }}>{s}</KBBtn>)}
          </div>
        </div>
      </KBCard>
      <KBHeader>VIBRATION</KBHeader>
      <KBCard style={{ marginBottom: U.large }}>
        {N.vibePatterns.map(v => (
          <KBRow key={v} icon="power" iconColor={a.vibe === v ? KB.accent : KB.dim} title={v}
            onClick={() => { setApp(detail, { vibe: v }); ping(`Vibration · ${v}`); }}
            trailing={a.vibe === v ? <Icon name="check" size={18} stroke={2.4} style={{ color: KB.accent }} /> : null} />
        ))}
      </KBCard>
      <KBHeader>OPTIONS</KBHeader>
      <KBCard>
        <KBRow icon="star" title="Custom icon" subtitle="Glyph shown on the watch" trailing={<ComboKB value="Default" />} onClick={() => ping('Choose icon…')} />
        <KBRow icon="bell" title="Allow during quiet hours" subtitle="High-priority override" trailing={<KBSwitch on={a.allowQuiet} onClick={() => setApp(detail, { allowQuiet: !a.allowQuiet })} />} />
      </KBCard>
    </>);
  }

  return (<>
    {/* Master + temp mute */}
    <KBCard style={{ marginBottom: U.large }}>
      <KBRow icon="bell" iconColor={forward ? KB.accent : KB.dim} title="Forward notifications" subtitle="Send phone notifications to the watch"
        trailing={<KBSwitch on={forward} onClick={() => { setForward(v => !v); ping(forward ? 'Notifications paused' : 'Notifications on'); }} />} />
      <div style={{ padding: '12px 14px', borderTop: `1px solid ${KB.sep}` }}>
        <div style={{ fontSize: 12.5, fontWeight: 700, color: KB.dim, marginBottom: 8 }}>{muted ? `Muted for ${muted}` : 'Mute temporarily'}</div>
        <div style={{ display: 'flex', gap: 8 }}>
          {muted
            ? <KBBtn onClick={() => { setMuted(null); ping('Mute cleared'); }}>Resume now</KBBtn>
            : snoozes.map(([s, full]) => <KBBtn key={s} onClick={() => { setMuted(full); ping(`Muted for ${full}`); }}>{s}</KBBtn>)}
        </div>
      </div>
    </KBCard>

    {/* Per-app */}
    <KBHeader>PER-APP</KBHeader>
    <KBCard style={{ marginBottom: U.large }}>
      {N.apps.map(a => (
        <KBRow key={a.name} icon={a.icon} iconColor={apps[a.name].on ? KB.accent : KB.dim} title={a.name}
          subtitle={!apps[a.name].on ? 'Off' : apps[a.name].tempMute ? `Muted · ${apps[a.name].tempMute}` : `Vibration · ${apps[a.name].vibe}`}
          onClick={() => setDetail(a.name)}
          trailing={<div style={{ display: 'flex', alignItems: 'center', gap: 6 }} onClick={e => e.stopPropagation()}>
            <KBSwitch on={apps[a.name].on} onClick={() => setApp(a.name, { on: !apps[a.name].on })} />
            <Icon name="chevron" size={16} style={{ color: KB.faint }} />
          </div>} />
      ))}
    </KBCard>

    {/* Quiet hours + quiet now */}
    <KBHeader>QUIET HOURS</KBHeader>
    <KBCard style={{ marginBottom: U.large }}>
      <KBRow icon="power" title="Scheduled quiet hours" subtitle={`${N.quietHours.from} – ${N.quietHours.to}`}
        trailing={<KBSwitch on={quiet} onClick={() => setQuiet(v => !v)} />} />
      <div style={{ padding: '12px 14px', borderTop: `1px solid ${KB.sep}` }}>
        <div style={{ fontSize: 12.5, fontWeight: 700, color: KB.dim, marginBottom: 8 }}>{quietNow ? `Quiet until ${quietNow}` : 'Quiet now'}</div>
        <div style={{ display: 'flex', gap: 8 }}>
          {quietNow
            ? <KBBtn onClick={() => { setQuietNow(null); ping('Quiet time ended'); }}>End</KBBtn>
            : [['1 hr', 'in 1 hour'], ['Morning', '07:00']].map(([s, full]) => <KBBtn key={s} onClick={() => { setQuietNow(full); ping(`Quiet until ${full}`); }}>{s}</KBBtn>)}
        </div>
      </div>
    </KBCard>

    {/* Filters */}
    <KBHeader>FILTERS</KBHeader>
    <KBCard>
      {N.filters.map((f, i) => (
        <KBRow key={i} icon="search" iconColor={f.action === 'block' ? KB.danger : KB.good}
          title={f.pattern} subtitle={f.action === 'block' ? 'Block matching' : 'Always allow'}
          trailing={<button style={iconBtnKB} onClick={() => ping('Edit filter')}><Icon name="kebab" size={17} style={{ color: KB.faint }} /></button>} />
      ))}
      <KBRow icon="plus" iconColor={KB.accent} title="Add regex filter" onClick={() => ping('New notification filter…')} />
    </KBCard>
    <div style={{ fontSize: 12, color: KB.faint, padding: '10px 6px 0', lineHeight: 1.5, fontFamily: 'monospace' }}>Filters use regex on the notification title + body. Block hides; allow overrides quiet hours.</div>
  </>);
}

// Watch details (opened by tapping the connected-watch card). Holds the hardware
// facts that used to live in the inline HARDWARE list.
const WATCH_LANGS = [
  { id: 'en_US', name: 'English (US)' }, { id: 'de_DE', name: 'Deutsch' },
  { id: 'fr_FR', name: 'Français' }, { id: 'es_ES', name: 'Español' }, { id: 'ja_JP', name: '日本語' },
];

function WatchInfo({ S, variant, onClose, ping, onForget }) {
  const isMobile = variant === 'mobile';
  const [view, setView] = React.useState('main');
  const [lang, setLang] = React.useState(S.language.current);
  // close-then-run for terminal actions
  const run = (fn) => { onClose(); fn && fn(); };
  const [devConn, setDevConn] = React.useState(false);
  const mainActions = [
    { label: 'Capture screenshot', icon: 'camera', onClick: () => run(() => ping('Screenshot saved')) },
    { label: 'Check for updates', icon: 'refresh', onClick: () => run(() => ping('Checking for firmware…')) },
    { label: 'Debug…', icon: 'sliders', sub: true, onClick: () => setView('debug') },
    { label: 'Forget watch', icon: 'trash', danger: true, onClick: () => run(() => onForget && onForget()) },
  ];
  const debugActions = [
    { label: 'Core dump', icon: 'download', onClick: () => run(() => ping('Core dump captured')) },
    { label: 'Pull watch logs', icon: 'file', onClick: () => run(() => ping('Pulling logs…')) },
    { label: 'Support bundle', icon: 'archive', onClick: () => run(() => ping('Building support bundle…')) },
    { label: 'Reboot to recovery (PRF)', icon: 'refresh', onClick: () => run(() => ping('Rebooting to recovery…')) },
    { label: 'Write notification', icon: 'bell', disabled: true, onClick: () => {} },
    { label: 'Factory reset', icon: 'alert', danger: true, onClick: () => run(() => ping('Factory reset sent')) },
  ];
  // Detail rows. Firmware row gets a permanent "What's new" link; Language row is tappable → picker.
  const fwLabel = lang; // unused guard
  const list = view === 'debug' ? debugActions : mainActions;
  const headerTitle = view === 'debug' ? 'Debug' : view === 'language' ? 'Watch language' : null;
  return (
    <div onClick={onClose} style={{ position: 'absolute', inset: 0, zIndex: 44, background: 'rgba(0,0,0,0.55)', display: 'flex', alignItems: isMobile ? 'flex-end' : 'center', justifyContent: 'center', padding: isMobile ? 0 : 18, animation: 'kbfade .12s ease' }}>
      <div onClick={e => e.stopPropagation()} style={{ width: isMobile ? '100%' : 320, background: KB.card, borderRadius: isMobile ? '14px 14px 0 0' : 8, border: `1px solid ${KB.sep}`, boxShadow: '0 -8px 40px rgba(0,0,0,0.5)', overflow: 'hidden', paddingBottom: isMobile ? 8 : 0 }}>
        {isMobile && <div style={{ width: 36, height: 4, borderRadius: 2, background: 'rgba(255,255,255,0.2)', margin: '9px auto 2px' }} />}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '14px 16px', borderBottom: `1px solid ${KB.sep}` }}>
          {headerTitle
            ? <><button style={iconBtnKB} onClick={() => setView('main')}><Icon name="back" size={20} style={{ color: KB.text }} /></button><div style={{ flex: 1, fontSize: 15.5, fontWeight: 700 }}>{headerTitle}</div></>
            : <><WatchGlyph size={34} accent={KB.accent} /><div style={{ flex: 1, minWidth: 0 }}><div style={{ display: 'flex', alignItems: 'center', gap: 7 }}><span style={{ fontSize: 15.5, fontWeight: 700 }}>{S.watch.name} · {S.watch.code}</span><button style={{ ...iconBtnKB, padding: 2 }} title="Rename" onClick={() => ping('Rename — needs daemon support')}><Icon name="edit" size={15} style={{ color: KB.dim }} /></button></div><div style={{ fontSize: 11.5, color: KB.good, fontWeight: 600, marginTop: 1 }}>● Connected</div></div></>}
          <button style={iconBtnKB} onClick={onClose}><Icon name="x" size={18} style={{ color: KB.dim }} /></button>
        </div>

        {view === 'main' && (<>
          <div style={{ padding: '6px 16px 4px' }}>
            {[['Model', S.watch.model], ['Platform', S.watch.platform], ['Transport', S.watch.transport]].map(([k, v]) => (
              <div key={k} style={{ display: 'flex', justifyContent: 'space-between', padding: '9px 0', borderBottom: `1px solid ${KB.sep}`, fontSize: 13.5 }}>
                <span style={{ color: KB.dim }}>{k}</span><span style={{ fontWeight: 600 }}>{v}</span>
              </div>
            ))}
            {/* Firmware row + permanent What's new link */}
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '9px 0', borderBottom: `1px solid ${KB.sep}`, fontSize: 13.5 }}>
              <span style={{ color: KB.dim }}>Firmware</span>
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
                <span style={{ fontWeight: 600 }}>{S.watch.firmware}</span>
                <button onClick={() => window.open(S.firmware.changelogUrl, '_blank', 'noopener')} style={{ background: 'none', border: 'none', color: KB.accent, cursor: 'pointer', padding: 0, fontFamily: KB.font, fontSize: 12, fontWeight: 700, display: 'inline-flex', alignItems: 'center', gap: 3 }}><Icon name="link" size={13} stroke={2.2} />What’s new</button>
              </span>
            </div>
            {[['Serial', S.watch.serial], ['Battery', `${S.watch.battery}%`], ['Last sync', S.watch.lastSync]].map(([k, v]) => (
              <div key={k} style={{ display: 'flex', justifyContent: 'space-between', padding: '9px 0', borderBottom: `1px solid ${KB.sep}`, fontSize: 13.5 }}>
                <span style={{ color: KB.dim }}>{k}</span><span style={{ fontWeight: 600, fontFamily: k === 'Serial' ? 'monospace' : KB.font }}>{v}</span>
              </div>
            ))}
            {/* Developer connection — toggle */}
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '9px 0', borderBottom: `1px solid ${KB.sep}`, fontSize: 13.5 }}>
              <span style={{ color: KB.dim }}>Developer connection</span>
              <KBSwitch on={devConn} onClick={() => { setDevConn(v => !v); ping(devConn ? 'Developer connection stopped' : 'Developer connection · listening'); }} />
            </div>
            {/* Language — watch-specific, tappable → picker */}
            <div onClick={() => setView('language')} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 0 9px', fontSize: 13.5, cursor: 'pointer' }}>
              <span style={{ color: KB.dim }}>Language</span>
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontWeight: 600 }}>{lang}<Icon name="chevron" size={15} style={{ color: KB.faint }} /></span>
            </div>
          </div>
          <div style={{ padding: '6px 8px 6px', borderTop: `1px solid ${KB.sep}` }}>
            {mainActions.map((a, i) => (
              <div key={i} onClick={a.disabled ? undefined : a.onClick} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '11px 12px', cursor: 'pointer', borderRadius: 6, color: a.danger ? KB.danger : KB.text }}>
                <Icon name={a.icon} size={19} stroke={1.9} style={{ color: a.danger ? KB.danger : KB.dim }} />
                <span style={{ fontSize: 14, fontWeight: 500, flex: 1 }}>{a.label}</span>
                {a.sub && <Icon name="chevron" size={16} style={{ color: KB.faint }} />}
              </div>
            ))}
          </div>
        </>)}

        {view === 'debug' && (<>
          <div style={{ fontSize: 12, color: KB.faint, padding: '12px 18px 4px', lineHeight: 1.5 }}>Low-level tools for diagnostics and recovery. Use with care.</div>
          <div style={{ padding: '6px 8px 6px' }}>
            {debugActions.map((a, i) => (
              <div key={i} onClick={a.disabled ? undefined : a.onClick} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '11px 12px', cursor: a.disabled ? 'default' : 'pointer', borderRadius: 6, color: a.disabled ? KB.faint : a.danger ? KB.danger : KB.text, opacity: a.disabled ? 0.6 : 1 }}>
                <Icon name={a.icon} size={19} stroke={1.9} style={{ color: a.disabled ? KB.faint : a.danger ? KB.danger : KB.dim }} />
                <span style={{ fontSize: 14, fontWeight: 500, flex: 1 }}>{a.label}</span>
                {a.disabled && <span style={{ fontSize: 10, fontWeight: 700, color: KB.faint, border: `1px solid ${KB.faint}`, borderRadius: 3, padding: '1px 5px' }}>SOON</span>}
              </div>
            ))}
          </div>
        </>)}

        {view === 'language' && (<>
          <div style={{ fontSize: 12, color: KB.faint, padding: '12px 18px 4px', lineHeight: 1.5 }}>Load a language pack onto the watch. The current one is marked.</div>
          <div style={{ padding: '6px 8px 8px' }}>
            {WATCH_LANGS.map(L => {
              const active = lang.startsWith(L.id) || lang === L.name;
              return (
                <div key={L.id} onClick={() => { setLang(`${L.name} (${L.id})`); ping(active ? `${L.name} already loaded` : `Loading ${L.name} onto watch…`); setTimeout(onClose, 300); }}
                  style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '11px 12px', cursor: 'pointer', borderRadius: 6, color: KB.text }}>
                  <Icon name="globe" size={19} stroke={1.9} style={{ color: active ? KB.accent : KB.dim }} />
                  <span style={{ fontSize: 14, fontWeight: 500, flex: 1 }}>{L.name} <span style={{ color: KB.faint, fontSize: 12 }}>· {L.id}</span></span>
                  {active && <Icon name="check" size={17} stroke={2.4} style={{ color: KB.accent }} />}
                </div>
              );
            })}
          </div>
        </>)}
      </div>
    </div>
  );
}

function ComboKB({ value }) { return <span style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 13.5, color: KB.dim }}>{value}<Icon name="chevron" size={14} style={{ transform: 'rotate(90deg)' }} /></span>; }
function SliderKB({ value, min, max, onChange }) {
  const ref = React.useRef(null);
  const pct = (value - min) / (max - min);
  const set = (x) => { const r = ref.current.getBoundingClientRect(); onChange(Math.round((Math.min(1, Math.max(0, (x - r.left) / r.width)) * (max - min) + min) / 10) * 10); };
  return (
    <div ref={ref} onPointerDown={e => { e.currentTarget.setPointerCapture(e.pointerId); set(e.clientX); }} onPointerMove={e => { if (e.buttons) set(e.clientX); }} style={{ height: 20, display: 'flex', alignItems: 'center', cursor: 'pointer', touchAction: 'none' }}>
      <div style={{ flex: 1, height: 4, borderRadius: 2, background: 'rgba(255,255,255,0.16)', position: 'relative' }}>
        <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: `${pct * 100}%`, background: KB.accent, borderRadius: 2 }} />
        <div style={{ position: 'absolute', left: `calc(${pct * 100}% - 8px)`, top: -6, width: 16, height: 16, borderRadius: 8, background: KB.accent, border: '2px solid #fff' }} />
      </div>
    </div>
  );
}
const iconBtnKB = { background: 'none', border: 'none', cursor: 'pointer', padding: 4, display: 'flex', flex: '0 0 auto' };

// Pairing dialog (shared)
function PairDialog({ phase, onClose }) {
  return (
    <div onClick={phase === 'paired' ? onClose : undefined} style={{ position: 'absolute', inset: 0, zIndex: 40, background: 'rgba(0,0,0,0.55)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 18, animation: 'kbfade .15s ease' }}>
      <div onClick={e => e.stopPropagation()} style={{ width: '100%', maxWidth: 300, background: KB.card, borderRadius: 8, border: `1px solid ${KB.sep}`, boxShadow: '0 16px 50px rgba(0,0,0,0.6)', overflow: 'hidden' }}>
        <div style={{ padding: '22px 18px 16px', textAlign: 'center' }}>
          {phase === 'searching' && <>
            <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 13 }}><KBSpinner size={34} /></div>
            <div style={{ fontSize: 16, fontWeight: 700 }}>Searching for watches</div>
            <div style={{ fontSize: 12.5, color: KB.dim, marginTop: 6, lineHeight: 1.5 }}>Put your Pebble in Bluetooth range. A ~2-minute window is open.</div>
          </>}
          {phase === 'confirm' && <>
            <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 8 }}><WatchGlyph size={42} accent={KB.accent} /></div>
            <div style={{ fontSize: 15.5, fontWeight: 700 }}>Confirm on your watch</div>
            <div style={{ fontSize: 12.5, color: KB.dim, marginTop: 6 }}>Does the watch show this code?</div>
            <div style={{ fontSize: 30, fontWeight: 700, letterSpacing: 4, margin: '12px 0 4px', color: KB.accent }}>814 372</div>
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, marginTop: 8, color: KB.dim, fontSize: 12 }}><KBSpinner size={14} stroke={2} /> Waiting…</div>
          </>}
          {phase === 'paired' && <>
            <div style={{ width: 46, height: 46, borderRadius: 23, margin: '0 auto 12px', background: 'rgba(39,174,96,0.18)', color: KB.good, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon name="check" size={26} stroke={2.6} /></div>
            <div style={{ fontSize: 16, fontWeight: 700 }}>Paired</div>
            <div style={{ fontSize: 12.5, color: KB.dim, marginTop: 6 }}>Pebble Time 2 is connected and syncing your locker.</div>
          </>}
        </div>
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, padding: '12px 14px', borderTop: `1px solid ${KB.sep}` }}>
          {phase === 'paired' ? <KBBtn solid onClick={onClose}>Done</KBBtn> : <KBBtn onClick={onClose}>Cancel</KBBtn>}
        </div>
      </div>
    </div>
  );
}

function usePairing() {
  const [phase, setPhase] = React.useState(null);
  const timers = React.useRef([]);
  const start = () => { timers.current.forEach(clearTimeout); setPhase('searching'); timers.current = [setTimeout(() => setPhase('confirm'), 1500), setTimeout(() => setPhase('paired'), 4300)]; };
  const close = () => { timers.current.forEach(clearTimeout); setPhase(null); };
  return { phase, start, close };
}

// ═══════════ MOBILE ═══════════ (bottom NavigationTabBar, header actions)
function KdeMobile() {
  const st = useStoState();
  const [tab, setTab] = React.useState('watch');
  const [toast, setToast] = React.useState(null);
  const pair = usePairing();
  const ping = (m) => { setToast(m); clearTimeout(window.__kbm); window.__kbm = setTimeout(() => setToast(null), 2000); };
  const rm = useRowMenus(ping);
  const [info, setInfo] = React.useState(false);
  const actions = headerActions(tab, ping, pair.start, st.seg);
  const primary = actions.find(a => a.primary);
  const secondary = actions.filter(a => !a.primary);

  return (
    <PhoneFrame bg={KB.win}>
      <div style={{ display: 'flex', flexDirection: 'column', height: '100%', fontFamily: KB.font, color: KB.text, position: 'relative' }}>
        <StatusBar />
        {/* Header toolbar — title + actions (HIG: toolbar; actions live here, not a FAB) */}
        <div style={{ height: 50, flex: '0 0 50px', background: KB.header, display: 'flex', alignItems: 'center', padding: '0 8px 0 16px', borderBottom: `1px solid ${KB.sep}`, gap: 4 }}>
          <div style={{ flex: 1, fontSize: 18, fontWeight: 700 }}>{TITLES[tab]}</div>
          {secondary.map(a => <button key={a.label} onClick={a.onClick} title={a.label} style={iconBtnHdr}><Icon name={a.icon} size={20} /></button>)}
          {primary && <button onClick={primary.onClick} title={primary.label} style={{ ...iconBtnHdr, color: KB.accent }}><Icon name={primary.icon} size={22} stroke={2.2} /></button>}
        </div>
        {/* Content */}
        <div style={{ flex: 1, overflowY: 'auto', padding: `${U.large}px ${U.large - 4}px ${U.large + 6}px` }}>
          <ScreenBody tab={tab} st={st} ping={ping} onPair={pair.start} onMenu={rm.openMenu} goTo={setTab} onInfo={() => setInfo(true)} onRemove={rm.confirmRemove} />
        </div>
        {/* Toast */}
        <div style={{ position: 'absolute', left: 14, right: 14, bottom: 66, zIndex: 8, display: 'flex', justifyContent: 'center', pointerEvents: 'none', opacity: toast ? 1 : 0, transform: toast ? 'translateY(0)' : 'translateY(8px)', transition: 'opacity .2s, transform .2s' }}>
          {toast && <div style={{ background: '#0d0f11', color: '#fff', borderRadius: 6, padding: '9px 14px', fontSize: 12.5, fontWeight: 500, boxShadow: '0 4px 16px rgba(0,0,0,0.5)', border: `1px solid ${KB.sep}` }}>{toast}</div>}
        </div>
        {/* NavigationTabBar — BELOW content on mobile (HIG) */}
        <div style={{ flex: '0 0 auto', display: 'flex', background: KB.header, borderTop: `1px solid ${KB.sep}`, padding: '4px 2px 7px' }}>
          {NAV.map(([k, icon, label]) => {
            const on = tab === k;
            return (
              <button key={k} onClick={() => setTab(k)} style={{ flex: 1, background: 'none', border: 'none', cursor: 'pointer', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, padding: '5px 0 3px', color: on ? KB.accent : KB.dim, position: 'relative' }}>
                <div style={{ width: 40, height: 3, borderRadius: 2, background: on ? KB.accent : 'transparent', position: 'absolute', top: 0 }} />
                <Icon name={icon} size={21} stroke={on ? 2.2 : 1.8} />
                <span style={{ fontSize: 10.5, fontWeight: on ? 700 : 600 }}>{label}</span>
              </button>
            );
          })}
        </div>
        {pair.phase && <PairDialog phase={pair.phase} onClose={pair.close} />}
        {rm.menu && <RowMenu {...rm.menu} variant="mobile" onClose={rm.closeMenu} />}
        {rm.confirm && <ConfirmDialog {...rm.confirm} onClose={rm.closeConfirm} />}
        {info && <WatchInfo S={st.S} variant="mobile" ping={ping} onClose={() => setInfo(false)} onForget={() => rm.confirmRemove(st.S.watch, 'watch')} />}
      </div>
    </PhoneFrame>
  );
}

// ═══════════ DESKTOP ═══════════ (top NavigationTabBar, centered constrained content)
function KdeDesktop({ width = 940, height = 640 }) {
  const st = useStoState();
  const [tab, setTab] = React.useState('watch');
  const [toast, setToast] = React.useState(null);
  const pair = usePairing();
  const ping = (m) => { setToast(m); clearTimeout(window.__kbd); window.__kbd = setTimeout(() => setToast(null), 2000); };
  const rm = useRowMenus(ping);
  const [info, setInfo] = React.useState(false);
  const actions = headerActions(tab, ping, pair.start, st.seg);

  return (
    <div style={{ width, height, background: KB.win, borderRadius: 10, overflow: 'hidden', boxShadow: '0 30px 80px rgba(0,0,0,0.45)', display: 'flex', flexDirection: 'column', fontFamily: KB.font, color: KB.text, position: 'relative' }}>
      {/* Window titlebar (Breeze) */}
      <div style={{ height: 38, flex: '0 0 38px', background: KB.header, display: 'flex', alignItems: 'center', padding: '0 12px', borderBottom: `1px solid ${KB.sep}` }}>
        <span style={{ flex: 1, textAlign: 'center', fontSize: 13, fontWeight: 600, color: KB.dim }}>stoandl — Pebble Manager</span>
        <div style={{ display: 'flex', gap: 7 }}>
          {[['power', null], ['plus', null], ['x', '#fff']].map(([n, c], i) => (
            <span key={i} style={{ width: 20, height: 20, borderRadius: 10, background: 'rgba(255,255,255,0.08)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: c || 'rgba(255,255,255,0.55)' }}>
              <svg width="9" height="9" viewBox="0 0 10 10">{i === 0 ? <rect x="1" y="5" width="8" height="1.3" rx="0.6" fill="currentColor" /> : i === 1 ? <rect x="1.5" y="1.5" width="7" height="7" rx="1" stroke="currentColor" strokeWidth="1.2" fill="none" /> : <path d="M2 2l6 6M8 2l-6 6" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />}</svg>
            </span>
          ))}
        </div>
      </div>
      {/* NavigationTabBar — ABOVE content on desktop (HIG) */}
      <div style={{ flex: '0 0 auto', display: 'flex', alignItems: 'center', justifyContent: 'center', background: KB.header, borderBottom: `1px solid ${KB.sep}`, padding: '6px 8px', gap: 4 }}>
        {NAV.map(([k, icon, label]) => {
          const on = tab === k;
          return (
            <button key={k} onClick={() => setTab(k)} style={{ display: 'flex', alignItems: 'center', gap: 8, background: on ? KB.accentDim : 'transparent', border: 'none', borderRadius: U.radius, cursor: 'pointer', color: on ? KB.accent : KB.dim, padding: '8px 16px', fontSize: 13.5, fontWeight: on ? 700 : 600, fontFamily: KB.font }}>
              <Icon name={icon} size={18} stroke={on ? 2.2 : 1.8} />{label}
            </button>
          );
        })}
      </div>
      {/* Content header: section title + actions toolbar (HIG: toolbar above content) */}
      <div style={{ flex: '0 0 auto', display: 'flex', alignItems: 'center', padding: '14px 22px 0', maxWidth: 720, width: '100%', margin: '0 auto' }}>
        <div style={{ flex: 1, fontSize: 22, fontWeight: 700 }}>{TITLES[tab]}</div>
        <div style={{ display: 'flex', gap: 8 }}>
          {actions.map(a => <KBBtn key={a.label} solid={a.primary} icon={a.icon} onClick={a.onClick}>{a.label}</KBBtn>)}
        </div>
      </div>
      {/* Centered constrained content column */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '16px 0 26px' }}>
        <div style={{ maxWidth: 720, margin: '0 auto', padding: '0 22px' }}>
          <ScreenBody tab={tab} st={st} ping={ping} onPair={pair.start} onMenu={rm.openMenu} goTo={setTab} onInfo={() => setInfo(true)} onRemove={rm.confirmRemove} />
        </div>
      </div>
      <div style={{ position: 'absolute', left: 0, right: 0, bottom: 20, display: 'flex', justifyContent: 'center', pointerEvents: 'none', opacity: toast ? 1 : 0, transform: toast ? 'translateY(0)' : 'translateY(8px)', transition: 'opacity .2s, transform .2s' }}>
        {toast && <div style={{ background: '#0d0f11', color: '#fff', borderRadius: 6, padding: '9px 16px', fontSize: 13, fontWeight: 500, boxShadow: '0 4px 16px rgba(0,0,0,0.5)', border: `1px solid ${KB.sep}` }}>{toast}</div>}
      </div>
      {pair.phase && <PairDialog phase={pair.phase} onClose={pair.close} />}
      {rm.menu && <RowMenu {...rm.menu} variant="desktop" onClose={rm.closeMenu} />}
      {rm.confirm && <ConfirmDialog {...rm.confirm} onClose={rm.closeConfirm} />}
      {info && <WatchInfo S={st.S} variant="desktop" ping={ping} onClose={() => setInfo(false)} onForget={() => rm.confirmRemove(st.S.watch, 'watch')} />}
    </div>
  );
}

const iconBtnHdr = { background: 'none', border: 'none', color: KB.text, cursor: 'pointer', padding: 8, display: 'flex', borderRadius: 5 };

// ── Empty / error states (Kirigami.PlaceholderMessage analogue) ─────────
function Placeholder({ icon, iconColor, title, body, primary, secondary, mono }) {
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center', padding: '0 34px' }}>
      <div style={{ width: 78, height: 78, borderRadius: 39, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(255,255,255,0.05)', marginBottom: 20, color: iconColor || KB.faint }}>
        <Icon name={icon} size={40} stroke={1.6} />
      </div>
      <div style={{ fontSize: 18, fontWeight: 700, color: KB.text }}>{title}</div>
      <div style={{ fontSize: 13.5, color: KB.dim, marginTop: 9, lineHeight: 1.55, maxWidth: 250 }}>{body}</div>
      {primary && <div style={{ marginTop: 22 }}><KBBtn solid icon={primary.icon} onClick={primary.onClick}>{primary.label}</KBBtn></div>}
      {secondary && <button onClick={secondary.onClick} style={{ marginTop: 12, background: 'none', border: 'none', color: KB.accent, fontFamily: KB.font, fontSize: 13, fontWeight: 600, cursor: 'pointer' }}>{secondary.label}</button>}
      {mono && <div style={{ marginTop: 20, background: KB.view, border: `1px solid ${KB.sep}`, borderRadius: 6, padding: '10px 13px', fontFamily: 'monospace', fontSize: 11.5, color: KB.dim }}><span style={{ color: KB.faint }}>$ </span><span style={{ color: KB.text }}>{mono}</span></div>}
    </div>
  );
}

// Phone shell for a state: status bar + header + body (+ optional bottom nav).
function StateShell({ title, children, nav = true, headerAction }) {
  return (
    <PhoneFrame bg={KB.win}>
      <div style={{ display: 'flex', flexDirection: 'column', height: '100%', fontFamily: KB.font, color: KB.text }}>
        <StatusBar />
        <div style={{ height: 50, flex: '0 0 50px', background: KB.header, display: 'flex', alignItems: 'center', padding: '0 8px 0 16px', borderBottom: `1px solid ${KB.sep}` }}>
          <div style={{ flex: 1, fontSize: 18, fontWeight: 700 }}>{title}</div>
          {headerAction}
        </div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>{children}</div>
        {nav && (
          <div style={{ flex: '0 0 auto', display: 'flex', background: KB.header, borderTop: `1px solid ${KB.sep}`, padding: '4px 2px 7px' }}>
            {NAV.map(([k, icon, label], i) => (
              <div key={k} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, padding: '5px 0 3px', color: i === 0 ? KB.accent : KB.dim, position: 'relative' }}>
                <div style={{ width: 40, height: 3, borderRadius: 2, background: i === 0 ? KB.accent : 'transparent', position: 'absolute', top: 0 }} />
                <Icon name={icon} size={21} stroke={i === 0 ? 2.2 : 1.8} />
                <span style={{ fontSize: 10.5, fontWeight: i === 0 ? 700 : 600 }}>{label}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </PhoneFrame>
  );
}

// Daemon not running — bus name unowned. No nav (nothing works without the daemon).
function StateDaemonDown() {
  return (
    <StateShell title="stoandl" nav={false}>
      <Placeholder icon="alert" iconColor={KB.warn}
        title="Daemon not running"
        body="The stoandl service isn’t on the session bus. Start it to manage your watch."
        primary={{ label: 'Start daemon', icon: 'power' }} secondary={{ label: 'Retry connection' }}
        mono="systemctl --user start stoandl" />
    </StateShell>
  );
}
// No watch connected (status kind = notready). Daemon up → nav visible.
function StateNoWatch() {
  return (
    <StateShell title="Watch" headerAction={<button style={iconBtnHdr}><Icon name="sync" size={20} /></button>}>
      <Placeholder icon="watch"
        title="No watch connected"
        body="Pair a Pebble or connect a known one. The daemon is running and ready."
        primary={{ label: 'Pair new watch', icon: 'plus' }} secondary={{ label: 'Connect a known watch' }} />
    </StateShell>
  );
}
// Bluetooth adapter off.
function StateBluetoothOff() {
  return (
    <StateShell title="Watch">
      <Placeholder icon="bluetooth" iconColor={KB.danger}
        title="Bluetooth is off"
        body="stoandl needs Bluetooth to reach your watch. Turn it on to reconnect."
        primary={{ label: 'Enable Bluetooth', icon: 'bluetooth' }} secondary={{ label: 'Open system settings' }} />
    </StateShell>
  );
}
// Reconnecting (transient, after reset / fw reboot).
function StateConnecting() {
  return (
    <StateShell title="Watch">
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center', padding: '0 34px' }}>
        <div style={{ marginBottom: 20 }}><KBSpinner size={40} /></div>
        <div style={{ fontSize: 18, fontWeight: 700 }}>Connecting…</div>
        <div style={{ fontSize: 13.5, color: KB.dim, marginTop: 9, lineHeight: 1.55, maxWidth: 250 }}>Reconnecting to Time Steel · B349. Normal right after a reboot or firmware flash.</div>
      </div>
    </StateShell>
  );
}

Object.assign(window, { KdeMobile, KdeDesktop, StateDaemonDown, StateNoWatch, StateBluetoothOff, StateConnecting });
