/* Shared icon set + phone frame for the stoandl mobile UI directions. */

const STROKE_ICONS = {
  watch: 'M9 3h6l.5 4M9 21h6l.5-4M6.5 7A7 7 0 0 1 17.5 7M6.5 17A7 7 0 0 0 17.5 17 M12 8v4l2.5 1.5',
  apps: 'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z',
  puzzle: 'M10 4a1.5 1.5 0 0 1 3 0c0 .8.6 1 1 1h2a1 1 0 0 1 1 1v2c0 .4.2 1 1 1a1.5 1.5 0 0 1 0 3c-.8 0-1 .6-1 1v2a1 1 0 0 1-1 1h-2c-.4 0-1 .2-1 1a1.5 1.5 0 0 1-3 0c0-.8-.6-1-1-1H6a1 1 0 0 1-1-1v-2c0-.4-.2-1-1-1a1.5 1.5 0 0 1 0-3c.8 0 1-.6 1-1V6a1 1 0 0 1 1-1h3c.4 0 1-.2 1-1z',
  sliders: 'M4 7h10M18 7h2M4 17h2M10 17h10M14 4v6M8 14v6',
  tools: 'M14.5 5.5a3.5 3.5 0 0 0-4.6 4.3L4 15.7 8.3 20l5.9-5.9a3.5 3.5 0 0 0 4.3-4.6l-2.3 2.3-2.1-.6-.6-2.1z',
  battery: 'M3 8h15v8H3zM21 11v2',
  bluetooth: 'M7 7l10 10-5 4V3l5 4L7 17',
  chevron: 'M9 6l6 6-6 6',
  back: 'M15 6l-6 6 6 6',
  check: 'M5 12.5l4.5 4.5L19 7',
  plus: 'M12 5v14M5 12h14',
  sync: 'M20 11A8 8 0 0 0 6 6L4 8M4 13a8 8 0 0 0 14 5l2-2M4 5v3h3M20 19v-3h-3',
  download: 'M12 4v11M7 11l5 5 5-5M5 20h14',
  search: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4',
  menu: 'M4 7h16M4 12h16M4 17h16',
  kebab: 'M12 5v.01M12 12v.01M12 19v.01',
  play: 'M7 5l11 7-11 7z',
  music: 'M9 18V6l11-2v12M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0zM20 16a3 3 0 1 1-6 0 3 3 0 0 1 6 0z',
  sun: 'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM12 2v2M12 20v2M4 12H2M22 12h-2M5 5l1.5 1.5M17.5 17.5L19 19M19 5l-1.5 1.5M6.5 17.5L5 19',
  calendar: 'M5 5h14v14H5zM5 9h14M9 3v4M15 3v4',
  bell: 'M7 9a5 5 0 0 1 10 0c0 5 2 6 2 6H5s2-1 2-6zM10 19a2 2 0 0 0 4 0',
  power: 'M12 4v8M7 7a7 7 0 1 0 10 0',
  trash: 'M5 7h14M9 7V5h6v2M6 7l1 13h10l1-13',
  info: 'M12 8v.01M11 12h1v4h1M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z',
  globe: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.5 2.5 15 0 18M12 3c-2.5 2.5-2.5 15 0 18',
  archive: 'M4 7h16v3H4zM5 10v9h14v-9M10 14h4',
  camera: 'M4 8h3l1.5-2h7L17 8h3v11H4zM12 16a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
  file: 'M6 3h8l4 4v14H6zM14 3v4h4M9 13h6M9 17h6',
  alert: 'M12 4l9 16H3zM12 10v4M12 17v.01',
  star: 'M12 4l2.3 4.7 5.2.8-3.8 3.7.9 5.2L12 16.7 7.4 18.4l.9-5.2L4.5 9.5l5.2-.8z',
  x: 'M6 6l12 12M18 6L6 18',
  link: 'M9 15l6-6M8 11l-2 2a3 3 0 0 0 4 4l2-2M16 13l2-2a3 3 0 0 0-4-4l-2 2',
  edit: 'M4 20h4L18.5 9.5l-4-4L4 16zM13.5 6.5l4 4',
  heart: 'M12 20s-7-4.3-7-9a4 4 0 0 1 7-2.6A4 4 0 0 1 19 11c0 4.7-7 9-7 9z',
  refresh: 'M4 5v3h3M20 19v-3h-3M5.5 8A7 7 0 0 1 19 9M18.5 16A7 7 0 0 1 5 15',
};

