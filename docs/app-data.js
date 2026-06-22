// Shared data model for the stoandl mobile UI — mirrors the stoandl CLI surface.
// Plain JS, attached to window so every direction renders the same content.

window.STO = {
  // ── Active + known watches ──────────────────────────────────────────
  watch: {
    name: 'Time Steel',
    code: 'B349',
    model: 'Pebble Time Steel',
    platform: 'BASALT',
    transport: 'Bluetooth Classic',
    connected: true,
    battery: 72,
    charging: false,
    firmware: '4.4.2',
    lastSync: '2 min ago',
    serial: 'Q402445E00GR',
    board: 'snowy_s3',
  },
  knownWatches: [
    { name: 'Time Steel', code: 'B349', model: 'Pebble Time Steel', connected: true, battery: 72, transport: 'BT Classic' },
    { name: 'Time 2', code: 'A1F0', model: 'Pebble Time 2', connected: false, battery: 41, transport: 'BLE' },
  ],

  // ── Locker: watchfaces + apps ───────────────────────────────────────
  faces: [
    { name: 'Tic Toc', flags: ['active', 'system'], uuid: '8f3c8985' },
    { name: 'Isotime', flags: [], uuid: '3af56a2b' },
    { name: 'Beam Up', flags: [], uuid: 'd2cd8de2' },
    { name: 'Kalk', flags: ['config'], uuid: '5e5da3f1' },
  ],
  apps: [
    { name: 'Music', flags: ['system'], uuid: '1f03293d' },
    { name: 'Notifications', flags: ['system'], uuid: 'b2cae152' },
    { name: 'Health', flags: ['system'], uuid: '36d8c6ed' },
    { name: 'Settings', flags: ['system'], uuid: '07e0d9cb' },
    { name: 'Pebblemap', flags: ['sideloaded', 'config'], uuid: 'a4d3f0b9' },
    { name: 'Tezel', flags: ['sideloaded'], uuid: 'c91b77a0' },
  ],

  // ── Extensions (host-side companion apps) ───────────────────────────
  extensions: [
    { name: 'Matrix', desc: 'Messages on the wrist + canned replies, E2EE', enabled: true, running: true, lang: 'Python' },
    { name: 'Find My Phone', desc: 'Ring this device from the watch', enabled: true, running: true, lang: 'Python' },
    { name: 'Signal', desc: 'Signal messages + quick replies', enabled: false, running: false, lang: 'Python' },
    { name: 'SMS Bridge', desc: 'Forward & reply to SMS over ModemManager', enabled: false, running: false, lang: 'Rust' },
  ],

  // ── Sync services ───────────────────────────────────────────────────
  sync: [
    { id: 'notif', name: 'Notifications', desc: 'Forward desktop notifications', on: true },
    { id: 'weather', name: 'Weather', desc: 'Open-Meteo · sunrise/sunset pins', on: true },
    { id: 'calendar', name: 'Calendar', desc: 'Timeline pins · 3 calendars', on: true },
    { id: 'music', name: 'Music (MPRIS)', desc: 'Now-playing + transport control', on: true },
    { id: 'health', name: 'Health', desc: 'Steps & sleep activity data', on: false },
  ],

  // ── Advanced watch settings ─────────────────────────────────────────
  watchSettings: {
    quickLaunchUp: 'Music',
    quickLaunchDown: 'Pebblemap',
    backlight: true,
    backlightTimeout: 3,
    ambientThreshold: 200,
    motionBacklight: true,
  },

  // ── System / firmware / tools ───────────────────────────────────────
  firmware: { current: '4.4.2', latest: '4.4.3', updateAvailable: true, channel: 'PebbleOS', changelogUrl: 'https://ndocs.repebble.com/PebbleOS-Changelog-25efbb55ea84801da04bfcf73c9346e1' },
  language: { current: 'English (en_US)', installed: true },
  backup: { last: 'Yesterday, 18:40', size: '4.2 MB' },

  // ── Daemon config (stoandl.conf) — ideally exposed over D-Bus, schema-driven ──
  daemonSettings: [
    { key: 'units', label: 'Units', type: 'combo', value: 'Metric', options: ['Metric', 'Imperial'] },
    { key: 'weather_provider', label: 'Weather provider', type: 'combo', value: 'Open-Meteo', options: ['Open-Meteo'] },
    { key: 'auto_reconnect', label: 'Reconnect automatically', type: 'toggle', value: true, desc: 'Reconnect when the watch comes back in range' },
    { key: 'calendar_window', label: 'Timeline window', type: 'combo', value: '3 days', options: ['1 day', '3 days', '7 days'] },
    { key: 'log_level', label: 'Log level', type: 'combo', value: 'info', options: ['error', 'info', 'debug'] },
  ],

  // ── Notifications ───────────────────────────────────────────────────
  notifications: {
    forward: true,
    mutedUntil: null,            // null | 'snooze' label
    quietHours: { on: true, from: '23:00', to: '07:00' },
    apps: [
      { name: 'Signal', icon: 'bell', on: true, vibe: 'Double', muted: false },
      { name: 'Matrix', icon: 'bell', on: true, vibe: 'Standard', muted: false },
      { name: 'Gmail', icon: 'bell', on: true, vibe: 'Subtle', muted: false },
      { name: 'Phone', icon: 'bell', on: true, vibe: 'Long', muted: false },
      { name: 'Calendar', icon: 'calendar', on: false, vibe: 'Standard', muted: true },
    ],
    filters: [
      { pattern: '(?i)verification code', action: 'allow' },
      { pattern: 'Slack: .* is typing', action: 'block' },
    ],
    vibePatterns: ['Standard', 'Double', 'Long', 'Subtle', 'Heartbeat'],
  },

  // ── Health (steps / sleep / heart rate) ─────────────────────────────
  health: {
    days: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
    todayIndex: 4,
    steps: { today: 7432, goal: 10000, distanceKm: 5.4, kcal: 312, activeMin: 52,
      week: [6210, 8140, 5390, 9320, 7432, null, null], lastWeekAvg: 6890, trendPct: 8 },
    sleep: { totalMin: 444, deepMin: 108, lightMin: 252, remMin: 84, awakeMin: 0,
      week: [408, 432, 366, 474, 444, null, null], avgMin: 426, lastWeekAvgMin: 402, trendPct: 6 },
    heart: { resting: 58, current: 72, min: 54, max: 121,
      day: [60, 58, 57, 59, 61, 64, 70, 88, 95, 79, 72, 68, 66, 64, 70, 82, 90, 78, 71, 66, 61, 58, 57, 60] },
  },
};
