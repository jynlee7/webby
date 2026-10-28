// Webby skin engine for the moodboard's skin lab.
// Mirrors plan §4f and §5.4: one loader for built-in and imported skins, group-level fallback,
// a contrast floor computed over white and black backdrops, and accessibility applied last.
(function (root) {
  const FORMAT_VERSION = 1;
  const NAME_RE = /^(skin\.json|preview(@2x)?\.png|images\/[a-z0-9-]+(~dark)?(-\d{1,2})?(@2x)?\.png|sounds\/[a-z0-9-]+\.(wav|aif|aiff|caf))$/;
  const LIMITS = { archive: 25e6, total: 64e6, entries: 400, manifest: 256e3, image: 4e6, sound: 1e6, side: 2048, pixels: 24e6 };
  const MATERIALS = ['none', 'titlebar', 'selection', 'menu', 'popover', 'sidebar', 'headerView', 'sheet', 'windowBackground', 'hudWindow', 'fullScreenUI', 'toolTip', 'contentBackground', 'underWindowBackground', 'underPageBackground'];
  const ANCHORS = ['topLeft', 'topCenter', 'topRight', 'centerLeft', 'center', 'centerRight', 'bottomLeft', 'bottomCenter', 'bottomRight'];
  const WEIGHTS = { ultraLight: 100, thin: 200, light: 300, regular: 400, medium: 500, semibold: 600, bold: 700, heavy: 800, black: 900 };
  const SOUNDS = ['note-create', 'note-save', 'note-delete', 'note-collapse', 'voice-start', 'voice-stop', 'voice-error'];
  const ORB_STATES = ['idle', 'listening', 'thinking', 'speaking', 'error'];
  const TOP_KEYS = new Set(['$schema', 'formatVersion', 'id', 'name', 'author', 'version', 'description', 'license', 'credits', 'basedOn', 'base', 'tags', 'appearances', 'palette', 'surface', 'typography', 'header', 'collapsed', 'decoration', 'icons', 'resizeHandle', 'library', 'voiceOrb', 'sounds', 'highContrast']);
  const GROUPS = ['surface', 'typography', 'header', 'collapsed', 'decoration', 'icons', 'resizeHandle', 'palette', 'library', 'voiceOrb', 'sounds'];

  // ---------- color ----------
  function hex(v) {
    if (typeof v !== 'string') return null;
    const m = /^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$/.exec(v);
    if (!m) return null;
    const n = parseInt(m[1], 16);
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255, a: m[2] ? parseInt(m[2], 16) / 255 : 1 };
  }
  function isColor(v) {
    if (typeof v === 'string') return !!hex(v);
    return !!(v && typeof v === 'object' && hex(v.light) && (v.dark === undefined || hex(v.dark)));
  }
  function pick(v, app) {
    if (v == null || typeof v !== 'object' || Array.isArray(v)) return v;
    if ('light' in v || 'dark' in v) return v[app] !== undefined ? v[app] : v.light;
    return v;
  }
  function rgba(c, a) { return `rgba(${c.r | 0}, ${c.g | 0}, ${c.b | 0}, ${+(a === undefined ? c.a : a).toFixed(3)})`; }
  const lin = c => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  const lum = c => 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const over = (top, a, under) => ({ r: top.r * a + under.r * (1 - a), g: top.g * a + under.g * (1 - a), b: top.b * a + under.b * (1 - a) });
  const WHITE = { r: 255, g: 255, b: 255 }, BLACK = { r: 0, g: 0, b: 0 };
  const stack = (layers, backdrop) => layers.reduce((acc, l) => over(l.c, l.a, acc), backdrop);
  // Worst-case contrast of text over the layers, with an unknown backdrop (white or black).
  const worst = (text, layers) => Math.min(ratio(text, stack(layers, WHITE)), ratio(text, stack(layers, BLACK)));
  // Smallest fill opacity at which text meets the floor over any backdrop; null if none works.
  function minAlpha(text, fill, floor, above) {
    for (let i = 0; i <= 100; i++) {
      const a = i / 100;
      if (worst(text, [{ c: fill, a }].concat(above || [])) >= floor) return a;
    }
    return null;
  }

  // ---------- the built-in base ----------
  const CLEAR = {
    formatVersion: 1, id: 'webby.clear', name: 'Clear', author: 'Webby', version: '1.0.0',
    description: 'Clear glass, lit from the top left. The default skin and the fallback for every other skin.',
    appearances: ['light', 'dark'],
    palette: [
      { light: '#FFFFFF00', dark: '#FFFFFF00' },
      { light: '#FFC86B66', dark: '#FFB3472E' },
      { light: '#FF9DB566', dark: '#FF7A9A2E' },
      { light: '#8FE3B866', dark: '#4FD69A29' },
      { light: '#93C5FF66', dark: '#5AA9FF2E' },
      { light: '#C3AEFF66', dark: '#A98BFF2E' }
    ],
    surface: {
      fill: { light: '#FFFFFF80', dark: '#16181DB8' },
      material: 'popover',
      cornerRadius: 16,
      border: { width: 1, color: { light: '#FFFFFFB3', dark: '#FFFFFF2E' } },
      shadow: 'soft',
      padding: { top: 12, left: 14, bottom: 14, right: 14 },
      text: { color: { light: '#0B0C0F', dark: '#F1F2F4' } },
      placeholderColor: { light: '#0B0C0F80', dark: '#F1F2F480' },
      selection: { light: '#2F52E033', dark: '#7D97FF40' },
      caret: { light: '#2F52E0', dark: '#7D97FF' }
    },
    typography: { size: 14, weight: 'regular', lineSpacing: 3 },
    header: { height: 0 },
    collapsed: { height: 32, showsFirstLine: true },
    decoration: { hidden: true },
    icons: { template: true, tint: { light: '#0B0C0F99', dark: '#F1F2F499' } },
    resizeHandle: { visibility: 'hover' },
    library: { accent: { light: '#2F52E0', dark: '#7D97FF' }, sidebarMaterial: 'sidebar', cardStyle: 'uniform' },
    voiceOrb: { states: { idle: { frames: 1, fps: 0 } } },
    sounds: { volume: 0.6, mute: [] },
    highContrast: {
      'surface.fill': { light: '#F9FAFB', dark: '#1D2026' },
      'surface.text.color': { light: '#000000', dark: '#FFFFFF' }
    }
  };

  // ---------- validation ----------
  function num(v) { return typeof v === 'number' && Number.isFinite(v); }
  function clampWarn(d, path, v, lo, hi) {
    if (!num(v)) return undefined;
    if (v < lo || v > hi) { d.push({ level: 'warning', path, msg: `${v} is outside ${lo}–${hi}; clamped.` }); return Math.min(hi, Math.max(lo, v)); }
    return v;
  }
  function colorKey(g, key, d, path) {
    if (g[key] === undefined) return;
    if (!isColor(g[key])) throw new GroupError(`${path}.${key}: expected #RRGGBB or #RRGGBBAA, or { "light", "dark" }.`);
  }
  class GroupError extends Error {}

  const groupCheck = {
    surface(g, d) {
      const p = 'surface';
      ['fill', 'placeholderColor', 'selection', 'caret'].forEach(k => colorKey(g, k, d, p));
      if (g.text !== undefined) { if (!g.text || !isColor(g.text.color)) throw new GroupError('surface.text.color: expected a color.'); }
      if (g.material !== undefined) {
        const okMat = m => typeof m === 'string' && MATERIALS.includes(m);
        const mats = typeof g.material === 'object' && g.material ? g.material : { light: g.material };
        Object.keys(mats).forEach(k => { if (!okMat(mats[k])) { d.push({ level: 'warning', path: 'surface.material', msg: `"${mats[k]}" is not an allowed material; using none.` }); mats[k] = 'none'; } });
        g.material = typeof g.material === 'object' && g.material ? mats : mats.light;
      }
      if (g.image !== undefined) {
        const im = g.image;
        if (!im || typeof im !== 'object') throw new GroupError('surface.image: expected an object.');
        if (!im.insets || !['top', 'left', 'bottom', 'right'].every(k => num(im.insets[k]) && im.insets[k] >= 0)) throw new GroupError('surface.image: a 9-slice image needs insets (top, left, bottom, right).');
        if (im.mode !== undefined && !['stretch', 'tile'].includes(im.mode)) { d.push({ level: 'warning', path: 'surface.image.mode', msg: 'Use stretch or tile; using stretch.' }); im.mode = 'stretch'; }
        im.element = im.element || 'note-body';
      }
      g.cornerRadius = clampWarn(d, 'surface.cornerRadius', g.cornerRadius, 0, 32);
      if (g.border !== undefined) {
        if (!g.border || typeof g.border !== 'object') throw new GroupError('surface.border: expected { width, color }.');
        g.border.width = clampWarn(d, 'surface.border.width', g.border.width, 0, 4);
        if (g.border.color !== undefined && !isColor(g.border.color)) throw new GroupError('surface.border.color: expected a color.');
      }
      if (g.shadow !== undefined && !['system', 'none', 'soft'].includes(g.shadow)) { d.push({ level: 'warning', path: 'surface.shadow', msg: 'Use system, none or soft; using soft.' }); g.shadow = 'soft'; }
      if (g.padding !== undefined) ['top', 'left', 'bottom', 'right'].forEach(k => { g.padding[k] = clampWarn(d, `surface.padding.${k}`, g.padding[k], 0, 40); });
    },
    typography(g, d) {
      if (g.font !== undefined && (!g.font || typeof g.font.family !== 'string')) throw new GroupError('typography.font.family: expected a font name.');
      g.size = clampWarn(d, 'typography.size', g.size, 10, 32);
      if (g.weight !== undefined && !(g.weight in WEIGHTS)) { d.push({ level: 'warning', path: 'typography.weight', msg: `Unknown weight "${g.weight}"; using regular.` }); g.weight = 'regular'; }
      g.lineSpacing = clampWarn(d, 'typography.lineSpacing', g.lineSpacing, 0, 20);
    },
    header(g, d) {
      if (num(g.height) && g.height > 0 && g.height < 16) { d.push({ level: 'warning', path: 'header.height', msg: 'Header height is 0 or 16–36; using 16.' }); g.height = 16; }
      else g.height = clampWarn(d, 'header.height', g.height, 0, 36);
      colorKey(g, 'fill', d, 'header');
    },
    collapsed(g, d) { g.height = clampWarn(d, 'collapsed.height', g.height, 16, 48); },
    decoration(g, d) {
      if (g.anchor !== undefined && !ANCHORS.includes(g.anchor)) throw new GroupError(`decoration.anchor: use one of ${ANCHORS.join(', ')}.`);
      if (g.origin !== undefined && !ANCHORS.includes(g.origin)) throw new GroupError('decoration.origin: use an anchor name.');
      g.rotation = clampWarn(d, 'decoration.rotation', g.rotation, -180, 180);
      if (g.offset) { g.offset.x = clampWarn(d, 'decoration.offset.x', g.offset.x, -64, 64); g.offset.y = clampWarn(d, 'decoration.offset.y', g.offset.y, -64, 64); }
    },
    icons(g, d) { colorKey(g, 'tint', d, 'icons'); },
    resizeHandle(g, d) {
      if (g.visibility !== undefined && !['always', 'hover', 'never'].includes(g.visibility)) { d.push({ level: 'warning', path: 'resizeHandle.visibility', msg: 'Use always, hover or never; using hover.' }); g.visibility = 'hover'; }
      colorKey(g, 'tint', d, 'resizeHandle');
    },
    palette(g, d) {
      if (!Array.isArray(g)) throw new GroupError('palette: expected a list of colors.');
      if (g.length > 12) { d.push({ level: 'warning', path: 'palette', msg: `${g.length} entries; only the first 12 are used.` }); g.length = 12; }
      g.forEach((c, i) => { if (!isColor(c)) throw new GroupError(`palette[${i}]: expected a color or { "light", "dark" }.`); });
    },
    library(g, d) {
      colorKey(g, 'accent', d, 'library'); colorKey(g, 'background', d, 'library');
      if (g.cardStyle !== undefined && !['note', 'uniform'].includes(g.cardStyle)) { d.push({ level: 'warning', path: 'library.cardStyle', msg: 'Use note or uniform; using uniform.' }); g.cardStyle = 'uniform'; }
      if (g.sidebarMaterial !== undefined && !MATERIALS.includes(g.sidebarMaterial)) { d.push({ level: 'warning', path: 'library.sidebarMaterial', msg: 'Not an allowed material; using sidebar.' }); g.sidebarMaterial = 'sidebar'; }
    },
    voiceOrb(g, d) {
      const st = g.states || {};
      Object.keys(st).forEach(k => {
        if (!ORB_STATES.includes(k)) { d.push({ level: 'warning', path: `voiceOrb.states.${k}`, msg: 'Unknown state; ignored.' }); delete st[k]; return; }
        const s = st[k];
        if (!num(s.frames) || s.frames < 1 || s.frames > 60) throw new GroupError(`voiceOrb.states.${k}.frames: 1–60 frames.`);
        if (s.audioReactive !== undefined) s.audioReactive = clampWarn(d, `voiceOrb.states.${k}.audioReactive`, s.audioReactive, 0, 0.3);
      });
    },
    sounds(g, d) {
      if (g.volume !== undefined) g.volume = clampWarn(d, 'sounds.volume', g.volume, 0, 1);
      if (g.mute !== undefined && !Array.isArray(g.mute)) throw new GroupError('sounds.mute: expected a list of sound names.');
      (g.mute || []).forEach(n => { if (!SOUNDS.includes(n)) d.push({ level: 'warning', path: 'sounds.mute', msg: `Unknown sound "${n}".` }); });
    }
  };

  // Validate a parsed skin.json. Returns { skin, diags, fatal }. Groups with errors are dropped,
  // so they fall back to the base as a unit.
  function validate(raw, opts) {
    opts = opts || {};
    const d = [];
    const fatal = msg => { d.push({ level: 'fatal', path: '', msg }); return { skin: null, diags: d, fatal: true }; };
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return fatal('skin.json must be a JSON object.');
    const s = JSON.parse(JSON.stringify(raw));
    if (s.formatVersion === undefined) return fatal('formatVersion is required.');
    if (!Number.isInteger(s.formatVersion) || s.formatVersion < 1) return fatal('formatVersion must be a whole number, 1 or higher.');
    if (s.formatVersion > FORMAT_VERSION) return fatal(`This skin needs a newer Webby (formatVersion ${s.formatVersion}; this build reads ${FORMAT_VERSION}).`);
    if (typeof s.id !== 'string' || !/^[a-z0-9]+(\.[a-z0-9-]+)+$/.test(s.id)) return fatal('id must be reverse-DNS, such as "io.github.you.my-skin".');
    if (!opts.builtIn && s.id.startsWith('webby.')) return fatal('The webby. prefix is reserved for built-in skins. Pick your own id.');
    if (typeof s.name !== 'string' || !s.name.trim()) d.push({ level: 'warning', path: 'name', msg: 'No name; showing the id instead.' });
    Object.keys(s).forEach(k => { if (!TOP_KEYS.has(k)) d.push({ level: 'warning', path: k, msg: 'Unknown key; ignored.' }); });
    GROUPS.forEach(name => {
      if (s[name] === undefined) return;
      try {
        if (name !== 'palette' && (typeof s[name] !== 'object' || Array.isArray(s[name]))) throw new GroupError(`${name}: expected an object.`);
        groupCheck[name](s[name], d);
      } catch (e) {
        if (!(e instanceof GroupError)) throw e;
        d.push({ level: 'error', path: name, msg: `${e.message} The ${name} group falls back to the base skin.` });
        delete s[name];
      }
    });
    if (s.highContrast !== undefined) {
      const ok = ['surface.fill', 'surface.text.color', 'surface.border.color', 'header.fill', 'library.accent'];
      Object.keys(s.highContrast).forEach(k => {
        if (!ok.includes(k)) { d.push({ level: 'warning', path: `highContrast.${k}`, msg: 'Not an overridable path; ignored.' }); delete s.highContrast[k]; }
        else if (!isColor(s.highContrast[k])) { d.push({ level: 'error', path: `highContrast.${k}`, msg: 'Expected a color; ignored.' }); delete s.highContrast[k]; }
      });
    }
    if (s.base !== undefined && s.base !== 'webby.clear') d.push({ level: 'warning', path: 'base', msg: `Base "${s.base}" isn't in this build; using webby.clear.` });
    return { skin: s, diags: d, fatal: false };
  }

  // ---------- assets ----------
  // assets: Map of archive path -> { url, w, h } (images, pixel size) or { url, bytes } (sounds)
  function findImage(assets, element, app, frame) {
    if (!assets) return null;
    const f = frame === undefined ? '' : `-${frame}`;
    const order = app === 'dark' ? [`~dark${f}@2x`, `~dark${f}`, `${f}@2x`, `${f}`] : [`${f}@2x`, `${f}`];
    for (const suf of order) {
      const key = `images/${element}${suf}.png`;
      const a = assets.get(key);
      if (a) { const scale = suf.endsWith('@2x') ? 2 : 1; return { url: a.url, scale, w: a.w / scale, h: a.h / scale, key }; }
    }
    return null;
  }

  // ---------- resolve ----------
  // Resolve a validated skin for one appearance: group fallback, contrast unit check,
  // the opacity floor, then accessibility transforms last.
  function resolve(skin, assets, app, a11y) {
    a11y = a11y || {};
    const notes = [];
    const base = CLEAR;
    const g = name => (skin && skin[name] !== undefined ? skin[name] : base[name]);
    const fromBase = name => !skin || skin[name] === undefined;
    let surface = Object.assign({}, base.surface, g('surface'));
    let palette = g('palette');
    const typ = Object.assign({}, base.typography, g('typography'));
    const size = typ.size || 14, weight = WEIGHTS[typ.weight || 'regular'];
    const large = size >= 18 || (size >= 14 && weight >= 700);
    const floor = large ? 3 : 4.5;

    const col = (v, fallback) => hex(pick(v, app)) || hex(pick(fallback, app));
    const translucent = s => { const m = pick(s.material, app); return !!m && m !== 'none'; };

    const unitCheck = (surf, pal) => {
      const text = col(surf.text && surf.text.color, base.surface.text.color);
      const fill = col(surf.fill, base.surface.fill);
      let alpha = translucent(surf) ? Math.min(fill.a, 1) : fill.a;
      const need = minAlpha(text, fill, floor);
      if (need === null) return { ok: false, why: `Text can't reach ${floor}:1 on this fill at any opacity.` };
      alpha = Math.max(alpha, need);
      for (let i = 0; i < pal.length; i++) {
        const p = col(pal[i]);
        if (worst(text, [{ c: fill, a: alpha }, { c: p, a: p.a }]) < floor) return { ok: false, why: `Palette color ${i + 1} fails ${floor}:1 with the text color.` };
      }
      return { ok: true, alpha, need, text, fill };
    };

    let unit = unitCheck(surface, palette);
    if (!unit.ok) {
      notes.push({ level: 'error', path: 'surface + palette', msg: `${unit.why} Surface and palette fall back to webby.clear together.` });
      surface = Object.assign({}, base.surface); palette = base.palette;
      unit = unitCheck(surface, palette);
    }
    const fillC = unit.fill;
    let fillA = unit.alpha;
    if (unit.alpha > fillC.a + 0.004) notes.push({ level: 'info', path: 'surface.fill', msg: `Fill opacity raised from ${Math.round(fillC.a * 100)}% to ${Math.round(unit.alpha * 100)}% so text keeps ${floor}:1 over any page.` });

    let text = unit.text;
    let material = pick(surface.material, app) || 'none';
    let fill = fillC;
    let border = surface.border ? { w: surface.border.width || 0, c: col(surface.border.color, '#00000000') } : { w: 0, c: hex('#00000000') };

    // Accessibility always last
    if (a11y.increaseContrast) {
      const hc = Object.assign({}, base.highContrast, skin && skin.highContrast);
      if (hc['surface.fill']) { fill = col(hc['surface.fill']); fillA = 1; material = 'none'; }
      if (hc['surface.text.color']) text = col(hc['surface.text.color']);
      border = { w: Math.max(1, border.w), c: hc['surface.border.color'] ? col(hc['surface.border.color']) : Object.assign({}, text, { a: 0.55 }) };
    }
    if (a11y.reduceTransparency) {
      const win = app === 'dark' ? { r: 30, g: 31, b: 35 } : { r: 246, g: 246, b: 248 };
      fill = Object.assign(over(fill, fillA, win), { a: 1 }); fillA = 1; material = 'none';
    }

    const img = surface.image ? findImage(assets, surface.image.element || 'note-body', app) : null;
    if (surface.image && !img && !fromBase('surface')) notes.push({ level: 'warning', path: 'surface.image', msg: `images/${surface.image.element || 'note-body'}@2x.png is missing; drawing the fill only.` });
    const header = Object.assign({}, base.header, g('header'));
    const collapsed = Object.assign({}, base.collapsed, g('collapsed'));
    const deco = fromBase('decoration') ? base.decoration : Object.assign({ hidden: false }, skin.decoration);
    const decoImg = deco.hidden ? null : findImage(assets, 'decoration', app);
    if (decoImg && (decoImg.w > 128 || decoImg.h > 64)) notes.push({ level: 'warning', path: 'decoration', msg: `Decoration is ${decoImg.w}×${decoImg.h} pt; the cap is 128×64, so it is scaled down.` });
    const icons = Object.assign({}, base.icons, g('icons'));
    const lib = Object.assign({}, base.library, g('library'));
    const libBg = col(lib.background, app === 'dark' ? '#1C1D21' : '#F6F6F8');
    let accent = col(lib.accent, base.library.accent);
    if (ratio(accent, libBg) < 3) { notes.push({ level: 'error', path: 'library.accent', msg: 'Accent is under 3:1 against the Library background; using the base accent.' }); accent = col(base.library.accent); }
    const orb = Object.assign({}, base.voiceOrb, g('voiceOrb'));
    const orbFrames = [];
    const ls = orb.states && orb.states.listening;
    if (ls && assets) for (let i = 0; i < ls.frames; i++) { const f = findImage(assets, 'orb-listening', app, i); if (!f) { notes.push({ level: 'error', path: 'voiceOrb.states.listening', msg: `Frame ${i} is missing; the orb uses the built-in drawing.` }); orbFrames.length = 0; break; } orbFrames.push(f.url); }
    const sounds = [];
    if (assets) assets.forEach((a, k) => { const m = /^sounds\/([a-z0-9-]+)\./.exec(k); if (m) sounds.push({ name: m[1], url: a.url, bytes: a.bytes }); });

    return {
      app, notes, floor,
      fill: { c: fill, a: fillA, css: rgba(fill, fillA) },
      material, blur: material !== 'none',
      image: img ? { url: img.url, scale: img.scale, insets: surface.image.insets, mode: surface.image.mode || 'stretch', tint: !!surface.image.tintWithPalette } : null,
      radius: num(surface.cornerRadius) ? surface.cornerRadius : 16,
      border: { w: border.w, css: rgba(border.c, border.c.a) },
      shadow: surface.shadow || 'soft',
      padding: Object.assign({ top: 12, left: 14, bottom: 14, right: 14 }, surface.padding),
      text: rgba(text, 1),
      placeholder: rgba(col(surface.placeholderColor, base.surface.placeholderColor)),
      selection: rgba(col(surface.selection, base.surface.selection)),
      caret: rgba(col(surface.caret, base.surface.caret), 1),
      font: { family: typ.font && typ.font.family, size, weight, lineSpacing: num(typ.lineSpacing) ? typ.lineSpacing : 3 },
      header: { height: header.height || 0, fill: header.fill ? rgba(col(header.fill)) : null, showsTitle: header.showsTitle !== false, image: findImage(assets, 'note-header', app) },
      collapsed: { height: collapsed.height || 32, showsFirstLine: collapsed.showsFirstLine !== false, image: findImage(assets, 'note-collapsed', app) },
      decoration: decoImg ? { url: decoImg.url, w: Math.min(decoImg.w, 128), h: Math.min(decoImg.h, 64) * (decoImg.w > 128 ? 128 / decoImg.w : 1), anchor: deco.anchor || 'topCenter', origin: deco.origin || 'center', offset: deco.offset || { x: 0, y: 0 }, rotation: deco.rotation || 0 } : null,
      icons: { tint: rgba(col(icons.tint, base.icons.tint)), template: icons.template !== false, images: ['collapse', 'expand', 'close', 'more'].reduce((o, n) => { const f = findImage(assets, `icon-${n}`, app); if (f) o[n] = f.url; return o; }, {}) },
      resize: Object.assign({ visibility: 'hover' }, g('resizeHandle')),
      palette: palette.map(p => { const c = col(p); return { c, css: rgba(c) }; }),
      library: { accent: rgba(accent, 1), background: rgba(libBg, 1), cardStyle: lib.cardStyle || 'uniform', sidebarTranslucent: (lib.sidebarMaterial || 'sidebar') !== 'none' },
      orb: { frames: orbFrames, fps: ls && ls.fps > 0 ? ls.fps : 24 },
      sounds
    };
  }

  // ---------- archive checks (pure parts) ----------
  function checkName(name) {
    if (/(^\/)|(\.\.)|\\|\0/.test(name)) return 'reject';
    if (name.startsWith('__MACOSX/') || name.endsWith('.DS_Store')) return 'skip';
    if (name.endsWith('/')) return 'dir';
    return NAME_RE.test(name) ? 'ok' : 'unknown';
  }
  function pngSize(bytes) {
    const sig = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 24 || !sig.every((b, i) => bytes[i] === b)) return null;
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (String.fromCharCode(bytes[12], bytes[13], bytes[14], bytes[15]) !== 'IHDR') return null;
    return { w: dv.getUint32(16), h: dv.getUint32(20) };
  }
  // Lenient JSON: strict first, then strip comments and trailing commas (JSON5-ish), with a warning.
  function parseManifest(text) {
    try { return { value: JSON.parse(text), strict: true }; } catch (e) {
      const loose = text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:"'])\/\/.*$/gm, '$1').replace(/,\s*([}\]])/g, '$1');
      try { return { value: JSON.parse(loose), strict: false }; } catch (e2) { return { error: e.message }; }
    }
  }

  const api = { FORMAT_VERSION, LIMITS, NAME_RE, CLEAR, WEIGHTS, validate, resolve, checkName, pngSize, parseManifest, hex, ratio, minAlpha, worst, rgba, pick };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.WebbySkins = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
