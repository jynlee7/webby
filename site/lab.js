// Skin lab: render any skin on a live note, import .webbyskin / skin.json files, edit skin.json live,
// and download any skin as a .webbyskin.
(function () {
  const S = window.WebbySkins;
  const $ = (sel, el) => (el || document).querySelector(sel);
  const h = (tag, cls, attrs) => { const e = document.createElement(tag); if (cls) e.className = cls; if (attrs) Object.assign(e, attrs); return e; };
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  // ---------- skin registry ----------
  // entry: { id, skin (raw json), assets: Map, builtIn, source: 'built-in' | 'imported', bytes }
  const registry = [];
  window.WebbyLab = { registry, register, renderSkin, select };

  function register(entry) {
    const i = registry.findIndex(e => e.id === entry.id);
    if (i >= 0) registry[i] = entry; else registry.push(entry);
    renderShelf();
    renderDirections();
    return entry;
  }

  // ---------- default icon shapes (page-provided, not part of the skin format) ----------
  const ICON_SVG = {
    collapse: '<path d="M4 7l5 5 5-5" fill="none" stroke="#000" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
    expand: '<path d="M4 11l5-5 5 5" fill="none" stroke="#000" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
    close: '<path d="M5 5l8 8M13 5l-8 8" fill="none" stroke="#000" stroke-width="1.8" stroke-linecap="round"/>',
    more: '<circle cx="4" cy="9" r="1.5"/><circle cx="9" cy="9" r="1.5"/><circle cx="14" cy="9" r="1.5"/>'
  };
  const iconMask = n => `url("data:image/svg+xml,${encodeURIComponent(`<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 18 18'>${ICON_SVG[n]}</svg>`)}")`;

  // ---------- palette tint for 9-slice images ----------
  const tintCache = new Map();
  function tintImage(url, css) {
    const key = url + '|' + css;
    if (tintCache.has(key)) return tintCache.get(key);
    const p = new Promise(res => {
      const img = new Image();
      img.onload = () => {
        const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
        const x = c.getContext('2d');
        x.drawImage(img, 0, 0);
        x.globalCompositeOperation = 'multiply'; x.fillStyle = css; x.fillRect(0, 0, c.width, c.height);
        x.globalCompositeOperation = 'destination-in'; x.drawImage(img, 0, 0);
        res(c.toDataURL('image/png'));
      };
      img.onerror = () => res(url);
      img.src = url;
    });
    tintCache.set(key, p);
    return p;
  }

  const SHADOWS = {
    system: '0 0 0 .5px rgba(0,0,0,.18), 0 10px 30px -6px rgba(0,0,0,.32)',
    soft: '0 1px 2px rgba(0,0,0,.08), 0 16px 32px -14px rgba(0,0,0,.34)',
    none: 'none'
  };
  const fontStack = f => {
    const fam = f ? `"${f.replace(/"/g, '')}", ` : '';
    return fam + (/mono|menlo|courier|code|plex mono/i.test(f || '')
      ? 'ui-monospace, "SF Mono", Menlo, "Geist Mono", Consolas, monospace'
      : '-apple-system, BlinkMacSystemFont, "SF Pro Text", Geist, "Helvetica Neue", Arial, sans-serif');
  };
  const ANCHOR_XY = { topLeft: [0, 0], topCenter: [.5, 0], topRight: [1, 0], centerLeft: [0, .5], center: [.5, .5], centerRight: [1, .5], bottomLeft: [0, 1], bottomCenter: [.5, 1], bottomRight: [1, 1] };

  function threeSlice(el, im) {
    const cap = Math.max(1, Math.floor(im.h / 2));
    el.style.borderStyle = 'solid';
    el.style.borderWidth = `0 ${cap}px`;
    el.style.borderImage = `url("${im.url}") 0 ${cap * im.scale} fill / 0 ${cap}px stretch`;
  }

  function iconEl(R, name) {
    const i = h('span', 'sk-ic');
    const url = R.icons.images[name];
    if (url && !R.icons.template) { i.style.background = `url("${url}") center / contain no-repeat`; }
    else {
      const m = url ? `url("${url}")` : iconMask(name);
      i.style.webkitMaskImage = m; i.style.maskImage = m;
      i.style.backgroundColor = R.icons.tint;
    }
    i.setAttribute('aria-hidden', 'true');
    return i;
  }

  // Draw one note (plus collapsed bar and orb when asked) for a resolved skin.
  // opts: { text, slot, compact, editable, onText, showBar, showOrb, width }
  function renderSkin(host, R, opts) {
    opts = opts || {};
    host.textContent = '';
    host.dataset.app = R.app;
    const W = opts.width || 280;
    const wrap = h('div', 'sk-wrap'); wrap.style.width = W + 'px';
    const note = h('div', 'sk-note');
    const st = note.style;
    st.background = R.fill.css;
    if (R.blur) { st.webkitBackdropFilter = st.backdropFilter = 'blur(20px) saturate(170%)'; }
    st.borderRadius = R.radius + 'px';
    st.border = R.border.w ? `${R.border.w}px solid ${R.border.css}` : 'none';
    st.boxShadow = SHADOWS[R.shadow] || SHADOWS.soft;
    st.color = R.text;
    st.fontFamily = fontStack(R.font.family);
    st.fontSize = R.font.size + 'px';
    st.fontWeight = R.font.weight;
    st.lineHeight = Math.round(R.font.size * 1.2 + R.font.lineSpacing) + 'px';
    st.setProperty('--sel', R.selection);
    st.setProperty('--ph', R.placeholder);
    st.caretColor = R.caret;

    const slot = R.palette[opts.slot || 0];
    if (slot && slot.c.a > 0) { const t = h('div', 'sk-tint'); t.style.background = slot.css; note.appendChild(t); }

    if (R.image) {
      const bg = h('div', 'sk-bg');
      const i = R.image.insets, s = R.image.scale;
      bg.style.borderStyle = 'solid';
      bg.style.borderWidth = `${i.top}px ${i.right}px ${i.bottom}px ${i.left}px`;
      const apply = url => { bg.style.borderImage = `url("${url}") ${i.top * s} ${i.right * s} ${i.bottom * s} ${i.left * s} fill / ${i.top}px ${i.right}px ${i.bottom}px ${i.left}px / 0 ${R.image.mode === 'tile' ? 'round' : 'stretch'}`; };
      apply(R.image.url);
      if (R.image.tint && slot && slot.c.a > 0) tintImage(R.image.url, S.rgba(slot.c, 1)).then(apply);
      note.appendChild(bg);
    }

    const title = (opts.text || '').split('\n')[0] || 'Note';
    const icons = h('div', 'sk-icons');
    ['collapse', 'more', 'close'].forEach(n => icons.appendChild(iconEl(R, n)));
    if (R.header.height > 0) {
      const head = h('div', 'sk-head');
      head.style.height = R.header.height + 'px';
      head.style.margin = `-${R.padding.top}px -${R.padding.right}px ${Math.min(8, R.padding.top)}px -${R.padding.left}px`;
      head.style.padding = `0 ${Math.max(8, R.padding.right - 4)}px 0 ${R.padding.left}px`;
      if (R.header.fill) head.style.background = R.header.fill;
      if (R.header.image) threeSlice(head, R.header.image);
      const t = h('span', 'sk-title'); t.textContent = R.header.showsTitle ? title : '';
      head.append(t, icons);
      note.appendChild(head);
    } else {
      icons.classList.add('float');
      icons.style.top = Math.max(4, R.padding.top - 6) + 'px';
      icons.style.right = Math.max(4, R.padding.right - 6) + 'px';
      note.appendChild(icons);
    }

    const body = h('div', 'sk-text');
    body.textContent = opts.text || '';
    if (opts.editable) {
      body.contentEditable = 'plaintext-only';
      if (body.contentEditable !== 'plaintext-only') body.contentEditable = 'true';
      body.spellcheck = false;
      body.setAttribute('role', 'textbox'); body.setAttribute('aria-multiline', 'true'); body.setAttribute('aria-label', 'Note text');
      body.addEventListener('input', () => opts.onText && opts.onText(body.innerText));
    }
    note.appendChild(body);
    note.style.padding = `${R.padding.top}px ${R.padding.right}px ${R.padding.bottom}px ${R.padding.left}px`;
    if (R.header.height === 0) body.style.paddingRight = '58px';

    if (R.resize.visibility !== 'never') {
      const rz = h('span', 'sk-resize' + (R.resize.visibility === 'hover' ? ' hover' : ''));
      rz.style.color = R.resize.tint ? S.rgba(S.hex(S.pick(R.resize.tint, R.app))) : R.icons.tint;
      rz.setAttribute('aria-hidden', 'true');
      note.appendChild(rz);
    }
    wrap.appendChild(note);

    if (R.decoration) {
      const d = R.decoration, img = h('img', 'sk-deco', { alt: '' });
      img.src = d.url; img.width = d.w; img.height = d.h;
      const [ax, ay] = ANCHOR_XY[d.anchor] || [.5, 0], [ox, oy] = ANCHOR_XY[d.origin] || [.5, .5];
      img.style.left = `calc(${ax * 100}% + ${d.offset.x || 0}px)`;
      img.style.top = `calc(${ay * 100}% + ${d.offset.y || 0}px)`;
      img.style.transform = `translate(${-ox * 100}%, ${-oy * 100}%) rotate(${d.rotation}deg)`;
      img.style.transformOrigin = `${ox * 100}% ${oy * 100}%`;
      wrap.appendChild(img);
    }
    host.appendChild(wrap);

    if (opts.showBar) {
      const bar = h('div', 'sk-bar');
      const bs = bar.style;
      bs.height = R.collapsed.height + 'px';
      bs.borderRadius = Math.min(R.radius, R.collapsed.height / 2) + 'px';
      bs.background = R.fill.css;
      if (R.blur) bs.webkitBackdropFilter = bs.backdropFilter = 'blur(20px) saturate(170%)';
      bs.border = R.border.w ? `${R.border.w}px solid ${R.border.css}` : 'none';
      bs.boxShadow = SHADOWS[R.shadow] || SHADOWS.soft;
      bs.color = R.text; bs.fontFamily = fontStack(R.font.family); bs.fontSize = Math.min(R.font.size, R.collapsed.height - 10) + 'px'; bs.fontWeight = Math.max(R.font.weight, 600);
      if (R.collapsed.image) threeSlice(bar, R.collapsed.image);
      if (slot && slot.c.a > 0) bs.backgroundImage = `linear-gradient(${slot.css}, ${slot.css})`;
      const t = h('span'); t.textContent = R.collapsed.showsFirstLine ? title : 'Note';
      bar.append(t, iconEl(R, 'expand'));
      host.appendChild(bar);
    }
    if (opts.showOrb) {
      const orb = h('div', 'sk-orb');
      orb.setAttribute('aria-hidden', 'true');
      if (R.orb.frames.length) {
        const img = h('img', '', { alt: '' }); img.src = R.orb.frames[0]; orb.appendChild(img);
        let i = 0; const id = setInterval(() => { if (!img.isConnected) return clearInterval(id); i = (i + 1) % R.orb.frames.length; img.src = R.orb.frames[i]; }, 1000 / R.orb.fps);
      } else orb.style.setProperty('--orb', R.library.accent);
      host.appendChild(orb);
    }
  }

  function renderLibrary(host, R, entry) {
    host.textContent = '';
    host.dataset.app = R.app;
    host.style.setProperty('--lib-bg', R.library.background);
    host.style.setProperty('--lib-accent', R.library.accent);
    host.style.color = R.app === 'dark' ? '#F1F2F4' : '#0B0C0F';
    const side = h('div', 'lib-side' + (R.library.sidebarTranslucent ? ' glassy' : ''));
    ['fieldnotes.example', 'github.com', 'Xcode', 'Inbox'].forEach((n, i) => { const w = h('div', 'lib-ws' + (i === 0 ? ' on' : '')); w.textContent = n; side.appendChild(w); });
    const main = h('div', 'lib-main');
    const head = h('div', 'lib-head'); head.innerHTML = `<b>fieldnotes.example</b><span>2 notes · ${esc(entry.skin.name || entry.id)}</span>`;
    main.appendChild(head);
    ['Why a drop of water magnifies\nIndex 1.5 for the glass test.', 'optics/ — This path and below\nCheck the footnote on annual plans.'].forEach((t, i) => {
      const c = h('div', 'lib-card');
      if (R.library.cardStyle === 'note') {
        c.style.background = R.fill.css; c.style.borderRadius = Math.min(R.radius, 14) + 'px';
        c.style.border = R.border.w ? `1px solid ${R.border.css}` : '1px solid transparent';
        c.style.color = R.text; c.style.fontFamily = fontStack(R.font.family);
        const slot = R.palette[i + 1]; if (slot && slot.c.a > 0) c.style.backgroundImage = `linear-gradient(${slot.css}, ${slot.css})`;
      }
      const [a, b] = t.split('\n'); c.innerHTML = `<b>${esc(a)}</b><span>${esc(b)}</span>`;
      main.appendChild(c);
    });
    host.append(side, main);
  }

  // ---------- state ----------
  const state = {
    current: null, app: 'light', slot: 0, hc: false, rt: false,
    text: 'Release checklist\nNotarize the build, update the appcast, and check that the Chrome extension ID matches the host manifest.',
    editing: null // { entry, lastGood }
  };

  function resolved(entry, app, a11y) {
    const v = S.validate(entry.skin, { builtIn: entry.builtIn });
    if (v.fatal) return { v, R: null };
    return { v, R: S.resolve(v.skin, entry.assets, app, a11y) };
  }

  function select(id) {
    const e = registry.find(x => x.id === id);
    if (!e) return;
    state.current = e; state.slot = 0;
    state.editing = null;
    renderShelf(); renderPreview(); renderEditor();
  }

  // ---------- preview ----------
  function renderPreview() {
    const e = state.current; if (!e) return;
    const skin = state.editing ? state.editing.lastGood : e.skin;
    const entry = Object.assign({}, e, { skin });
    const { v, R } = resolved(entry, state.app, { increaseContrast: state.hc, reduceTransparency: state.rt });
    if (!R) return;
    const stage = $('#lab-stage');
    stage.dataset.app = state.app;
    renderSkin($('#lab-note'), R, { text: state.text, slot: state.slot, editable: true, showBar: true, showOrb: true, width: 300, onText: t => { state.text = t; } });
    renderLibrary($('#lab-lib'), R, entry);
    // palette slots
    const pal = $('#lab-palette'); pal.textContent = '';
    R.palette.forEach((p, i) => {
      const b = h('button', 'pal' + (i === state.slot ? ' on' : ''), { type: 'button', title: i === 0 ? 'Palette slot 1' : `Palette slot ${i + 1}` });
      b.style.setProperty('--c', p.c.a > 0 ? p.css : 'transparent');
      b.setAttribute('aria-label', `Palette slot ${i + 1}`);
      b.setAttribute('aria-pressed', String(i === state.slot));
      b.addEventListener('click', () => { state.slot = i; renderPreview(); });
      pal.appendChild(b);
    });
    // diagnostics
    const diags = v.diags.concat(R.notes);
    renderDiags($('#lab-diags'), diags);
    // sounds
    const snd = $('#lab-sounds'); snd.textContent = '';
    R.sounds.forEach(s => { const b = h('button', 'chipbtn', { type: 'button' }); b.textContent = `▶ ${s.name}`; b.addEventListener('click', () => { const a = new Audio(s.url); a.volume = 0.6; a.play().catch(() => {}); }); snd.appendChild(b); });
    snd.hidden = !R.sounds.length;
    $('#lab-meta').innerHTML = metaLine(e);
  }

  function kindLabel(e) { return e.label || (e.builtIn ? 'Built-in' : e.source === 'duplicated' ? 'Your copy' : 'Imported'); }
  function metaLine(e) {
    const s = e.skin;
    const parts = [`<b>${esc(s.name || s.id)}</b>`, esc(s.id)];
    if (s.author) parts.push('by ' + esc(s.author));
    if (s.version) parts.push('v' + esc(s.version));
    parts.push(kindLabel(e));
    return parts.join(' · ');
  }

  function renderDiags(host, diags) {
    host.textContent = '';
    if (!diags.length) { const li = h('li', 'ok'); li.textContent = 'No problems found. Every text and fill pair meets the contrast floor.'; host.appendChild(li); return; }
    const order = { fatal: 0, error: 1, warning: 2, info: 3 };
    diags.slice().sort((a, b) => order[a.level] - order[b.level]).forEach(d => {
      const li = h('li', d.level);
      li.innerHTML = `<span class="lvl">${d.level === 'info' ? 'Adjusted' : d.level}</span>${d.path ? `<code>${esc(d.path)}</code> ` : ''}${esc(d.msg)}`;
      host.appendChild(li);
    });
  }

  // ---------- shelf ----------
  function renderShelf() {
    const host = $('#lab-shelf'); if (!host) return;
    host.textContent = '';
    registry.forEach(e => {
      const b = h('button', 'shelf-item' + (state.current === e ? ' on' : ''), { type: 'button' });
      b.setAttribute('aria-pressed', String(state.current === e));
      const { R } = resolved(e, 'light', {});
      const sw = h('span', 'shelf-sw');
      if (R) { sw.style.background = R.fill.css; sw.style.borderRadius = Math.min(R.radius, 8) + 'px'; sw.style.border = `1px solid ${R.border.w ? R.border.css : 'rgba(0,0,0,.12)'}`; sw.style.color = R.text; sw.style.fontFamily = fontStack(R.font.family); sw.textContent = 'Aa'; }
      const t = h('span', 'shelf-t'); t.innerHTML = `<b>${esc(e.skin.name || e.id)}</b><small>${kindLabel(e)}</small>`;
      b.append(sw, t);
      b.addEventListener('click', () => select(e.id));
      host.appendChild(b);
    });
  }

  // ---------- direction cards (overview) ----------
  function renderDirections() {
    document.querySelectorAll('[data-skin-card]').forEach(card => {
      const e = registry.find(x => x.id === card.dataset.skinCard);
      const host = $('.dir-note', card);
      if (!e || !host) return;
      const app = card.dataset.app || 'light';
      const { R } = resolved(e, app, {});
      if (R) renderSkin(host, R, { text: card.dataset.text || 'Note', slot: +(card.dataset.slot || 0), width: 220 });
    });
  }

  // ---------- editor ----------
  function renderEditor() {
    const e = state.current; if (!e) return;
    const ta = $('#lab-json');
    ta.value = JSON.stringify(state.editing ? state.editing.lastGood : e.skin, null, 2);
    ta.readOnly = !!e.builtIn;
    $('#lab-dup').hidden = !e.builtIn;
    $('#lab-edit-note').textContent = e.builtIn
      ? `${kindLabel(e)} skins are protected. Duplicate this one to edit it.`
      : 'Edit the JSON and the note updates as you type. If the JSON breaks, the last good version stays on screen.';
  }
  let editTimer = 0;
  function onEdit() {
    clearTimeout(editTimer);
    editTimer = setTimeout(() => {
      const e = state.current; if (!e || e.builtIn) return;
      const p = S.parseManifest($('#lab-json').value);
      if (p.error) { renderDiags($('#lab-diags'), [{ level: 'fatal', path: 'skin.json', msg: `Can't parse: ${p.error}. Showing the last good version.` }]); return; }
      const v = S.validate(p.value, {});
      if (v.fatal) { renderDiags($('#lab-diags'), v.diags.concat([{ level: 'info', path: '', msg: 'Showing the last good version.' }])); return; }
      e.skin = p.value;
      state.editing = null;
      renderPreview(); renderShelf();
      if (!p.strict) $('#lab-diags').insertAdjacentHTML('afterbegin', '<li class="warning"><span class="lvl">warning</span>Non-strict JSON (comments or trailing commas). Webby reads it, but the validator flags it.</li>');
    }, 250);
  }
  function copyOf(e) {
    const copy = JSON.parse(JSON.stringify(e.skin));
    const slug = (copy.name || 'skin').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'skin';
    copy.id = `io.github.you.${slug}-copy`;
    copy.name = `${copy.name || 'Skin'} copy`;
    copy.author = 'You';
    copy.basedOn = e.id;
    return copy;
  }
  function duplicate() {
    const e = state.current; if (!e) return;
    const copy = copyOf(e);
    const entry = register({ id: copy.id, skin: copy, assets: e.assets, builtIn: false, source: 'duplicated' });
    select(entry.id);
    $('#lab-json').focus();
  }

  // ---------- download ----------
  // Protected skins download as the same editable copy that Duplicate to edit makes, because
  // the import checks reject the reserved webby. prefix. Names follow <Name> (<Author>).webbyskin.
  const fileName = s => `${s.name || s.id}${s.author ? ` (${s.author})` : ''}`.replace(/[\u0000-\u001f/\\:*?"<>|]+/g, '-').trim() + '.webbyskin';
  async function download(id) {
    const e = registry.find(x => x.id === id); if (!e) return;
    const skin = e.builtIn ? copyOf(e) : e.skin;
    const json = JSON.stringify(skin, null, 2) + '\n';
    let blob, name = fileName(skin);
    if (window.JSZip) {
      const zip = new window.JSZip();
      zip.file('skin.json', json);
      // No folder entries: the archive holds only allowlisted file names (plan §5.4.6).
      for (const [path, a] of e.assets) zip.file(path, await (await fetch(a.url)).arrayBuffer(), { createFolders: false });
      blob = await zip.generateAsync({ type: 'blob', mimeType: 'application/zip', compression: 'DEFLATE' });
    } else {
      blob = new Blob([json], { type: 'application/json' });
      name = 'skin.json';
    }
    const a = h('a', '', { href: URL.createObjectURL(blob), download: name });
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 10000);
    announce(window.JSZip ? `Downloaded ${name}.` : "The ZIP library didn't load, so only skin.json was downloaded.");
  }

  // ---------- import ----------
  const fmtBytes = n => n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(1)} MB`;
  const SOUND_MAGIC = b => (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46) || (b[0] === 0x46 && b[1] === 0x4F && b[2] === 0x52 && b[3] === 0x4D) || (b[0] === 0x63 && b[1] === 0x61 && b[2] === 0x66 && b[3] === 0x66);

  async function importFile(file) {
    const d = [];
    const reject = msg => showSheet({ rejected: msg, file, diags: d });
    if (file.size > S.LIMITS.archive) return reject(`The file is ${fmtBytes(file.size)}. Skins can be up to 25 MB.`);
    const lower = file.name.toLowerCase();
    let manifestText = null; const assets = new Map(); let total = 0, entriesCount = 0;
    if (lower.endsWith('.json')) {
      manifestText = await file.text();
      if (manifestText.length > S.LIMITS.manifest) return reject('skin.json is over 256 KB.');
      entriesCount = 1; total = file.size;
    } else {
      if (!window.JSZip) return reject("The ZIP reader didn't load, so .webbyskin files can't be opened here. A plain skin.json still works.");
      let zip;
      try { zip = await window.JSZip.loadAsync(file); } catch (e) { return reject(`This isn't a readable ZIP archive (${e.message}). A .webbyskin is a renamed .zip.`); }
      let files = Object.values(zip.files).filter(f => !f.dir);
      entriesCount = files.length;
      if (files.length > S.LIMITS.entries) return reject(`${files.length} entries; the limit is 400.`);
      // Tolerate one wrapper folder
      const real = files.filter(f => S.checkName(f.name) !== 'skip');
      const tops = new Set(real.map(f => f.name.split('/')[0]));
      let prefix = '';
      if (!real.some(f => f.name === 'skin.json') && tops.size === 1) { const t = [...tops][0]; if (real.every(f => f.name.startsWith(t + '/'))) prefix = t + '/'; }
      const seen = new Set();
      for (const f of files) {
        const name = f.name.startsWith(prefix) ? f.name.slice(prefix.length) : f.name;
        const kind = S.checkName(name);
        if (kind === 'skip') continue;
        if (kind === 'reject') return reject(`Unsafe entry name "${f.name}". Archives can't contain absolute paths, "..", backslashes or NUL.`);
        if (f.unixPermissions && (f.unixPermissions & 0o170000) === 0o120000) return reject(`"${f.name}" is a symbolic link. Skins can't contain links.`);
        const folded = name.normalize('NFC').toLowerCase();
        if (seen.has(folded)) return reject(`Two entries collide as "${folded}" on a case-insensitive disk.`);
        seen.add(folded);
        if (kind === 'unknown') { d.push({ level: 'warning', path: name, msg: 'Not an allowed file name; skipped. Names are lowercase, like images/note-body@2x.png.' }); continue; }
        const bytes = await f.async('uint8array');
        total += bytes.length;
        if (total > S.LIMITS.total) return reject('More than 64 MB once decompressed.');
        if (name === 'skin.json') {
          if (bytes.length > S.LIMITS.manifest) return reject('skin.json is over 256 KB.');
          manifestText = new TextDecoder().decode(bytes);
        } else if (name.endsWith('.png')) {
          if (bytes.length > S.LIMITS.image) { d.push({ level: 'error', path: name, msg: 'Image is over 4 MB; skipped.' }); continue; }
          const dim = S.pngSize(bytes);
          if (!dim) { d.push({ level: 'error', path: name, msg: "Not a PNG (checked by its first bytes); skipped." }); continue; }
          if (dim.w > S.LIMITS.side || dim.h > S.LIMITS.side) { d.push({ level: 'error', path: name, msg: `${dim.w}×${dim.h} px is over 2048 px per side; skipped.` }); continue; }
          if (!/@2x\.png$/.test(name) && !name.startsWith('preview')) d.push({ level: 'warning', path: name, msg: 'Only @1x; it will look blurry on Retina screens.' });
          assets.set(name, { url: URL.createObjectURL(new Blob([bytes], { type: 'image/png' })), w: dim.w, h: dim.h, bytes: bytes.length });
        } else {
          if (bytes.length > S.LIMITS.sound) { d.push({ level: 'error', path: name, msg: 'Sound is over 1 MB; skipped.' }); continue; }
          if (!SOUND_MAGIC(bytes)) { d.push({ level: 'error', path: name, msg: 'Not a WAV, AIFF or CAF file; skipped.' }); continue; }
          assets.set(name, { url: URL.createObjectURL(new Blob([bytes])), bytes: bytes.length });
        }
      }
      let px = 0; assets.forEach(a => { if (a.w) px += a.w * a.h; });
      if (px > S.LIMITS.pixels) return reject('Images add up to more than 24 megapixels.');
    }
    if (manifestText === null) return reject('No skin.json at the top level of the archive.');
    const p = S.parseManifest(manifestText);
    if (p.error) return reject(`skin.json isn't valid JSON: ${p.error}`);
    if (!p.strict) d.push({ level: 'warning', path: 'skin.json', msg: 'Non-strict JSON (comments or trailing commas).' });
    const v = S.validate(p.value, {});
    if (v.fatal) return reject(v.diags.find(x => x.level === 'fatal').msg);
    const entry = { id: v.skin.id, skin: p.value, assets, builtIn: false, source: 'imported', bytes: file.size };
    showSheet({ entry, file, diags: d.concat(v.diags), entriesCount, total, replaces: registry.some(e => e.id === v.skin.id && !e.builtIn) });
  }

  // ---------- install sheet ----------
  function showSheet(o) {
    const sheet = $('#lab-sheet');
    sheet.hidden = false;
    $('#lab-editor').hidden = true;
    const body = $('#sheet-body'); body.textContent = '';
    const title = $('#sheet-title');
    const actions = $('#sheet-actions'); actions.textContent = '';
    const cancel = h('button', 'btn', { type: 'button', textContent: o.rejected ? 'Close' : 'Cancel' });
    cancel.addEventListener('click', closeSheet);
    if (o.rejected) {
      title.textContent = `Can't install “${o.file.name}”`;
      const p = h('p', 'sheet-reject'); p.textContent = o.rejected;
      body.appendChild(p);
      if (o.diags.length) { const ul = h('ul', 'diags'); renderDiags(ul, o.diags); body.appendChild(ul); }
      actions.appendChild(cancel);
      return;
    }
    const s = o.entry.skin;
    title.textContent = `Install “${s.name || s.id}”?`;
    const meta = h('p', 'sheet-meta');
    meta.innerHTML = [esc(s.id), s.author ? 'by ' + esc(s.author) : null, s.version ? 'v' + esc(s.version) : null, s.license ? esc(s.license) : null, `${o.entriesCount} files`, fmtBytes(o.file.size)].filter(Boolean).join(' · ');
    body.appendChild(meta);
    if (s.description) { const p = h('p', 'sheet-desc'); p.textContent = s.description; body.appendChild(p); }
    const groups = ['surface', 'typography', 'header', 'collapsed', 'decoration', 'icons', 'resizeHandle', 'palette', 'library', 'voiceOrb', 'sounds'];
    const given = groups.filter(g => s[g] !== undefined).length;
    let imgs = 0, snds = 0; o.entry.assets.forEach((a, k) => { if (k.startsWith('images/')) imgs++; else if (k.startsWith('sounds/')) snds++; });
    const cov = h('p', 'sheet-meta');
    cov.textContent = `Provides ${given} of ${groups.length} groups, ${imgs} image${imgs === 1 ? '' : 's'} and ${snds} sound${snds === 1 ? '' : 's'}. Everything else comes from Clear. Images and sounds only, no code.`;
    body.appendChild(cov);
    const pv = h('div', 'sheet-previews');
    ['light', 'dark'].forEach(app => {
      const cell = h('div', 'sheet-pv'); cell.dataset.app = app;
      const { R } = resolved(o.entry, app, {});
      const n = h('div', 'sheet-note'); cell.appendChild(n);
      const lab = h('span', 'label flat'); lab.textContent = app === 'light' ? 'Light' : 'Dark';
      cell.appendChild(lab);
      pv.appendChild(cell);
      if (R) renderSkin(n, R, { text: 'Preview\nThis is how notes will look with this skin.', width: 210 });
    });
    body.appendChild(pv);
    const { R } = resolved(o.entry, 'light', {});
    const ul = h('ul', 'diags'); renderDiags(ul, o.diags.concat(R ? R.notes : [])); body.appendChild(ul);
    if (s.credits && Array.isArray(s.credits) && s.credits.length) { const c = h('p', 'sheet-meta'); c.textContent = 'Credits: ' + s.credits.map(x => `${x.name}${x.role ? ` (${x.role})` : ''}`).join(', '); body.appendChild(c); }
    const install = h('button', 'btn primary', { type: 'button', textContent: o.replaces ? 'Replace and install' : 'Install' });
    install.addEventListener('click', () => { register(o.entry); closeSheet(); select(o.entry.id); announce(`Installed ${s.name || s.id}.`); });
    actions.append(cancel, install);
    install.focus();
  }
  function closeSheet() { $('#lab-sheet').hidden = true; $('#lab-editor').hidden = false; }
  function announce(msg) { const a = $('#lab-live'); a.textContent = msg; }

  // ---------- wire up ----------
  function init() {
    if (!$('#lab')) return;
    const drop = $('#lab-drop'), input = $('#lab-file');
    input.addEventListener('change', () => { if (input.files[0]) importFile(input.files[0]); input.value = ''; });
    ['dragenter', 'dragover'].forEach(t => drop.addEventListener(t, e => { e.preventDefault(); drop.classList.add('over'); }));
    ['dragleave', 'drop'].forEach(t => drop.addEventListener(t, e => { e.preventDefault(); drop.classList.remove('over'); }));
    drop.addEventListener('drop', e => { const f = e.dataTransfer && e.dataTransfer.files[0]; if (f) importFile(f); });
    $('#lab-json').addEventListener('input', onEdit);
    $('#lab-dup').addEventListener('click', duplicate);
    $('#lab-download').addEventListener('click', () => { if (state.current) download(state.current.id); });
    document.querySelectorAll('[data-download]').forEach(b => b.addEventListener('click', () => download(b.dataset.download)));
    $('#lab-copy').addEventListener('click', () => {
      const ta = $('#lab-json');
      const done = () => { $('#lab-copy').textContent = 'Copied'; setTimeout(() => { $('#lab-copy').textContent = 'Copy skin.json'; }, 1400); };
      (navigator.clipboard ? navigator.clipboard.writeText(ta.value) : Promise.reject()).then(done, () => { ta.focus(); ta.select(); });
    });
    document.querySelectorAll('[data-app-toggle]').forEach(b => b.addEventListener('click', () => {
      state.app = b.dataset.appToggle;
      document.querySelectorAll('[data-app-toggle]').forEach(x => x.setAttribute('aria-pressed', String(x === b)));
      renderPreview();
    }));
    $('#lab-hc').addEventListener('change', e => { state.hc = e.target.checked; renderPreview(); });
    $('#lab-rt').addEventListener('change', e => { state.rt = e.target.checked; renderPreview(); });
    document.querySelectorAll('[data-try]').forEach(b => b.addEventListener('click', () => { select(b.dataset.try); $('#lab').scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth', block: 'start' }); }));
    if (registry.length) select(registry[0].id);
  }
  window.WebbyLab.init = init;
})();