function Icon({ name, size = 22, stroke = 2, fill = 'none', className, style }) {
  const d = STROKE_ICONS[name] || '';
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill={fill === 'solid' ? 'currentColor' : 'none'}
      stroke={fill === 'solid' ? 'none' : 'currentColor'} strokeWidth={stroke} strokeLinecap="round"
      strokeLinejoin="round" className={className} style={style} aria-hidden="true">
      {d.split('M').filter(Boolean).map((seg, i) => <path key={i} d={'M' + seg} />)}
    </svg>
  );
}

// Small battery glyph with fill level.
function BatteryGlyph({ level, size = 24, color = 'currentColor' }) {
  const w = size, h = size * 0.5;
  return (
    <svg width={w} height={h} viewBox="0 0 24 12" fill="none" aria-hidden="true">
      <rect x="1" y="1" width="19" height="10" rx="2.5" stroke={color} strokeWidth="1.6" />
      <rect x="21" y="4" width="2" height="4" rx="1" fill={color} />
      <rect x="3" y="3" width={Math.max(1, 15 * level / 100)} height="6" rx="1" fill={color} />
    </svg>
  );
}

// Pebble-style watch render — rounded-rect body + simple face. Generic enough
// (rounded rect + lugs), not a branded illustration.
function WatchGlyph({ size = 120, screen = '#101317', accent = '#ff5a1f', label }) {
  return (
    <svg width={size} height={size * 1.18} viewBox="0 0 100 118" fill="none" aria-hidden="true">
      <rect x="30" y="2" width="40" height="18" rx="5" fill="#2a2d33" />
      <rect x="30" y="98" width="40" height="18" rx="5" fill="#2a2d33" />
      <rect x="14" y="16" width="72" height="86" rx="16" fill="#3a3e45" />
      <rect x="20" y="22" width="60" height="74" rx="11" fill={screen} />
      <rect x="27" y="34" width="46" height="6" rx="3" fill={accent} opacity="0.9" />
      <rect x="27" y="46" width="34" height="4" rx="2" fill="#ffffff" opacity="0.5" />
      <rect x="27" y="68" width="46" height="14" rx="3" fill="#ffffff" opacity="0.12" />
    </svg>
  );
}

// ── Phone frame: mobile-Linux device bezel ─────────────────────────────
// screenW/H are the inner screen; the frame adds bezel. Children fill screen.
function PhoneFrame({ screenW = 300, screenH = 650, bg = '#000', children, statusBar, accent = '#fff' }) {
  return (
    <div style={{
      width: screenW + 22, height: screenH + 22, background: 'linear-gradient(160deg,#26282c,#15161a)',
      borderRadius: 38, padding: 11, boxSizing: 'border-box',
      boxShadow: 'inset 0 0 0 1.5px rgba(255,255,255,0.06)',
    }}>
      <div style={{
        width: screenW, height: screenH, background: bg, borderRadius: 28, overflow: 'hidden',
        position: 'relative', display: 'flex', flexDirection: 'column',
      }}>
        {children}
      </div>
    </div>
  );
}

// Mobile-linux status bar (time + indicators). Compact, theme-colored.
function StatusBar({ color = 'rgba(255,255,255,0.92)', dim = 'rgba(255,255,255,0.5)', battery = 86 }) {
  return (
    <div style={{
      height: 26, flex: '0 0 26px', display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      padding: '0 16px', fontSize: 12, fontWeight: 600, color, letterSpacing: 0.2,
      fontVariantNumeric: 'tabular-nums',
    }}>
      <span>9:41</span>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: dim }}>
        <Icon name="bluetooth" size={12} stroke={2.4} style={{ color }} />
        <svg width="15" height="11" viewBox="0 0 15 11" fill="none"><path d="M1 6.5a8 8 0 0 1 13 0M3.3 8.4a5 5 0 0 1 8.4 0M6 10a2 2 0 0 1 3 0" stroke={color} strokeWidth="1.3" strokeLinecap="round"/></svg>
        <BatteryGlyph level={battery} size={22} color={color} />
      </div>
    </div>
  );
}

function syncIcon(id) { return { notif: 'bell', weather: 'sun', calendar: 'calendar', music: 'music', health: 'heart' }[id] || 'sync'; }

Object.assign(window, { Icon, BatteryGlyph, WatchGlyph, PhoneFrame, StatusBar, syncIcon });
