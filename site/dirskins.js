// Direction skins for the board. Each is a real skin.json plus PNG assets drawn at load time,
// so they go through the same validator and renderer as an imported .webbyskin.
(function () {
  const L = window.WebbyLab, S = window.WebbySkins;
  if (!L || !S) return;

  function png(w, h, draw) {
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const x = c.getContext('2d'); draw(x, w, h);
    return { url: c.toDataURL('image/png'), w, h };
  }
  function rand(seed) { return () => (seed = (seed * 16807) % 2147483647) / 2147483647; }
  function grain(x, w, h, rgb, alpha, seed, density) {
    const r = rand(seed), img = x.getImageData(0, 0, w, h), d = img.data;
    for (let i = 0; i < d.length; i += 4) {
      if (r() > (density || 1)) continue;
      const a = alpha * r();
      d[i] = d[i] * (1 - a) + rgb[0] * a; d[i + 1] = d[i + 1] * (1 - a) + rgb[1] * a; d[i + 2] = d[i + 2] * (1 - a) + rgb[2] * a;
      d[i + 3] = Math.max(d[i + 3], a * 255);
    }
    x.putImageData(img, 0, 0);
  }
  const map = obj => new Map(Object.entries(obj));

  // ---------- Clear (built-in default) ----------
  L.register({ id: 'webby.clear', skin: S.CLEAR, assets: new Map(), builtIn: true, label: 'Built-in' });

  // ---------- Graphite ----------
  const graphite = {
    formatVersion: 1, id: 'webby.graphite', name: 'Graphite', author: 'Webby', version: '0.1.0',
    description: 'Quiet instrument panels: tuned near-black greys, 1 pt hairlines, mono metadata and one signal colour.',
    base: 'webby.clear', tags: ['dark', 'mono', 'pro'], appearances: ['light', 'dark'],
    palette: [
      { light: '#FAFAFA00', dark: '#16171A00' },
      { light: '#DCE4F299', dark: '#26304599' },
      { light: '#E2E0FA99', dark: '#2C2A5299' },
      { light: '#DCEBDD99', dark: '#22332899' },
      { light: '#F3E1D699', dark: '#40291F99' },
      { light: '#F6E8C299', dark: '#45361499' }
    ],
    surface: {
      fill: { light: '#FAFAFAFA', dark: '#16171AF7' }, material: 'none',
      image: { element: 'note-body', insets: { top: 8, left: 8, bottom: 8, right: 8 }, mode: 'tile', tintWithPalette: false },
      cornerRadius: 6, border: { width: 1, color: { light: '#E4E4E7', dark: '#2C2D32' } }, shadow: 'soft',
      padding: { top: 12, left: 12, bottom: 12, right: 12 },
      text: { color: { light: '#18181B', dark: '#E4E4E7' } }, placeholderColor: { light: '#71717A', dark: '#8B8B93' },
      selection: '#5E9BFF4D', caret: { light: '#2563EB', dark: '#5E9BFF' }
    },
    typography: { font: { family: 'SF Mono' }, size: 13, weight: 'regular', lineSpacing: 3 },
    header: { height: 22, showsTitle: true },
    collapsed: { height: 24, showsFirstLine: true },
    decoration: { element: 'decoration', anchor: 'bottomRight', origin: 'bottomRight', offset: { x: -5, y: -5 }, rotation: 0 },
    icons: { template: true, tint: { light: '#52525B', dark: '#8B8B93' } },
    resizeHandle: { visibility: 'hover' },
    library: { accent: { light: '#2563EB', dark: '#5E9BFF' }, sidebarMaterial: 'none', cardStyle: 'note', background: { light: '#FFFFFF', dark: '#0B0C0E' } },
    sounds: { volume: 0.4, mute: [] },
    highContrast: { 'surface.fill': { light: '#FFFFFF', dark: '#000000' }, 'surface.text.color': { light: '#000000', dark: '#FFFFFF' } }
  };
  const gBody = (dark, seed) => png(48, 48, (x, w, h) => {
    grain(x, w, h, dark ? [255, 255, 255] : [0, 0, 0], dark ? 0.05 : 0.035, seed, 0.5);
    x.fillStyle = dark ? 'rgba(255,255,255,.05)' : 'rgba(255,255,255,.9)'; x.fillRect(0, 0, w, 2);
  });
  const gHead = dark => png(44, 44, (x, w, h) => {
    x.fillStyle = dark ? '#1D1E22' : '#F1F1F3'; x.fillRect(0, 0, w, h);
    x.fillStyle = dark ? 'rgba(255,255,255,.07)' : 'rgba(0,0,0,.08)'; x.fillRect(0, h - 2, w, 2);
  });
  const gBar = dark => png(48, 48, (x, w, h) => {
    x.fillStyle = dark ? '#1D1E22' : '#F4F4F5'; x.fillRect(0, 0, w, h);
    x.fillStyle = dark ? '#5E9BFF' : '#2563EB'; x.fillRect(0, 10, 6, h - 20);
  });
  const gMarks = dark => png(32, 32, (x, w, h) => {
    x.strokeStyle = dark ? 'rgba(255,255,255,.35)' : 'rgba(0,0,0,.3)'; x.lineWidth = 2;
    x.beginPath(); x.moveTo(w - 1, h - 14); x.lineTo(w - 1, h - 1); x.lineTo(w - 14, h - 1); x.stroke();
    x.beginPath(); x.moveTo(w - 9, h - 18); x.lineTo(w - 9, h - 9); x.lineTo(w - 18, h - 9); x.stroke();
  });
  L.register({
    id: graphite.id, skin: graphite, builtIn: true, label: 'Built-in (v1.1)',
    assets: map({
      'images/note-body@2x.png': gBody(false, 11), 'images/note-body~dark@2x.png': gBody(true, 23),
      'images/note-header@2x.png': gHead(false), 'images/note-header~dark@2x.png': gHead(true),
      'images/note-collapsed@2x.png': gBar(false), 'images/note-collapsed~dark@2x.png': gBar(true),
      'images/decoration@2x.png': gMarks(false), 'images/decoration~dark@2x.png': gMarks(true)
    })
  });

  // ---------- shared helpers for pixel art and sound ----------
  const px = (x, c, X, Y, W, H) => { x.fillStyle = c; x.fillRect(X, Y, W, H); };
  function wav(fn, ms, rate) {
    rate = rate || 22050;
    const n = Math.round(rate * ms / 1000), buf = new DataView(new ArrayBuffer(44 + n * 2));
    const str = (o, t) => [...t].forEach((ch, i) => buf.setUint8(o + i, ch.charCodeAt(0)));
    str(0, 'RIFF'); buf.setUint32(4, 36 + n * 2, true); str(8, 'WAVE'); str(12, 'fmt ');
    buf.setUint32(16, 16, true); buf.setUint16(20, 1, true); buf.setUint16(22, 1, true); buf.setUint32(24, rate, true);
    buf.setUint32(28, rate * 2, true); buf.setUint16(32, 2, true); buf.setUint16(34, 16, true); str(36, 'data'); buf.setUint32(40, n * 2, true);
    const r = rand(5);
    for (let i = 0; i < n; i++) buf.setInt16(44 + i * 2, Math.max(-1, Math.min(1, fn(i / rate, r))) * 26000, true);
    return { url: URL.createObjectURL(new Blob([buf], { type: 'audio/wav' })), bytes: 44 + n * 2 };
  }
  const click = (t, r) => (r() * 2 - 1) * Math.exp(-t * 260) * 0.7 + Math.sin(t * 2 * Math.PI * 1900) * Math.exp(-t * 400) * 0.5;
  const blip = (f1, f2) => t => { const on = t < 0.04 || (t > 0.06 && t < 0.1); const f = t < 0.05 ? f1 : f2; return on ? Math.sign(Math.sin(t * 2 * Math.PI * f)) * 0.25 : 0; };

  // ---------- Desk Accessory (Retro OS) ----------
  const desk = {
    formatVersion: 1, id: 'io.github.jynlee7.desk-accessory', name: 'Desk Accessory', author: 'Webby moodboard', version: '0.1.0',
    description: 'A small desk-accessory window from the 1990s: pinstriped title bar, 1 pt outline and bevels, flat paper. Graphite in dark mode.',
    license: 'CC-BY-4.0', base: 'webby.clear', tags: ['retro', 'pixel', '1990s'], appearances: ['light', 'dark'],
    palette: [
      { light: '#FFF9CB00', dark: '#33333300' },
      { light: '#E2F0FC', dark: '#1F2F40' }, { light: '#DDDDDD', dark: '#3A3A3A' }, { light: '#DDF3D6', dark: '#22331F' },
      { light: '#F9DADA', dark: '#3B2626' }, { light: '#E6E0F7', dark: '#2B2638' }, { light: '#FDE3C8', dark: '#3B2D1F' }
    ],
    surface: {
      fill: { light: '#FFF9CB', dark: '#333333' }, material: 'none',
      image: { element: 'note-body', insets: { top: 4, left: 4, bottom: 4, right: 4 }, mode: 'stretch', tintWithPalette: false },
      cornerRadius: 0, border: { width: 0 }, shadow: 'none',
      padding: { top: 10, left: 10, bottom: 10, right: 10 },
      text: { color: { light: '#000000', dark: '#F2F2F2' } }, placeholderColor: { light: '#00000080', dark: '#F2F2F280' },
      selection: { light: '#B9D2EE', dark: '#4F8BC599' }, caret: { light: '#000000', dark: '#FFFFFF' }
    },
    typography: { font: { family: 'Geneva' }, size: 12, weight: 'regular', lineSpacing: 2 },
    header: { height: 20, showsTitle: true },
    collapsed: { height: 20, showsFirstLine: true },
    decoration: { element: 'decoration', anchor: 'bottomRight', origin: 'bottomRight', offset: { x: 0, y: 0 }, rotation: 0 },
    icons: { template: true, tint: { light: '#000000', dark: '#F2F2F2' } },
    resizeHandle: { visibility: 'never' },
    library: { accent: { light: '#3E78B2', dark: '#7FB0E0' }, sidebarMaterial: 'none', cardStyle: 'note', background: { light: '#EEEEEE', dark: '#2A2A2A' } },
    sounds: { volume: 0.5, mute: [] },
    highContrast: { 'surface.fill': { light: '#FFFFFF', dark: '#000000' }, 'surface.text.color': { light: '#000000', dark: '#FFFFFF' } }
  };
  const dBody = dark => png(24, 24, (x, w, h) => {
    px(x, dark ? '#111111' : '#000000', 0, 0, w, 2); px(x, dark ? '#111111' : '#000000', 0, h - 2, w, 2);
    px(x, dark ? '#111111' : '#000000', 0, 0, 2, h); px(x, dark ? '#111111' : '#000000', w - 2, 0, 2, h);
    px(x, dark ? '#5A585C' : '#FFFFFF', 2, 2, w - 4, 2); px(x, dark ? '#5A585C' : '#FFFFFF', 2, 2, 2, h - 4);
    px(x, dark ? '#1E1E1E' : '#757575', 2, h - 4, w - 4, 2); px(x, dark ? '#1E1E1E' : '#757575', w - 4, 2, 2, h - 4);
  });
  const stripes = (x, w, h, dark, outlineTop) => {
    for (let y = 0; y < h; y += 4) { px(x, dark ? '#4F4D50' : '#F2F2F2', 0, y, w, 2); px(x, dark ? '#444246' : '#DADADA', 0, y + 2, w, 2); }
    px(x, dark ? '#111111' : '#000000', 0, h - 2, w, 2);
    if (outlineTop) { px(x, dark ? '#111111' : '#000000', 0, 0, w, 2); px(x, dark ? '#111111' : '#000000', 0, 0, 2, h); px(x, dark ? '#111111' : '#000000', w - 2, 0, 2, h); }
  };
  const dHead = dark => png(40, 40, (x, w, h) => stripes(x, w, h, dark, false));
  const dBar = dark => png(40, 40, (x, w, h) => stripes(x, w, h, dark, true));
  const dEar = dark => png(32, 32, (x, w, h) => {
    const ink = dark ? '#111111' : '#000000';
    for (let i = 0; i < 16; i++) { px(x, dark ? '#4A4A4A' : '#E6E0B0', 32 - 2 * i, 2 * i, 2 * i, 2); }
    for (let i = 0; i < 16; i++) px(x, ink, 32 - 2 * i - 2, 2 * i, 2, 2);
    px(x, ink, 0, 30, 32, 2); px(x, ink, 30, 0, 2, 32);
  });
  const pixIcon = kind => png(36, 36, (x) => {
    const k = '#000';
    if (kind === 'close') { px(x, k, 8, 8, 20, 2); px(x, k, 8, 26, 20, 2); px(x, k, 8, 8, 2, 20); px(x, k, 26, 8, 2, 20); }
    if (kind === 'collapse') { px(x, k, 8, 8, 20, 2); px(x, k, 8, 26, 20, 2); px(x, k, 8, 8, 2, 20); px(x, k, 26, 8, 2, 20); px(x, k, 8, 14, 20, 2); px(x, k, 8, 18, 20, 2); }
    if (kind === 'expand') { px(x, k, 8, 8, 20, 2); px(x, k, 8, 26, 20, 2); px(x, k, 8, 8, 2, 20); px(x, k, 26, 8, 2, 20); px(x, k, 17, 12, 2, 12); px(x, k, 12, 17, 12, 2); }
    if (kind === 'more') { [8, 16, 24].forEach(X => px(x, k, X, 16, 4, 4)); }
  });
  L.register({
    id: desk.id, skin: desk, builtIn: true, label: 'Sample',
    assets: map({
      'images/note-body@2x.png': dBody(false), 'images/note-body~dark@2x.png': dBody(true),
      'images/note-header@2x.png': dHead(false), 'images/note-header~dark@2x.png': dHead(true),
      'images/note-collapsed@2x.png': dBar(false), 'images/note-collapsed~dark@2x.png': dBar(true),
      'images/decoration@2x.png': dEar(false), 'images/decoration~dark@2x.png': dEar(true),
      'images/icon-close@2x.png': pixIcon('close'), 'images/icon-collapse@2x.png': pixIcon('collapse'),
      'images/icon-expand@2x.png': pixIcon('expand'), 'images/icon-more@2x.png': pixIcon('more'),
      'sounds/note-create.wav': wav((t, r) => (r() * 2 - 1) * Math.exp(-t * 120) * 0.6, 70),
      'sounds/voice-start.wav': wav(blip(660, 990), 110), 'sounds/voice-stop.wav': wav(blip(990, 660), 110)
    })
  });

  // ---------- Field Instrument (Hardware) ----------
  const field = {
    formatVersion: 1, id: 'io.github.jynlee7.field-instrument', name: 'Field Instrument', author: 'Webby moodboard', version: '0.1.0',
    description: 'A small, well-made device: warm moulded housing, a recessed LCD window, printed labels and one safety-orange signal light.',
    license: 'CC-BY-4.0', base: 'webby.clear', tags: ['hardware', 'industrial', 'orange'], appearances: ['light', 'dark'],
    palette: [
      { light: '#EDEBE600', dark: '#1C1C1B00' },
      { light: '#FF6A2B', dark: '#7A2E12' }, { light: '#FFD23F', dark: '#5C4A00' }, { light: '#C9D6DF', dark: '#2A3640' },
      { light: '#D6D6D2', dark: '#3A3A38' }, { light: '#BFE3C0', dark: '#1E3B22' }
    ],
    surface: {
      fill: { light: '#EDEBE6', dark: '#1C1C1B' }, material: 'none',
      image: { element: 'note-body', insets: { top: 14, left: 14, bottom: 14, right: 14 }, mode: 'stretch', tintWithPalette: true },
      cornerRadius: 10, border: { width: 1, color: { light: '#C9C6BE', dark: '#2E2E2C' } }, shadow: 'soft',
      padding: { top: 14, left: 14, bottom: 14, right: 14 },
      text: { color: { light: '#1A1A18', dark: '#ECEBE6' } }, placeholderColor: { light: '#1A1A1880', dark: '#ECEBE680' },
      selection: '#FF5F1F47', caret: '#FF5F1F'
    },
    typography: { font: { family: 'SF Pro Text' }, size: 14, weight: 'regular', lineSpacing: 3 },
    header: { height: 24, showsTitle: false },
    collapsed: { height: 24, showsFirstLine: true },
    decoration: { element: 'decoration', anchor: 'bottomLeft', origin: 'topLeft', offset: { x: 16, y: -2 }, rotation: 0 },
    icons: { template: true, tint: { light: '#1A1A18CC', dark: '#ECEBE6CC' } },
    resizeHandle: { visibility: 'hover' },
    library: { accent: { light: '#B8410E', dark: '#FF7A3D' }, sidebarMaterial: 'none', cardStyle: 'note', background: { light: '#F4F2EE', dark: '#121211' } },
    voiceOrb: { states: { idle: { frames: 1, fps: 0 }, listening: { frames: 12, fps: 10, loop: true, audioReactive: 0.1 } } },
    sounds: { volume: 0.5, mute: [] },
    highContrast: { 'surface.fill': { light: '#FFFFFF', dark: '#000000' }, 'surface.text.color': { light: '#000000', dark: '#FFFFFF' } }
  };
  const rr = (x, X, Y, W, H, R) => { x.beginPath(); x.moveTo(X + R, Y); x.arcTo(X + W, Y, X + W, Y + H, R); x.arcTo(X + W, Y + H, X, Y + H, R); x.arcTo(X, Y + H, X, Y, R); x.arcTo(X, Y, X + W, Y, R); x.closePath(); };
  const fBody = dark => png(64, 64, (x, w, h) => {
    const g = x.createLinearGradient(0, 0, 0, h);
    g.addColorStop(0, dark ? 'rgba(255,255,255,.07)' : 'rgba(255,255,255,.75)'); g.addColorStop(.12, 'rgba(255,255,255,0)');
    g.addColorStop(.85, 'rgba(0,0,0,0)'); g.addColorStop(1, dark ? 'rgba(0,0,0,.45)' : 'rgba(0,0,0,.10)');
    rr(x, 1, 1, w - 2, h - 2, 18); x.fillStyle = g; x.fill();
    rr(x, 5, 5, w - 10, h - 10, 14); x.strokeStyle = dark ? 'rgba(255,255,255,.05)' : 'rgba(0,0,0,.05)'; x.lineWidth = 2; x.stroke();
    [[14, 14], [50, 14]].forEach(([cx, cy]) => {
      x.beginPath(); x.arc(cx, cy, 3.5, 0, 7); x.fillStyle = dark ? '#3A3A38' : '#B9B5AC'; x.fill();
      x.fillStyle = dark ? '#1C1C1B' : '#8E8A80'; x.fillRect(cx - 2.5, cy - .6, 5, 1.2);
    });
  });
  const fHead = dark => png(48, 48, (x, w, h) => {
    const g = x.createLinearGradient(0, 0, 0, h); g.addColorStop(0, dark ? '#30302E' : '#E2E2DE'); g.addColorStop(1, dark ? '#262624' : '#CFCFCA');
    x.fillStyle = g; x.fillRect(0, 0, w, h);
    const r = rand(dark ? 9 : 3); for (let y = 0; y < h; y++) { x.fillStyle = `rgba(255,255,255,${(r() * (dark ? .03 : .18)).toFixed(3)})`; x.fillRect(0, y, w, 1); }
    x.fillStyle = dark ? 'rgba(0,0,0,.5)' : 'rgba(0,0,0,.12)'; x.fillRect(0, h - 2, w, 2);
    x.beginPath(); x.arc(14, h / 2, 6, 0, 7); x.fillStyle = 'rgba(255,95,31,.25)'; x.fill();
    x.beginPath(); x.arc(14, h / 2, 3.6, 0, 7); x.fillStyle = '#FF5F1F'; x.fill();
    x.beginPath(); x.arc(13, h / 2 - 1.2, 1.2, 0, 7); x.fillStyle = 'rgba(255,255,255,.8)'; x.fill();
  });
  const fBar = dark => png(48, 48, (x, w, h) => {
    rr(x, 0, 0, w, h, 16); x.fillStyle = dark ? '#0E1210' : '#C9D6DF'; x.fill();
    const g = x.createLinearGradient(0, 0, 0, h); g.addColorStop(0, dark ? 'rgba(0,0,0,.6)' : 'rgba(30,50,70,.28)'); g.addColorStop(.25, 'rgba(0,0,0,0)');
    rr(x, 0, 0, w, h, 16); x.fillStyle = g; x.fill();
    rr(x, 1, 1, w - 2, h - 2, 15); x.strokeStyle = dark ? 'rgba(255,255,255,.08)' : 'rgba(255,255,255,.6)'; x.lineWidth = 2; x.stroke();
  });
  // 5x7 dot font for the spec plate
  const DOTS = { N: ['10001', '11001', '10101', '10011', '10001', '10001', '10001'], O: ['01110', '10001', '10001', '10001', '10001', '10001', '01110'], T: ['11111', '00100', '00100', '00100', '00100', '00100', '00100'], E: ['11111', '10000', '10000', '11110', '10000', '10000', '11111'], '-': ['00000', '00000', '00000', '01110', '00000', '00000', '00000'], 0: ['01110', '10001', '10011', '10101', '11001', '10001', '01110'], 1: ['00100', '01100', '00100', '00100', '00100', '00100', '01110'] };
  const fPlate = dark => png(144, 48, (x, w, h) => {
    rr(x, 1, 1, w - 2, h - 2, 8); x.fillStyle = dark ? '#2E2E2C' : '#D6D6D2'; x.fill();
    x.strokeStyle = dark ? 'rgba(255,255,255,.12)' : 'rgba(0,0,0,.18)'; x.lineWidth = 2; x.stroke();
    [[10, h / 2], [w - 10, h / 2]].forEach(([cx, cy]) => { x.beginPath(); x.arc(cx, cy, 3, 0, 7); x.fillStyle = dark ? '#1C1C1B' : '#A9A59C'; x.fill(); });
    let cx = 24; x.fillStyle = dark ? '#ECEBE6' : '#1A1A18';
    [...'NOTE-01'].forEach(ch => { const g = DOTS[ch]; g.forEach((row, ry) => [...row].forEach((b, rx) => { if (b === '1') { x.beginPath(); x.arc(cx + rx * 3.2, 13 + ry * 3.2, 1.2, 0, 7); x.fill(); } })); cx += 5 * 3.2 + 4; });
    x.fillStyle = '#B8410E'; x.fillRect(24, 38, w - 48, 2);
  });
  const dotIcon = kind => png(36, 36, (x) => {
    const on = { collapse: ['00000', '00000', '11111', '00000', '00000'], expand: ['00100', '00100', '11111', '00100', '00100'], close: ['10001', '01010', '00100', '01010', '10001'], more: ['00000', '00000', '10101', '00000', '00000'] }[kind];
    x.fillStyle = '#000';
    on.forEach((row, ry) => [...row].forEach((b, rx) => { if (b === '1') { x.beginPath(); x.arc(6 + rx * 6, 6 + ry * 6, 2.1, 0, 7); x.fill(); } }));
  });
  const orbFrame = (i, dark) => png(112, 112, (x, w, h) => {
    x.beginPath(); x.arc(56, 56, 54, 0, 7); x.fillStyle = dark ? '#0A0A0A' : '#161616'; x.fill();
    x.lineWidth = 3; x.strokeStyle = dark ? '#2E2E2C' : '#D6D6D2'; x.stroke();
    for (let k = 0; k < 16; k++) {
      const a = (k / 16) * Math.PI * 2 - Math.PI / 2, d = ((k - i * 16 / 12) % 16 + 16) % 16, lit = Math.max(0.12, 1 - d / 6);
      x.beginPath(); x.arc(56 + Math.cos(a) * 38, 56 + Math.sin(a) * 38, 4.2, 0, 7);
      x.fillStyle = `rgba(255,176,0,${lit.toFixed(2)})`; x.fill();
    }
    x.beginPath(); x.arc(56, 56, 6, 0, 7); x.fillStyle = '#FF5F1F'; x.fill();
  });
  const fieldAssets = {
    'images/note-body@2x.png': fBody(false), 'images/note-body~dark@2x.png': fBody(true),
    'images/note-header@2x.png': fHead(false), 'images/note-header~dark@2x.png': fHead(true),
    'images/note-collapsed@2x.png': fBar(false), 'images/note-collapsed~dark@2x.png': fBar(true),
    'images/decoration@2x.png': fPlate(false), 'images/decoration~dark@2x.png': fPlate(true),
    'images/icon-close@2x.png': dotIcon('close'), 'images/icon-collapse@2x.png': dotIcon('collapse'),
    'images/icon-expand@2x.png': dotIcon('expand'), 'images/icon-more@2x.png': dotIcon('more'),
    'sounds/note-create.wav': wav(click, 60, 44100),
    'sounds/voice-start.wav': wav((t, r) => click(t, r) * 0.6 + blip(1320, 1760)(t) * 0.6, 120, 44100),
    'sounds/voice-stop.wav': wav((t, r) => click(t, r) * 0.6 + blip(1760, 1320)(t) * 0.6, 120, 44100)
  };
  for (let i = 0; i < 12; i++) fieldAssets[`images/orb-listening-${i}@2x.png`] = orbFrame(i, false);
  L.register({ id: field.id, skin: field, builtIn: true, label: 'Sample', assets: map(fieldAssets) });

  // ---------- Paper & Tape ----------
  const paper = {
    formatVersion: 1, id: 'webby.paper', name: 'Paper & Tape', author: 'Webby', version: '0.1.0',
    description: 'Real stationery stuck onto the web: grainy paper, a strip of masking tape, a short shadow and ink-coloured type.',
    base: 'webby.clear', tags: ['paper', 'warm', 'tactile'], appearances: ['light', 'dark'],
    palette: [
      { light: '#F6F1E600', dark: '#24211D00' },
      { light: '#F7DC6F', dark: '#4A3F17' }, { light: '#CDA978', dark: '#3A2C1D' }, { light: '#BFE6D2', dark: '#1E3A2E' },
      { light: '#C9DDF5', dark: '#1D2A3F' }, { light: '#F8C9D6', dark: '#41222D' }, { light: '#DCD0F2', dark: '#2D2540' }, { light: '#F9CFA6', dark: '#40291A' }
    ],
    surface: {
      fill: { light: '#F6F1E6', dark: '#24211D' }, material: 'none',
      image: { element: 'note-body', insets: { top: 14, left: 14, bottom: 14, right: 14 }, mode: 'tile', tintWithPalette: true },
      cornerRadius: 2, border: { width: 0 }, shadow: 'soft',
      padding: { top: 14, left: 14, bottom: 14, right: 14 },
      text: { color: { light: '#2B2621', dark: '#EDE6D6' } }, placeholderColor: { light: '#2B262180', dark: '#EDE6D680' },
      selection: { light: '#FFE80073', dark: '#FFE80040' }, caret: { light: '#24357A', dark: '#9FB1F0' }
    },
    typography: { font: { family: 'Charter' }, size: 14, weight: 'regular', lineSpacing: 4 },
    header: { height: 20, showsTitle: false },
    collapsed: { height: 26, showsFirstLine: true },
    decoration: { element: 'decoration', anchor: 'topCenter', origin: 'center', offset: { x: 0, y: -6 }, rotation: -3 },
    icons: { template: true, tint: { light: '#2B2621B3', dark: '#EDE6D6B3' } },
    resizeHandle: { visibility: 'hover' },
    library: { accent: { light: '#C2392E', dark: '#FF8A7E' }, sidebarMaterial: 'sidebar', cardStyle: 'note' },
    sounds: { volume: 0.5, mute: [] },
    highContrast: { 'surface.fill': { light: '#FFFFFF', dark: '#000000' }, 'surface.text.color': { light: '#000000', dark: '#FFFFFF' } }
  };
  const pBody = dark => png(192, 192, (x, w, h) => {
    grain(x, w, h, dark ? [255, 255, 255] : [60, 40, 20], dark ? 0.06 : 0.07, dark ? 31 : 17, 0.6);
    const r = rand(dark ? 41 : 29);
    for (let i = 0; i < 70; i++) {
      const X = r() * w, Y = r() * h, a = r() * Math.PI, L = 4 + r() * 10;
      x.strokeStyle = dark ? 'rgba(255,255,255,.07)' : 'rgba(80,55,30,.10)'; x.lineWidth = 1;
      x.beginPath(); x.moveTo(X, Y); x.lineTo(X + Math.cos(a) * L, Y + Math.sin(a) * L); x.stroke();
    }
    // Deckled edge: an uneven darker rim with a few fray specks
    x.fillStyle = dark ? 'rgba(0,0,0,.35)' : 'rgba(90,65,35,.16)';
    for (let i = 0; i < w; i += 2) {
      const t = 1 + r() * 2.5;
      x.fillRect(i, 0, 2, t); x.fillRect(i, h - t, 2, t); x.fillRect(0, i, t, 2); x.fillRect(w - t, i, t, 2);
    }
  });
  const pHead = dark => png(40, 40, (x, w, h) => {
    x.fillStyle = dark ? 'rgba(255,255,255,.05)' : 'rgba(90,65,35,.08)'; x.fillRect(0, 0, w, h - 4);
    x.fillStyle = dark ? 'rgba(255,255,255,.22)' : 'rgba(43,38,33,.28)';
    for (let i = 1; i < w; i += 6) x.fillRect(i, h - 3, 2, 2);
  });
  const torn = (x, w, h, col, seed) => {
    const r = rand(seed);
    x.fillStyle = col;
    x.beginPath(); x.moveTo(6, 0);
    for (let y = 0; y <= h; y += 4) x.lineTo(2 + r() * 6, y);
    x.lineTo(w - 6, h);
    for (let y = h; y >= 0; y -= 4) x.lineTo(w - 2 - r() * 6, y);
    x.closePath(); x.fill();
  };
  const pBar = dark => png(52, 52, (x, w, h) => {
    torn(x, w, h, dark ? 'rgba(90,70,48,.95)' : 'rgba(205,169,120,.92)', 3);
    x.globalCompositeOperation = 'source-atop'; grain(x, w, h, [60, 40, 20], 0.12, 9, 0.5);
  });
  const pTape = dark => png(192, 56, (x, w, h) => {
    torn(x, w, h, dark ? 'rgba(200,190,165,.55)' : 'rgba(233,223,198,.85)', 7);
    x.globalCompositeOperation = 'source-atop';
    x.fillStyle = dark ? 'rgba(255,255,255,.06)' : 'rgba(255,255,255,.25)';
    for (let i = -h; i < w; i += 14) { x.beginPath(); x.moveTo(i, 0); x.lineTo(i + 7, 0); x.lineTo(i + 7 + h, h); x.lineTo(i + h, h); x.fill(); }
    grain(x, w, h, [80, 60, 30], 0.08, 13, 0.5);
  });
  const pencil = kind => png(36, 36, (x) => {
    const r = rand(kind.length * 7 + 3); const j = () => (r() - .5) * 1.4;
    x.strokeStyle = '#000'; x.lineWidth = 3; x.lineCap = 'round'; x.lineJoin = 'round';
    const line = pts => { x.beginPath(); pts.forEach(([X, Y], i) => (i ? x.lineTo(X + j(), Y + j()) : x.moveTo(X + j(), Y + j()))); x.stroke(); };
    if (kind === 'close') { line([[9, 9], [18, 18], [27, 27]]); line([[27, 9], [18, 18], [9, 27]]); }
    if (kind === 'collapse') { line([[8, 13], [18, 23], [28, 13]]); }
    if (kind === 'expand') { line([[8, 23], [18, 13], [28, 23]]); }
    if (kind === 'more') { [9, 18, 27].forEach(X => { x.beginPath(); x.arc(X + j(), 18 + j(), 2.4, 0, 7); x.fillStyle = '#000'; x.fill(); }); }
  });
  L.register({
    id: paper.id, skin: paper, builtIn: true, label: 'Built-in (v1.1)',
    assets: map({
      'images/note-body@2x.png': pBody(false), 'images/note-body~dark@2x.png': pBody(true),
      'images/note-header@2x.png': pHead(false), 'images/note-header~dark@2x.png': pHead(true),
      'images/note-collapsed@2x.png': pBar(false), 'images/note-collapsed~dark@2x.png': pBar(true),
      'images/decoration@2x.png': pTape(false), 'images/decoration~dark@2x.png': pTape(true),
      'images/icon-close@2x.png': pencil('close'), 'images/icon-collapse@2x.png': pencil('collapse'),
      'images/icon-expand@2x.png': pencil('expand'), 'images/icon-more@2x.png': pencil('more'),
      'sounds/note-create.wav': wav((t, r) => (r() * 2 - 1) * Math.exp(-t * 45) * Math.min(1, t * 400) * 0.35, 120)
    })
  });

  const order = ['webby.clear', 'webby.paper', 'webby.graphite', 'io.github.jynlee7.desk-accessory', 'io.github.jynlee7.field-instrument'];
  L.registry.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
})();
