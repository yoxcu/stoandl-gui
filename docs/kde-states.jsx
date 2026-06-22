/* Shared empty / error / loading states for the KDE (by-the-book) direction.
   These are the cross-screen states CLAUDE.md mandates but the happy-path
   screens don't show. Each renders inside the same PhoneFrame + Breeze chrome
   so Code has 1:1 pixel targets. Uses BRZ + FormCard primitives from dir-kde.jsx.

   States covered:
   1. daemon-down        — bus name de.yoxcu.stoandl unowned
   2. notready           — daemon up, no watch / libpebble not ready
   3. connecting         — transient, reconnecting after reset/reboot
   4. list-empty         — a screen's list legitimately has 0 rows
   5. list-loading       — first poll in flight (skeleton)
   6. action-error       — a call returned kind=error (inline banner)
*/

// Generic Breeze page scaffold: status bar + header + body, optional tab bar.
function KdeShell({ title, children, footer = true, action }) {
  const B = window.BRZ;
  const tabs = [['watch', 'Watch'], ['apps', 'Apps'], ['puzzle', 'Plugins'], ['sliders', 'Sync'], ['tools', 'System']];
  return (
    <PhoneFrame bg={B.win}>
      <div style={{ display: 'flex', flexDirection: 'column', height: '100%', fontFamily: B.font, color: B.text, position: 'relative' }}>
        <StatusBar />
        <div style={{ height: 50, flex: '0 0 50px', background: B.head, display: 'flex', alignItems: 'center', padding: '0 6px 0 14px', borderBottom: `1px solid ${B.div}` }}>
          <div style={{ flex: 1, fontSize: 18, fontWeight: 700 }}>{title}</div>
          {action}
        </div>
        <div style={{ flex: 1, overflowY: 'auto', display: 'flex', flexDirection: 'column' }}>{children}</div>
        {footer && (
          <div style={{ flex: '0 0 auto', display: 'flex', background: B.head, borderTop: `1px solid ${B.div}`, padding: '4px 2px 7px' }}>
            {tabs.map(([icon, label], i) => {
              const on = i === 0;
              return (
                <div key={label} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, padding: '5px 0 3px', color: on ? B.accent : B.dim, position: 'relative' }}>
                  <div style={{ width: 40, height: 4, borderRadius: 2, background: on ? B.accent : 'transparent', position: 'absolute', top: 0 }} />
                  <Icon name={icon} size={21} stroke={on ? 2.2 : 1.8} />
                  <span style={{ fontSize: 10.5, fontWeight: on ? 700 : 600 }}>{label}</span>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </PhoneFrame>
  );
}

// Centered "placeholder message" — Kirigami.PlaceholderMessage analogue.
function Placeholder({ icon, iconColor, title, body, primary, secondary, spinner }) {
  const B = window.BRZ;
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center', padding: '0 34px' }}>
      <div style={{ width: 76, height: 76, borderRadius: 38, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(255,255,255,0.05)', marginBottom: 20, color: iconColor || B.faint }}>
        {spinner ? <Spinner size={40} /> : <Icon name={icon} size={38} stroke={1.6} />}
      </div>
      <div style={{ fontSize: 18, fontWeight: 700, color: B.text }}>{title}</div>
      <div style={{ fontSize: 13.5, color: B.dim, marginTop: 9, lineHeight: 1.55, maxWidth: 240 }}>{body}</div>
      {primary && (
        <button onClick={primary.onClick} style={{ display: 'inline-flex', alignItems: 'center', gap: 7, marginTop: 22, background: B.accent, color: '#06151d', border: 'none', borderRadius: 6, padding: '10px 18px', fontFamily: B.font, fontSize: 14, fontWeight: 700, cursor: 'pointer' }}>
          {primary.icon && <Icon name={primary.icon} size={17} stroke={2.3} />}{primary.label}
        </button>
      )}
      {secondary && (
        <button onClick={secondary.onClick} style={{ marginTop: 12, background: 'none', border: 'none', color: B.accent, fontFamily: B.font, fontSize: 13, fontWeight: 600, cursor: 'pointer' }}>{secondary.label}</button>
      )}
    </div>
  );
}

// 1 · Daemon down — bus name unowned. Highest-priority state per CLAUDE.md.
function StateDaemonDown() {
  const B = window.BRZ;
  return (
    <KdeShell title="stoandl">
      <Placeholder icon="alert" iconColor={B.warn}
        title="Daemon not running"
        body={<>The <code style={{ fontFamily: 'monospace', color: B.text }}>stoandl</code> service isn’t on the session bus. Start it to manage your watch.</>}
        primary={{ label: 'Start daemon', icon: 'power' }}
        secondary={{ label: 'Retry connection' }} />
      <div style={{ flex: '0 0 auto', padding: '0 22px 22px' }}>
        <div style={{ background: B.view, border: `1px solid ${B.div}`, borderRadius: 7, padding: '11px 13px', fontFamily: 'monospace', fontSize: 11.5, color: B.dim, display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ color: B.faint }}>$</span><span style={{ color: B.text }}>systemctl --user start stoandl</span>
        </div>
      </div>
    </KdeShell>
  );
}

// 2 · Not ready — daemon up, no watch connected (status kind=notready).
function StateNotReady() {
  return (
    <KdeShell title="Watch" action={<button style={{ background: 'none', border: 'none', color: window.BRZ.text, cursor: 'pointer', padding: 9, display: 'flex' }}><Icon name="sync" size={20} /></button>}>
      <Placeholder icon="watch"
        title="No watch connected"
        body="Pair a Pebble or connect a known one to get started. The daemon is running and ready."
        primary={{ label: 'Pair watch', icon: 'plus' }}
        secondary={{ label: 'Connect a known watch' }} />
    </KdeShell>
  );
}

// 3 · Connecting / reconnecting — transient (e.g. after a reset or fw reboot).
function StateConnecting() {
  return (
    <KdeShell title="Watch">
      <Placeholder spinner
        title="Connecting…"
        body="Reconnecting to Time Steel · B349. This is normal right after a reboot or firmware flash." />
    </KdeShell>
  );
}

// 4 · Empty list — a screen with 0 rows (here: Plugins, none installed).
function StateListEmpty() {
  const B = window.BRZ;
  return (
    <KdeShell title="Extensions">
      <Placeholder icon="puzzle"
        title="No extensions yet"
        body="Extensions are host-side companions that add notifications, replies and actions. Install one to begin."
        primary={{ label: 'Install extension', icon: 'plus' }} />
    </KdeShell>
  );
}

// 5 · Loading skeleton — first poll in flight, before any list data.
function StateLoading() {
  const B = window.BRZ;
  const Row = () => (
    <div style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '13px 14px' }}>
      <div style={{ width: 32, height: 32, borderRadius: 6, background: 'rgba(255,255,255,0.07)', flex: '0 0 auto' }} />
      <div style={{ flex: 1 }}>
        <div style={{ height: 11, width: '55%', borderRadius: 4, background: 'rgba(255,255,255,0.09)' }} />
        <div style={{ height: 9, width: '34%', borderRadius: 4, background: 'rgba(255,255,255,0.05)', marginTop: 7 }} />
      </div>
    </div>
  );
  return (
    <KdeShell title="Apps & Faces">
      <div style={{ padding: 14 }}>
        <div style={{ height: 36, borderRadius: 7, background: 'rgba(255,255,255,0.05)', marginBottom: 16 }} />
        <div style={{ background: B.card, borderRadius: 8, border: `1px solid ${B.div}`, overflow: 'hidden' }}>
          {[0, 1, 2, 3].map(i => <React.Fragment key={i}>{i > 0 && <div style={{ height: 1, background: B.div, marginLeft: 14 }} />}<Row /></React.Fragment>)}
        </div>
        <div style={{ display: 'flex', justifyContent: 'center', marginTop: 22, opacity: 0.7 }}><Spinner size={22} /></div>
      </div>
    </KdeShell>
  );
}

// 6 · Action error — a call returned kind=error; inline dismissible banner
//     over otherwise-normal content (NOT a blocking dialog).
function StateActionError() {
  const B = window.BRZ;
  return (
    <KdeShell title="Apps & Faces">
      <div style={{ padding: 14 }}>
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 11, background: 'rgba(218,68,83,0.12)', border: `1px solid rgba(218,68,83,0.45)`, borderRadius: 7, padding: '12px 13px', marginBottom: 16 }}>
          <Icon name="alert" size={19} style={{ color: B.danger, flex: '0 0 auto', marginTop: 1 }} />
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13.5, fontWeight: 700, color: B.text }}>Couldn’t install watchface</div>
            <div style={{ fontSize: 12, color: B.dim, marginTop: 3, lineHeight: 1.5 }}>error: incompatible platform — this .pbw targets APLITE, watch is BASALT.</div>
            <div style={{ display: 'flex', gap: 16, marginTop: 9 }}>
              <button style={{ background: 'none', border: 'none', color: B.accent, fontFamily: B.font, fontSize: 12.5, fontWeight: 700, cursor: 'pointer', padding: 0 }}>Retry</button>
              <button style={{ background: 'none', border: 'none', color: B.dim, fontFamily: B.font, fontSize: 12.5, fontWeight: 600, cursor: 'pointer', padding: 0 }}>Dismiss</button>
            </div>
          </div>
        </div>
        <window.FormCard>
          <window.FormDelegate icon="star" iconTone={B.accent} title="Tic Toc" subtitle="8f3c8985" trailing={<window.BChip tone="active">active</window.BChip>} />
          <window.FormDelegate icon="watch" iconTone={B.dim} title="Isotime" subtitle="3af56a2b" />
        </window.FormCard>
      </div>
    </KdeShell>
  );
}

Object.assign(window, { KdeShell, Placeholder, StateDaemonDown, StateNotReady, StateConnecting, StateListEmpty, StateLoading, StateActionError });
