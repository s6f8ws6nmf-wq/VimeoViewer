// Vimeo Viewer pre Windows – rozhranie
'use strict';
const $ = id => document.getElementById(id);
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const LS = {
  get: (k, d) => { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set: (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
};

function fmt(t) {
  const s = Math.max(0, Math.floor(t || 0)), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(x).padStart(2, '0')}` : `${m}:${String(x).padStart(2, '0')}`;
}
function parseTime(str) {
  str = String(str || '').trim().toLowerCase();
  if (!str) return null;
  if (str.includes(':')) { let t = 0; for (const p of str.split(':')) { const v = parseFloat(p); if (isNaN(v)) return null; t = t * 60 + v; } return t; }
  if (/^[\d.]+$/.test(str)) return parseFloat(str);
  let t = 0; const re = /([\d.]+)([hms])/g; let m, any = false;
  while ((m = re.exec(str))) { any = true; t += parseFloat(m[1]) * ({ h: 3600, m: 60, s: 1 }[m[2]]); }
  return any ? t : null;
}
const TS_RE = /\b(?:\d{1,2}:)?\d{1,2}:\d{2}\b/g;
function toast(msg) { const t = $('toast'); t.textContent = msg; t.classList.remove('hidden'); clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.add('hidden'), 2500); }
const log = (src, msg) => vv.diagLog(src, msg);

function videoRefFromURL(raw) {
  let u; try { u = new URL(raw); } catch { return null; }
  if (!/vimeo\.com$/i.test(u.hostname)) return null;
  const c = u.pathname.split('/').filter(Boolean);
  const num = s => /^\d+$/.test(s || ''), hex = s => /^[0-9a-f]{6,24}$/i.test(s || '');
  let id = null, hash = null;
  if (u.hostname === 'player.vimeo.com') { if (c[0] === 'video' && num(c[1])) id = c[1]; }
  else if (num(c[0])) { id = c[0]; if (hex(c[1])) hash = c[1]; }
  else for (let i = 0; i < c.length - 1; i++) if ((c[i] === 'video' || c[i] === 'videos') && num(c[i + 1])) { id = c[i + 1]; if (hex(c[i + 2])) hash = c[i + 2]; break; }
  if (!id) return null;
  if (!hash && hex(u.searchParams.get('h'))) hash = u.searchParams.get('h');
  return { id, hash };
}
const apiPath = ref => ref.hash ? `/videos/${ref.id}:${ref.hash}` : `/videos/${ref.id}`;
const pageURL = (ref, t) => `https://vimeo.com/${ref.id}${ref.hash ? '/' + ref.hash : ''}${t >= 1 ? '#t=' + Math.floor(t) + 's' : ''}`;

// ====================================================== Režimy
let mode = 'library';
function setMode(m) {
  mode = m;
  $('viewLibrary').classList.toggle('active', m === 'library');
  $('viewVideo').classList.toggle('active', m === 'video');
  $('tabLibrary').classList.toggle('active', m === 'library');
  $('tabVideo').classList.toggle('active', m === 'video');
  if (m === 'library') { pause(); setTitle('Knižnica', ''); $('address').value = ''; Library.show(); }
  else { setTitle(Video.title || (Video.ref ? 'Načítavam…' : 'Video'), Video.author || ''); $('address').value = Video.ref ? pageURL(Video.ref) : ''; }
}
function setTitle(t, s) { $('winTitle').textContent = t; $('winSub').textContent = s || ''; document.title = t + ' – Vimeo Viewer'; }

$('tabLibrary').onclick = () => setMode('library');
$('tabVideo').onclick = () => setMode('video');
$('btnBack').onclick = () => { if (mode === 'video') setMode('library'); else Library.up(); };
$('btnHome').onclick = () => { setMode('library'); Library.goRoot(); };
$('btnBrowse').onclick = () => vv.openBrowse('https://vimeo.com/');
$('btnLogin').onclick = () => Account.login();
$('btnReload').onclick = () => { if (mode === 'library') Library.reload(); else if (Video.ref) Video.open({ ...Video.ref }, Player.time); };
$('address').addEventListener('keydown', e => {
  if (e.key !== 'Enter') return;
  const s = e.target.value.trim(); if (!s) return;
  if (/^\d+$/.test(s)) { Video.open({ id: s, hash: null }); return; }
  let u = s; if (!/^[a-z]+:/i.test(u) && /\./.test(u) && !/\s/.test(u)) u = 'https://' + u;
  if (/^(https?|vimeoviewer):/i.test(u)) { vv.route(u); return; }
  setMode('library'); Library.search(s);
});
$('btnMenu').onclick = async () => {
  const id = await vv.menu([
    { id: 'login', label: 'Prihlásiť sa do Vimea…' }, { id: 'logout', label: 'Odhlásiť sa' }, '-',
    { id: 'upload', label: 'Nahrať video… (Ctrl+U)' }, { id: 'transfers', label: 'Prenosy (nahrávanie a sťahovanie)' }, '-',
    { id: 'settings', label: 'Nastavenia…' }, { id: 'updates', label: 'Skontrolovať aktualizácie…' }, '-',
    { id: 'help', label: 'Návod k aplikácii (F1)' }, { id: 'diag', label: 'Diagnostika…' }, { id: 'about', label: 'O aplikácii' }]);
  ({ login: () => Account.login(), logout: () => Account.logout(), upload: () => { setMode('library'); Library.upload(); },
     transfers: () => Transfers.show(), settings: () => Settings.show(), updates: () => vv.checkUpdates(), help: () => Help.show(),
     diag: () => Diagnostics.show(), about: async () => { const i = await vv.appInfo(); Modal.alert('Vimeo Viewer', `Verzia ${i.version} · Windows\nNUNEZ NFE`); } }[id] || (() => {}))();
};
document.addEventListener('keydown', e => {
  if (e.key === 'F1') { e.preventDefault(); Help.show(); }
  if (e.ctrlKey && e.key === 'Enter') { e.preventDefault(); Player.toggle(); }
  if (e.ctrlKey && e.key.toLowerCase() === 'k') { e.preventDefault(); Comments.begin(); }
  if (e.ctrlKey && e.key.toLowerCase() === 'u') { e.preventDefault(); setMode('library'); Library.upload(); }
  if (e.ctrlKey && e.key.toLowerCase() === 'f' && mode === 'video') { e.preventDefault(); $('tSearch').focus(); }
  if (e.ctrlKey && e.key === '1') setMode('library');
  if (e.ctrlKey && e.key === '2') setMode('video');
});

// ====================================================== Modálne okná
const Modal = {
  open(html) { $('modalBox').innerHTML = html; $('modal').classList.remove('hidden'); },
  close() { $('modal').classList.add('hidden'); $('modalBox').innerHTML = ''; },
  alert(title, text) {
    this.open(`<h2>${esc(title)}</h2><p style="white-space:pre-wrap">${esc(text)}</p><div class="btns"><button class="primary" id="mOk">OK</button></div>`);
    $('mOk').onclick = () => this.close();
  },
  confirm(title, text, ok = 'OK') {
    return new Promise(res => {
      this.open(`<h2>${esc(title)}</h2><p style="white-space:pre-wrap">${esc(text)}</p><div class="btns"><button id="mNo">Zrušiť</button><button class="primary" id="mYes">${esc(ok)}</button></div>`);
      $('mNo').onclick = () => { this.close(); res(false); };
      $('mYes').onclick = () => { this.close(); res(true); };
    });
  },
};
$('modal').addEventListener('mousedown', e => { if (e.target.id === 'modal') Modal.close(); });

// ====================================================== Účet
const Account = {
  async login() {
    const r = await vv.login();
    if (r && r.ok) { toast('✓ Prihlásený ako ' + r.name); await vv.resetSession(); Library.reloadAll(); if (Video.ref) Comments.load(Video.ref); }
  },
  async logout() {
    if (!await Modal.confirm('Odhlásiť sa?', 'Odhlásite sa z Vimea v tejto aplikácii.', 'Odhlásiť')) return;
    await vv.logout(); Library.reloadAll();
  },
};

// ====================================================== Knižnica
const ITEM_FIELDS = 'type,folder.uri,folder.name,folder.modified_time,video.uri,video.name,video.duration,video.created_time,video.modified_time,video.link,video.pictures.sizes,video.privacy.view';
const VIDEO_FIELDS = 'uri,name,duration,created_time,modified_time,link,pictures.sizes,privacy.view';
const Library = {
  roots: [], stack: [], rows: [], next: null, nextItems: true, loading: false, req: 0, query: null, loaded: false,
  favorites: LS.get('favorites', []),
  get owner() { return this.stack[0] ? this.stack[0].owner : '/me'; },

  show() { if (!this.loaded) this.reloadAll(); },

  async reloadAll() {
    this.loaded = true; this.roots = []; this.renderTree(); this.rows = []; this.renderGrid();
    this.status('Načítavam knižnicu…');
    const me = await vv.api('GET', '/me?fields=name,uri');
    if (!me.ok) { this.status('Na zobrazenie knižnice sa prihláste do Vimea (ikona osoby hore vpravo).'); return; }
    this.roots = [{ title: me.json.name || 'Moja knižnica', owner: '/me', folder: null, children: null, open: true, icon: '🎬' }];
    const teams = await vv.api('GET', '/me/teams?per_page=50');
    const seen = new Set([me.json.uri]);
    for (const t of (teams.ok && teams.json.data) || []) {
      const o = t.owner || t.user || t;
      if (!o || !o.uri || !o.uri.startsWith('/users/') || seen.has(o.uri)) continue;
      seen.add(o.uri);
      this.roots.push({ title: o.name || t.name || 'Tím', owner: o.uri, folder: null, children: null, open: false, icon: '👥' });
    }
    const savedOwner = LS.get('libOwner', '/me');
    const root = this.roots.find(r => r.owner === savedOwner) || this.roots[0];
    this.stack = [{ title: root.title, owner: root.owner, folder: null }];
    for (const l of LS.get('libPath', [])) if (l.owner === root.owner) this.stack.push(l);
    root.open = true;
    this.loadChildren(root);
    this.load();
  },

  async loadChildren(node) {
    if (node.children || node.loading) return;
    node.loading = true;
    let path = (node.folder ? `${node.folder}/items` : `${node.owner}/folders/root`) + '?per_page=100&fields=type,folder.uri,folder.name';
    const kids = [];
    while (path) {
      const r = await vv.api('GET', path);
      if (!r.ok) break;
      for (const d of r.json.data || []) if (d.type === 'folder' && d.folder) kids.push({ title: d.folder.name, owner: node.owner, folder: d.folder.uri, parent: node, children: null, open: false, icon: '📁' });
      path = r.json.paging && r.json.paging.next;
    }
    node.children = kids; node.loading = false;
    this.renderTree();
  },

  renderTree() {
    const tree = $('tree'); tree.innerHTML = '';
    const cur = this.stack[this.stack.length - 1];
    if (this.favorites.length) {
      tree.insertAdjacentHTML('beforeend', '<div class="thead">OBĽÚBENÉ</div>');
      for (const f of this.favorites) {
        const d = document.createElement('div');
        d.className = 'tnode' + (cur && cur.folder === f.uri && this.owner === f.owner ? ' sel' : '');
        d.innerHTML = `<span class="tw"></span>⭐ ${esc(f.path[f.path.length - 1].title)}`;
        d.onclick = () => this.openFavorite(f);
        d.oncontextmenu = async e => { e.preventDefault(); if (await vv.menu([{ id: 'rm', label: 'Odobrať z obľúbených' }]) === 'rm') this.toggleFav(f.owner, f.path); };
        tree.appendChild(d);
      }
      tree.insertAdjacentHTML('beforeend', '<div class="thead">KNIŽNICE</div>');
    }
    const add = (node, depth) => {
      const d = document.createElement('div');
      const sel = cur && node.owner === this.owner && node.folder === cur.folder && !(this.favorites.length && cur.folder && this.isFav(node.owner, node.folder) && false);
      d.className = 'tnode' + (sel ? ' sel' : '');
      d.style.paddingLeft = (6 + depth * 14) + 'px';
      const expandable = !node.children || node.children.length;
      d.innerHTML = `<span class="tw">${expandable ? (node.open ? '▾' : '▸') : ''}</span>${node.icon} ${esc(node.title)}`;
      d.title = node.title;
      d.querySelector('.tw').onclick = e => { e.stopPropagation(); node.open = !node.open; if (node.open) this.loadChildren(node); this.renderTree(); };
      d.onclick = () => { node.open = true; this.loadChildren(node); this.openNode(node); };
      d.oncontextmenu = async e => {
        e.preventDefault(); if (!node.folder) return;
        const fav = this.isFav(node.owner, node.folder);
        if (await vv.menu([{ id: 'fav', label: fav ? 'Odobrať z obľúbených' : 'Pridať medzi obľúbené' }]) === 'fav') this.toggleFav(node.owner, this.nodePath(node));
      };
      tree.appendChild(d);
      if (node.open && node.children) for (const c of node.children) add(c, depth + 1);
    };
    for (const r of this.roots) add(r, 0);
  },

  nodePath(node) { const p = []; for (let n = node; n; n = n.parent) p.unshift({ title: n.title, owner: n.owner, folder: n.folder }); return p; },
  openNode(node) { this.stack = this.nodePath(node); this.query = null; $('libSearch').value = ''; this.load(); },
  openFavorite(f) { this.stack = f.path.map(p => ({ ...p })); this.query = null; this.load(); },
  isFav(owner, uri) { return this.favorites.some(f => f.owner === owner && f.uri === uri); },
  toggleFav(owner, path) {
    const uri = path[path.length - 1].folder;
    if (!uri) return;
    const i = this.favorites.findIndex(f => f.owner === owner && f.uri === uri);
    if (i >= 0) this.favorites.splice(i, 1); else this.favorites.push({ owner, uri, path });
    LS.set('favorites', this.favorites);
    this.renderTree(); this.renderCrumbs(); this.renderGrid();
  },

  up() { if (this.query) { this.query = null; $('libSearch').value = ''; } else if (this.stack.length > 1) this.stack.pop(); else return; this.load(); },
  goRoot() { if (this.stack.length) { this.stack = [this.stack[0]]; this.query = null; this.load(); } },
  reload() { this.load(); },
  search(q) { this.query = q || null; $('libSearch').value = q || ''; this.load(); },

  renderCrumbs() {
    const c = $('crumbs'); c.innerHTML = '';
    this.stack.forEach((l, i) => {
      if (i) c.insertAdjacentHTML('beforeend', '<span class="small">›</span>');
      const a = document.createElement('a');
      a.textContent = l.title; a.className = (i === this.stack.length - 1 && !this.query) ? 'last' : '';
      a.onclick = () => { this.stack = this.stack.slice(0, i + 1); this.query = null; $('libSearch').value = ''; this.load(); };
      c.appendChild(a);
    });
    if (this.query) c.insertAdjacentHTML('beforeend', '<span class="small">›</span><a class="last">Výsledky hľadania</a>');
    const cur = this.stack[this.stack.length - 1];
    const canStar = this.stack.length > 1 && !this.query;
    $('btnStar').classList.toggle('hidden', !canStar);
    if (canStar) $('btnStar').textContent = this.isFav(this.owner, cur.folder) ? '★' : '☆';
  },

  async load() {
    const cur = this.stack[this.stack.length - 1]; if (!cur) return;
    LS.set('libOwner', this.owner);
    LS.set('libPath', this.stack.slice(1));
    this.renderCrumbs(); this.renderTree();
    const id = ++this.req; this.rows = []; this.next = null; this.renderGrid(); this.status('Načítavam…');
    let path, items = true;
    if (this.query) { path = `${this.owner}/videos?per_page=50&query=${encodeURIComponent(this.query)}&fields=${VIDEO_FIELDS}`; items = false; }
    else if (cur.folder) path = `${cur.folder}/items?per_page=100&fields=${ITEM_FIELDS}`;
    else path = `${this.owner}/folders/root?per_page=100&fields=${ITEM_FIELDS}`;
    await this.fetch(path, id, items);
  },

  async fetch(path, id, items) {
    this.loading = true; this.nextItems = items;
    const r = await vv.api('GET', path);
    if (id !== this.req) return;
    this.loading = false;
    if (!r.ok) {
      if (!this.rows.length) {
        if (this.stack.length > 1 && !this.query) { this.stack = [this.stack[0]]; this.load(); }
        else this.status('Obsah sa nepodarilo načítať. ' + r.error);
      }
      return;
    }
    for (const d of r.json.data || []) {
      if (items) {
        if (d.type === 'folder' && d.folder) this.rows.push({ folder: true, uri: d.folder.uri, name: d.folder.name, date: d.folder.modified_time });
        else if (d.video) { const v = this.parse(d.video); if (v) this.rows.push(v); }
      } else { const v = this.parse(d); if (v) this.rows.push(v); }
    }
    this.rows.sort((a, b) => (b.folder ? 1 : 0) - (a.folder ? 1 : 0));
    this.next = r.json.paging && r.json.paging.next;
    this.renderGrid();
    this.status(this.rows.length ? '' : (this.query ? 'Nič sa nenašlo.' : 'Prázdny priečinok.'));
  },

  parse(v) {
    let ref = v.link ? videoRefFromURL(v.link) : null;
    if (!ref && v.uri) { const id = v.uri.split('/').pop(); if (/^\d+$/.test(id)) ref = { id, hash: null }; }
    if (!ref) return null;
    const sizes = (v.pictures && v.pictures.sizes) || [];
    const pic = sizes.find(s => s.width >= 295) || sizes[sizes.length - 1];
    return { folder: false, ref, name: v.name || '(bez názvu)', duration: v.duration || 0, date: v.created_time || v.modified_time,
             thumb: pic && pic.link, privacy: v.privacy && v.privacy.view };
  },

  status(s) { const el = $('libStatus'); el.textContent = s; el.classList.toggle('hidden', !s); },

  renderGrid() {
    const g = $('grid'); g.innerHTML = '';
    const df = d => d ? new Date(d).toLocaleDateString('sk-SK') : '';
    const priv = { anybody: 'Verejné', unlisted: 'Nezverejnené', nobody: 'Súkromné', password: 'Súkromné', disable: 'Súkromné', users: 'Súkromné', contacts: 'Súkromné', team: 'Súkromné' };
    this.rows.forEach(row => {
      const c = document.createElement('div'); c.className = 'card';
      if (row.folder) {
        const fav = this.isFav(this.owner, row.uri);
        c.innerHTML = `<div class="thumb folder">📁</div><div class="t">${esc(row.name)}</div><div class="m">${fav ? '★ ' : ''}Priečinok${row.date ? ' · ' + df(row.date) : ''}</div>`;
        c.onclick = () => { this.stack.push({ title: row.name, owner: this.owner, folder: row.uri }); this.query = null; $('libSearch').value = ''; this.load(); };
        c.oncontextmenu = async e => {
          e.preventDefault();
          const id = await vv.menu([{ id: 'open', label: 'Otvoriť' }, { id: 'fav', label: fav ? 'Odobrať z obľúbených' : 'Pridať medzi obľúbené' }]);
          if (id === 'open') c.onclick();
          if (id === 'fav') this.toggleFav(this.owner, [...this.stack, { title: row.name, owner: this.owner, folder: row.uri }]);
        };
      } else {
        const meta = [row.duration ? fmt(row.duration) : '', df(row.date), priv[row.privacy] || ''].filter(Boolean).join(' · ');
        c.innerHTML = `<div class="thumb" style="background-image:url('${esc(row.thumb || '')}')"></div><div class="t" title="${esc(row.name)}">${esc(row.name)}</div><div class="m">${esc(meta)}</div>`;
        c.onclick = () => Video.open(row.ref);
        c.oncontextmenu = async e => {
          e.preventDefault();
          const id = await vv.menu([{ id: 'open', label: 'Otvoriť' }, { id: 'dl', label: 'Stiahnuť…' }, { id: 'copy', label: 'Kopírovať odkaz' }]);
          if (id === 'open') Video.open(row.ref);
          if (id === 'dl') Share.download(row.ref, row.name);
          if (id === 'copy') { vv.copy(pageURL(row.ref)); toast('✓ Odkaz skopírovaný'); }
        };
      }
      g.appendChild(c);
    });
  },

  async upload() {
    const files = await vv.chooseFiles({ multiple: true, title: 'Vyberte videá na nahratie', filters: [{ name: 'Videá', extensions: ['mp4', 'mov', 'm4v', 'avi', 'mkv', 'mxf', 'webm', 'wmv'] }] });
    const cur = this.stack[this.stack.length - 1];
    for (const f of files) vv.upload({ kind: 'upload', file: f, owner: this.owner, folder: cur && cur.folder });
    if (files.length) Transfers.show();
  },
};
$('grid').addEventListener('scroll', e => {
  const g = e.target;
  if (Library.next && !Library.loading && g.scrollTop + g.clientHeight > g.scrollHeight - 400) {
    const n = Library.next; Library.next = null; Library.fetch(n, Library.req, Library.nextItems);
  }
});
$('libSearch').addEventListener('keydown', e => { if (e.key === 'Enter') Library.search(e.target.value.trim()); });
$('libRefresh').onclick = () => Library.reload();
$('btnUpload').onclick = () => Library.upload();
$('btnStar').onclick = () => Library.toggleFav(Library.owner, Library.stack);
vv.on('upload-finished', () => { if (mode === 'library') Library.reload(); });

// ====================================================== Prehrávač
const Player = {
  p: null, time: 0, duration: 0,
  load(ref, start) {
    const box = $('playerBox'); box.innerHTML = '';
    let src = `https://player.vimeo.com/video/${ref.id}?autoplay=1&title=0&byline=0&portrait=0&pip=1&controls=0&keyboard=1`;
    if (ref.hash) src += `&h=${ref.hash}`;
    if (start >= 1) src += `#t=${Math.floor(start)}s`;
    const f = document.createElement('iframe');
    f.src = src; f.allow = 'autoplay; fullscreen; picture-in-picture; clipboard-write'; f.allowFullscreen = true;
    box.appendChild(f);
    this.time = start || 0; this.duration = 0;
    if (typeof Vimeo === 'undefined') { log('Prehrávač', 'player.js sa nenačítal'); return; }
    const p = this.p = new Vimeo.Player(f);
    p.on('timeupdate', d => { this.time = d.seconds; this.duration = d.duration; Controls.time(d.seconds, d.duration); Transcript.update(d.seconds); Share.updateTime(d.seconds); });
    const st = () => Promise.all([p.getPaused(), p.getVolume(), p.getPlaybackRate().catch(() => 1), p.getMuted().catch(() => false)])
      .then(([paused, vol, rate, muted]) => Controls.state(paused, vol, rate, muted)).catch(() => {});
    const opts = () => Promise.all([p.getTextTracks().catch(() => []), p.getQualities().catch(() => [])]).then(([t, q]) => Controls.options(t, q));
    ['play', 'pause', 'ended', 'volumechange', 'playbackratechange'].forEach(ev => p.on(ev, st));
    ['loaded', 'texttrackchange', 'qualitychange'].forEach(ev => p.on(ev, () => { st(); opts(); }));
    p.on('error', e => log('Prehrávač', (e && (e.message || e.name)) || 'chyba'));
    p.ready().then(() => { st(); opts(); }).catch(e => log('Prehrávač', String(e && e.message || e)));
  },
  seek(t) { if (this.p) this.p.setCurrentTime(Math.max(0, t)).then(() => this.p.play()).catch(() => {}); },
  toggle() { if (this.p) this.p.getPaused().then(x => x ? this.p.play() : this.p.pause()).catch(() => {}); },
  skip(d) { if (this.p) this.p.getCurrentTime().then(t => this.p.setCurrentTime(Math.max(0, t + d))).catch(() => {}); },
};
function pause() { if (Player.p) Player.p.pause().catch(() => {}); }

const Controls = {
  muted: false, lastVol: 1,
  time(t, d) {
    $('cTime').textContent = `${fmt(t)} / ${fmt(d)}`;
    const pct = d > 0 ? Math.min(100, t / d * 100) : 0;
    $('tlPlayed').style.width = pct + '%'; $('tlHead').style.left = pct + '%';
    if (d !== this.lastDur) { this.lastDur = d; Timeline.render(); }
  },
  state(paused, vol, rate, muted) {
    $('cPlay').textContent = paused ? '▶' : '⏸';
    this.muted = muted || vol === 0; if (vol > 0) this.lastVol = vol;
    $('cVol').value = this.muted ? 0 : vol; $('cMute').textContent = this.muted ? '🔇' : '🔊';
    $('cRate').value = String(rate);
  },
  options(tracks, qualities) {
    const cc = $('cCC');
    cc.innerHTML = '<option value="">CC vyp.</option>' + tracks.map(t => `<option value="${esc(t.language)}|${esc(t.kind)}" ${t.mode === 'showing' ? 'selected' : ''}>${esc(t.label || t.language)}</option>`).join('');
    cc.disabled = !tracks.length;
    const q = $('cQuality');
    q.innerHTML = qualities.length ? qualities.map(x => `<option value="${esc(x.id)}" ${x.active ? 'selected' : ''}>${esc(x.id === 'auto' ? 'Auto' : x.label)}</option>`).join('') : '<option>Auto</option>';
    q.disabled = qualities.length < 2;
  },
};
$('cPlay').onclick = () => Player.toggle();
$('cBack').onclick = () => Player.skip(-10);
$('cFwd').onclick = () => Player.skip(10);
$('cVol').oninput = e => { const v = parseFloat(e.target.value); if (Player.p) { Player.p.setVolume(v).catch(() => {}); Player.p.setMuted(v === 0).catch(() => {}); } };
$('cMute').onclick = () => { const v = Controls.muted ? (Controls.lastVol || 1) : 0; $('cVol').value = v; $('cVol').oninput({ target: $('cVol') }); };
$('cRate').onchange = e => Player.p && Player.p.setPlaybackRate(parseFloat(e.target.value)).catch(() => toast('Rýchlosť pre toto video nie je dostupná'));
$('cCC').onchange = e => { if (!Player.p) return; const v = e.target.value; if (!v) Player.p.disableTextTrack().catch(() => {}); else { const [l, k] = v.split('|'); Player.p.enableTextTrack(l, k).catch(() => {}); } };
$('cQuality').onchange = e => Player.p && Player.p.setQuality(e.target.value).catch(() => toast('Kvalitu nie je možné zmeniť'));
$('cPip').onclick = () => Player.p && Player.p.requestPictureInPicture().catch(() => toast('Obraz v obraze nie je dostupný'));
$('cFull').onclick = () => Player.p && Player.p.requestFullscreen().catch(() => document.documentElement.requestFullscreen());

const Timeline = {
  markers: [],
  set(m) { this.markers = m; this.render(); },
  render() {
    const box = $('tlMarkers'); box.innerHTML = '';
    const d = Player.duration; if (!d) return;
    for (const m of this.markers) {
      const el = document.createElement('div');
      el.className = 'marker' + (m.collab ? ' collab' : '');
      el.style.left = Math.min(100, m.time / d * 100) + '%';
      el.title = `${fmt(m.time)}  ${m.text}`;
      el.onclick = e => { e.stopPropagation(); Player.seek(m.time); };
      box.appendChild(el);
    }
  },
};
$('timeline').onclick = e => {
  const r = e.currentTarget.getBoundingClientRect();
  if (Player.duration) Player.seek((e.clientX - r.left) / r.width * Player.duration);
};

// ====================================================== Video (otvorenie)
const Video = {
  ref: null, title: null, author: null,
  async open(ref, start) {
    const same = this.ref && this.ref.id === ref.id && this.ref.hash === ref.hash;
    setMode('video');
    if (same && start == null) return;
    this.ref = { id: ref.id, hash: ref.hash }; this.title = null; this.author = null;
    $('placeholder') && $('placeholder').remove();
    Player.load(this.ref, start || 0);
    Transcript.load(this.ref); Comments.load(this.ref); Share.load(this.ref);
    $('address').value = pageURL(this.ref);
    setTitle('Načítavam…', '');
    const r = await vv.api('GET', `${apiPath(this.ref)}?fields=name,user.name,link`);
    if (r.ok && r.json.name) { this.title = r.json.name; this.author = r.json.user && r.json.user.name; }
    else {
      try { const o = await (await fetch('https://vimeo.com/api/oembed.json?url=' + encodeURIComponent(pageURL(this.ref)))).json(); this.title = o.title; this.author = o.author_name; } catch {}
    }
    if (!this.title) this.title = 'vimeo.com/' + this.ref.id;
    if (mode === 'video') setTitle(this.title, this.author);
  },
};
vv.on('open-video', ref => Video.open(ref));

// ====================================================== Prepis
const LANGS = [['Slovenčina', 'sk'], ['Čeština', 'cs'], ['English', 'en'], ['Deutsch', 'de'], ['Italiano', 'it'], ['Español', 'es'], ['Français', 'fr'], ['Magyar', 'hu'], ['Polski', 'pl'], ['Українська', 'uk'], ['Русский', 'ru'], ['Português', 'pt'], ['Nederlands', 'nl'], ['Hrvatski', 'hr'], ['Română', 'ro']];
const langName = c => { try { return new Intl.DisplayNames(['sk'], { type: 'language' }).of(c.slice(0, 2)); } catch { return c; } };
function parseVTT(s) {
  const out = [];
  const blocks = s.replace(/\r\n?/g, '\n').split(/\n\n+/);
  const stamp = x => { const p = x.trim().split(/\s+/)[0].replace(',', '.').split(':'); let t = 0; for (const v of p) { const n = parseFloat(v); if (isNaN(n)) return null; t = t * 60 + n; } return t; };
  for (const b of blocks) {
    const lines = b.split('\n').filter(Boolean);
    const i = lines.findIndex(l => l.includes('-->'));
    if (i < 0) continue;
    const [a, z] = lines[i].split('-->'); const st = stamp(a), en = stamp(z);
    if (st == null || en == null) continue;
    const text = lines.slice(i + 1).join(' ').replace(/<[^>]+>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim();
    if (!text) continue;
    const last = out[out.length - 1];
    if (last && last.text === text) { last.end = en; continue; }
    out.push({ start: st, end: en, text });
  }
  return out;
}
function detectLang(texts) {
  const s = texts.slice(0, 150).join(' ').toLowerCase();
  const score = {
    sk: /\b(je|som|sa|že|aby|ktorý|ako|ale|veľmi|teraz|tak|čo|nie|áno|ďakujem|môže)\b/g, cs: /\b(je|jsem|se|že|aby|který|jak|ale|velmi|teď|tak|co|ne|ano|děkuji|může)\b/g,
    en: /\b(the|and|is|you|that|it|of|to|what|this|have)\b/g, it: /\b(il|che|non|di|è|sono|per|una|questo|anche|perché)\b/g,
    de: /\b(der|die|und|ist|nicht|ich|das|sie|mit|auch)\b/g, es: /\b(el|que|de|y|no|es|por|una|pero|muy)\b/g, fr: /\b(le|que|et|est|pas|je|une|les|des|vous)\b/g,
    hu: /\b(és|hogy|nem|az|egy|van|ez|meg|is)\b/g, pl: /\b(jest|że|nie|się|to|jak|ale|tak|co|bardzo)\b/g,
  };
  let best = null, bestN = 0;
  for (const [k, re] of Object.entries(score)) { const n = (s.match(re) || []).length + (k === 'sk' ? (s.match(/[ľĺŕäô]/g) || []).length * 2 : 0) + (k === 'cs' ? (s.match(/[ěřů]/g) || []).length * 2 : 0); if (n > bestN) { best = k; bestN = n; } }
  return bestN > 3 ? best : null;
}

const Transcript = {
  ref: null, tracks: [], cues: [], original: [], origLang: null, translations: {}, cur: -1, req: 0, trReq: 0,
  async load(ref) {
    this.ref = ref; const id = ++this.req;
    this.tracks = []; this.cues = []; this.original = []; this.translations = {}; this.cur = -1;
    $('tTrack').innerHTML = ''; $('tTrack').disabled = true; $('tLang').innerHTML = ''; $('tLang').disabled = true;
    this.msg('Načítavam prepis…');
    let res = await vv.playerTracks(ref);
    if (id !== this.req) return;
    let tracks = res.tracks || [];
    if (!tracks.length) {
      const a = await vv.api('GET', `${apiPath(ref)}/texttracks`);
      if (a.ok) tracks = (a.json.data || []).filter(t => t.link).map(t => ({ label: t.name || t.language, lang: t.language || '', url: t.link }));
    }
    if (id !== this.req) return;
    if (!tracks.length) { await this.capture(id); return; }
    this.tracks = tracks;
    $('tTrack').innerHTML = tracks.map((t, i) => `<option value="${i}">${esc(/auto/i.test(t.label + t.lang) ? 'Automatický prepis (Vimeo: „' + t.label.replace(/\(auto.?generated\)/i, '').trim() + '“)' : t.label)}</option>`).join('');
    $('tTrack').disabled = tracks.length < 2;
    const pref = ['sk', 'cs', 'en'];
    let idx = 0;
    for (const l of pref) { const i = tracks.findIndex(t => t.lang.startsWith(l)); if (i >= 0) { idx = i; break; } }
    $('tTrack').value = idx;
    this.loadTrack(idx, id);
  },
  async loadTrack(i, id = this.req) {
    this.msg('Načítavam prepis…');
    const r = await vv.fetchText(this.tracks[i].url);
    if (id !== this.req) return;
    const cues = r.ok ? parseVTT(r.text) : [];
    if (cues.length) this.setOriginal(cues); else await this.capture(id);
  },
  // Záloha: titulky na chvíľu zapne prehrávač a aplikácia zachytí súbor, ktorý si stiahne.
  async capture(id) {
    const p = Player.p;
    if (!p) { this.msg('Toto video nemá titulky ani automatický prepis.'); return; }
    try {
      await p.ready();
      const tracks = await p.getTextTracks();
      if (!tracks.length) { this.msg('Toto video nemá titulky ani automatický prepis.'); return; }
      const before = tracks.find(t => t.mode === 'showing');
      const t = tracks.find(x => /^sk/.test(x.language)) || tracks.find(x => /^(cs|en)/.test(x.language)) || tracks[0];
      const prevURL = await vv.lastTrackURL();
      await p.enableTextTrack(t.language, t.kind);
      for (let k = 0; k < 20; k++) {
        await new Promise(r => setTimeout(r, 500));
        const u = await vv.lastTrackURL();
        if (u && u !== prevURL) {
          const r = await vv.fetchText(u);
          if (before) p.enableTextTrack(before.language, before.kind).catch(() => {}); else p.disableTextTrack().catch(() => {});
          if (id !== this.req) return;
          const cues = r.ok ? parseVTT(r.text) : [];
          if (cues.length) { $('tTrack').innerHTML = `<option>${esc(t.label || t.language)}</option>`; this.setOriginal(cues); return; }
          break;
        }
      }
      if (before) p.enableTextTrack(before.language, before.kind).catch(() => {}); else p.disableTextTrack().catch(() => {});
      this.msg('Prepis sa nepodarilo načítať.');
    } catch (e) { log('Prepis', 'zachytenie → ' + (e && e.message)); this.msg('Prepis sa nepodarilo načítať.'); }
  },
  setOriginal(cues) {
    this.original = cues; this.translations = {};
    this.origLang = detectLang(cues.map(c => c.text));
    const sel = $('tLang');
    sel.innerHTML = `<option value="">Originál${this.origLang ? ' – ' + esc(langName(this.origLang)) : ''}</option>` +
      LANGS.filter(l => !(this.origLang || '').startsWith(l[1])).map(l => `<option value="${l[1]}">Preklad: ${esc(l[0])}</option>`).join('');
    sel.disabled = false;
    const target = LS.get('transcriptTargetLang', 'sk');
    if (target && this.origLang && !this.origLang.startsWith(target)) { sel.value = target; this.translate(target); }
    else { sel.value = ''; this.show(cues); }
  },
  async translate(code) {
    if (this.translations[code]) { this.show(this.translations[code], 'Preklad'); return; }
    const id = ++this.trReq;
    if (!this.cues.length) this.show(this.original, 'Prekladám… 0 %');
    $('tStatus').textContent = 'Prekladám… 0 %';
    const s = await vv.settingsGet();
    const r = await vv.translate(this.original.map(c => c.text), code, s.deeplKey || '');
    if (id !== this.trReq) return;
    if (!r.ok) { $('tLang').value = ''; this.show(this.original, 'Preklad zlyhal – zobrazený originál'); return; }
    const t = this.original.map((c, i) => ({ ...c, text: r.texts[i] }));
    this.translations[code] = t;
    this.show(t, s.deeplKey ? 'Preklad (DeepL)' : 'Preklad (Google)');
  },
  msg(s) { $('tList').innerHTML = `<div class="status">${esc(s)}</div>`; $('tStatus').textContent = ''; },
  show(cues, note) {
    this.cues = cues; this.cur = -1;
    const q = $('tSearch').value.trim().toLowerCase();
    const list = $('tList'); list.innerHTML = '';
    cues.forEach((c, i) => {
      if (q && !c.text.toLowerCase().includes(q)) return;
      const d = document.createElement('div'); d.className = 'cue'; d.dataset.i = i;
      let text = esc(c.text);
      if (q) text = text.replace(new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), m => `<mark>${m}</mark>`);
      d.innerHTML = `<span class="tc">${fmt(c.start)}</span>${text}`;
      d.onclick = () => Player.seek(c.start);
      list.appendChild(d);
    });
    if (!list.children.length) this.msg(q ? 'Nič sa nenašlo.' : 'Prepis je prázdny.');
    $('tStatus').textContent = note || `${cues.length} úsekov`;
  },
  update(t) {
    if (!this.cues.length) return;
    let lo = 0, hi = this.cues.length - 1, f = -1;
    while (lo <= hi) { const m = (lo + hi) >> 1; if (this.cues[m].start <= t + 0.15) { f = m; lo = m + 1; } else hi = m - 1; }
    if (f === this.cur) return;
    const list = $('tList');
    const old = list.querySelector('.cue.cur'); if (old) old.classList.remove('cur');
    this.cur = f;
    const el = list.querySelector(`.cue[data-i="${f}"]`);
    if (el) { el.classList.add('cur'); if ($('tFollow').checked) el.scrollIntoView({ block: 'center', behavior: 'smooth' }); }
  },
  text(times) { return times ? this.cues.map(c => `[${fmt(c.start)}] ${c.text}`).join('\n') : this.cues.map(c => c.text).join(' '); },
  srt() {
    const st = t => { const ms = Math.round(t * 1000); return `${String(Math.floor(ms / 3600000)).padStart(2, '0')}:${String(Math.floor(ms / 60000) % 60).padStart(2, '0')}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')},${String(ms % 1000).padStart(3, '0')}`; };
    return this.cues.map((c, i) => `${i + 1}\n${st(c.start)} --> ${st(Math.max(c.end, c.start + 0.5))}\n${c.text}\n`).join('\n');
  },
  async uploadSubtitles() {
    if (!this.ref) return;
    const [file] = await vv.chooseFiles({ title: 'Vyberte titulky', filters: [{ name: 'Titulky', extensions: ['srt', 'vtt', 'dfxp', 'ttml', 'xml', 'scc', 'sami', 'smi'] }] });
    if (!file) return;
    const name = file.split(/[\\/]/).pop().replace(/\.[^.]+$/, '');
    Modal.open(`<h2>Nahrať titulky na Vimeo</h2><p class="small">${esc(file)}</p>
      <div class="field"><span>Jazyk:</span><select id="sLang">${LANGS.map(l => `<option value="${l[1]}">${l[0]}</option>`).join('')}</select></div>
      <div class="field"><span>Typ:</span><select id="sKind"><option value="subtitles">Titulky (subtitles)</option><option value="captions">Skryté titulky pre nepočujúcich (captions)</option></select></div>
      <div class="field"><span>Názov:</span><input id="sName" value="${esc(name)}"></div>
      <div class="btns"><button id="sNo">Zrušiť</button><button class="primary" id="sYes">Nahrať</button></div>`);
    $('sNo').onclick = () => Modal.close();
    $('sYes').onclick = async () => {
      const lang = $('sLang').value, kind = $('sKind').value, nm = $('sName').value || name;
      Modal.close();
      const txt = await vv.readFile(file);
      if (txt) { const c = parseVTT(txt); if (c.length) this.setOriginal(c); }
      $('tStatus').textContent = 'Nahrávam titulky…';
      const r = await vv.uploadSubtitles(this.ref, file, lang, kind, nm);
      if (r.ok) { Modal.alert('Hotovo', `Titulky „${nm}“ sú nahraté na Vimeo. Vimeo ich môže chvíľu spracúvať.`); setTimeout(() => this.load(this.ref), 4000); }
      else Modal.alert('Nahratie titulkov zlyhalo', r.error + '\n\nNahrávať titulky môže vlastník videa alebo člen tímu s oprávnením upravovať.');
    };
  },
};
$('tTrack').onchange = e => Transcript.loadTrack(parseInt(e.target.value, 10));
$('tLang').onchange = e => { const c = e.target.value; LS.set('transcriptTargetLang', c); if (!c) Transcript.show(Transcript.original); else Transcript.translate(c); };
$('tSearch').oninput = () => Transcript.cues.length && Transcript.show(Transcript.cues, $('tStatus').textContent);
vv.on('translate-progress', p => { if (/Prekladám/.test($('tStatus').textContent)) $('tStatus').textContent = `Prekladám… ${Math.round(p * 100)} %`; });
$('tMenu').onclick = async () => {
  const id = await vv.menu([{ id: 'c1', label: 'Kopírovať prepis s časmi' }, { id: 'c2', label: 'Kopírovať iba text' }, { id: 'txt', label: 'Uložiť prepis ako .txt…' },
    { id: 'srt', label: 'Uložiť titulky ako .srt…' }, '-', { id: 'up', label: 'Nahrať titulky na Vimeo (.srt, .vtt…)…' }]);
  const t = Transcript;
  if (id === 'c1' && t.cues.length) { vv.copy(t.text(true)); toast('✓ Skopírované'); }
  if (id === 'c2' && t.cues.length) { vv.copy(t.text(false)); toast('✓ Skopírované'); }
  if (id === 'txt' && t.cues.length) vv.saveText(`Prepis ${Video.title || ''}.txt`, t.text(true));
  if (id === 'srt' && t.cues.length) vv.saveText(`Titulky ${Video.title || ''}.srt`, t.srt());
  if (id === 'up') t.uploadSubtitles();
};

// ====================================================== Komentáre
const FIELDS = 'uri,text,created_on,user.name,user.link,metadata.connections.replies';
const Comments = {
  ref: null, list: [], collab: [], total: 0, next: null, req: 0, replyTo: null, time: null,
  collabPath: null, textKey: 'text', timeKey: null, timeSample: null, probing: false,

  async load(ref) {
    this.ref = ref; const id = ++this.req;
    Object.assign(this, { list: [], collab: [], total: 0, next: null, replyTo: null, time: null, collabPath: null, timeKey: null, timeSample: null, probing: true });
    this.updateInput(); this.render();
    const r = await vv.api('GET', `${apiPath(ref)}/comments?per_page=30&fields=${FIELDS}`);
    if (id !== this.req) return;
    if (r.ok) { this.list = (r.json.data || []).map(x => this.parse(x)).filter(Boolean); this.total = r.json.total || this.list.length; this.next = r.json.paging && r.json.paging.next; }
    else log('Komentáre', r.error);
    this.render();
    await this.probe(ref, id);
  },

  parse(j) {
    let text = null; for (const k of ['text', 'body', 'content', 'note', 'message', 'comment']) if (typeof j[k] === 'string' && j[k]) { text = j[k]; break; }
    if (text == null) return null;
    const u = j.user || j.author || j.owner || j.created_by || j.creator || {};
    let time = null;
    for (const k of ['timecode', 'time_code', 'video_time', 'timestamp', 'time', 'position', 'start_time', 'seconds', 'start']) {
      const v = j[k];
      if (typeof v === 'number' && v >= 0 && v < 100000) { time = v; break; }
      if (typeof v === 'string') { const t = parseTime(v); if (t != null && t < 100000) { time = t; break; } }
      if (v && typeof v === 'object' && typeof (v.seconds ?? v.start ?? v.time) === 'number') { time = v.seconds ?? v.start ?? v.time; break; }
    }
    const replies = j.metadata && j.metadata.connections && j.metadata.connections.replies;
    return { uri: j.uri || String(Math.random()), text, author: u.name || u.display_name || j.author_name || 'Kolaborátor', link: u.link,
             date: j.created_on || j.created_time || j.created_at, time, resolved: !!(j.is_resolved || j.resolved || j.status === 'resolved'),
             replyCount: (replies && replies.total) || 0, replies: null };
  },

  async probe(ref, id) {
    const cands = [];
    const meta = await vv.api('GET', `${apiPath(ref)}?fields=metadata.connections`);
    if (meta.ok) {
      const conns = (meta.json.metadata && meta.json.metadata.connections) || {};
      log('Komentáre', 'druhy obsahu videa: ' + Object.keys(conns).sort().map(k => k + (conns[k] && conns[k].total != null ? '=' + conns[k].total : '')).join(', '));
      for (const [k, v] of Object.entries(conns)) if (k !== 'comments' && /comment|note|review|feedback|annotation|timecode/i.test(k) && v && v.uri) cands.push(v.uri);
    }
    for (const c of [`/videos/${ref.id}/timecoded_comments`, `/videos/${ref.id}/notes`, `/videos/${ref.id}/review/notes`, `/videos/${ref.id}/collaborator_comments`, `/videos/${ref.id}/annotations`])
      if (!cands.includes(c)) cands.push(c);
    for (const path of cands) {
      const r = await vv.api('GET', path + (path.includes('?') ? '&' : '?') + 'per_page=100');
      if (id !== this.req) return;
      if (!r.ok) continue;
      const data = r.json.data || [];
      log('Komentáre', `${path} → OK, ${data.length} položiek [${data[0] ? Object.keys(data[0]).sort().join(',') : ''}]`);
      this.learn(path, data[0]);
      const items = data.map(x => this.parse(x)).filter(Boolean);
      if (items.length) { this.collab = items.sort((a, b) => (a.time || 0) - (b.time || 0)); break; }
    }
    this.probing = false;
    this.render();
  },

  learn(path, sample) {
    this.collabPath = path.split('?')[0];
    if (!sample) return;
    for (const k of ['text', 'body', 'content', 'note', 'message', 'comment']) if (typeof sample[k] === 'string') { this.textKey = k; break; }
    for (const k of ['timecode', 'time_code', 'video_time', 'timestamp', 'time', 'position', 'start_time', 'seconds', 'start'])
      if (sample[k] != null) { this.timeKey = k; this.timeSample = sample[k]; break; }
  },

  timeValue(t) {
    const s = this.timeSample;
    if (typeof s === 'string') { const x = Math.floor(t); return (s.match(/:/g) || []).length >= 2 ? `${String(Math.floor(x / 3600)).padStart(2, '0')}:${String(Math.floor(x / 60) % 60).padStart(2, '0')}:${String(x % 60).padStart(2, '0')}` : fmt(t); }
    if (s && typeof s === 'object') { const o = {}; for (const k of Object.keys(s)) if (['seconds', 'start', 'time'].includes(k)) o[k] = t; if (!Object.keys(o).length) o.seconds = t; return o; }
    return t;
  },

  markers() {
    const m = this.collab.filter(c => c.time != null).map(c => ({ time: c.time, text: `${c.author}: ${c.text}`, collab: true }));
    for (const c of this.list.concat(...this.list.map(x => x.replies || []))) {
      const ts = c.text.match(TS_RE); const t = ts && parseTime(ts[0]);
      if (t != null) m.push({ time: t, text: `${c.author}: ${c.text}`, collab: false });
    }
    Timeline.set(m.sort((a, b) => a.time - b.time));
  },

  linkify(text) {
    return esc(text).replace(/https?:\/\/[^\s<]+/g, u => `<a class="ext" data-u="${u}">${u}</a>`).replace(TS_RE, m => `<a class="tc" data-t="${parseTime(m)}">${m}</a>`);
  },

  html(c, isReply, allowReply, isCollab) {
    const d = c.date ? new Date(c.date).toLocaleString('sk-SK', { dateStyle: 'medium', timeStyle: 'short' }) : '';
    const body = (c.time != null ? `<a class="tc" data-t="${c.time}">${fmt(c.time)}</a> ` : '') + this.linkify(c.text);
    const acts = [];
    if (allowReply) acts.push(`<a data-act="reply" data-uri="${esc(c.uri)}">Odpovedať</a>`);
    if (c.uri.startsWith('/')) { acts.push(`<a data-act="edit" data-uri="${esc(c.uri)}">Upraviť</a>`); acts.push(`<a class="del" data-act="del" data-uri="${esc(c.uri)}">Zmazať</a>`); }
    let h = `<div class="cm${isReply ? ' reply' : ''}"><div><span class="a">${esc(c.author)}</span> <span class="d">· ${esc(d)}</span>${c.resolved ? ' <span class="ok">✓ vyriešené</span>' : ''}</div>
      <div>${body}</div><div class="acts">${acts.join('')}</div></div>`;
    if (!isCollab && !isReply) {
      if (c.replies) h += c.replies.map(r => this.html(r, true, false, false)).join('');
      else if (c.replyCount) h += `<div class="cm reply acts"><a data-act="replies" data-uri="${esc(c.uri)}">▸ Zobraziť odpovede (${c.replyCount})</a></div>`;
    }
    return h;
  },

  render() {
    const n = this.total + this.collab.length;
    $('cTitle').textContent = n ? `Komentáre (${n})` : 'Komentáre';
    this.markers();
    const el = $('cList');
    if (!this.list.length && !this.collab.length) { el.innerHTML = `<div class="status">${this.probing ? 'Hľadám komentáre kolaborátorov…' : 'Zatiaľ žiadne komentáre.'}</div>`; return; }
    let h = '';
    if (this.collab.length) {
      h += `<div class="csec">KOLABORÁTORI (${this.collab.length})</div>` + this.collab.map(c => this.html(c, false, false, true)).join('');
      if (this.list.length) h += `<div class="csec">VEREJNÉ KOMENTÁRE (${this.total})</div>`;
    }
    h += this.list.map(c => this.html(c, false, true, false)).join('');
    if (this.next) h += `<div class="acts cm"><a data-act="more">Načítať ďalšie komentáre…</a></div>`;
    const top = el.scrollTop; el.innerHTML = h; el.scrollTop = top;
  },

  find(uri) {
    return this.collab.find(c => c.uri === uri) || this.list.find(c => c.uri === uri) || this.list.flatMap(c => c.replies || []).find(c => c.uri === uri);
  },

  async click(e) {
    const a = e.target.closest('a'); if (!a) return;
    if (a.dataset.t) { Player.seek(parseFloat(a.dataset.t)); return; }
    if (a.dataset.u) { vv.route(a.dataset.u); return; }
    const act = a.dataset.act, c = a.dataset.uri && this.find(a.dataset.uri);
    if (act === 'more' && this.next) { const n = this.next; this.next = null; const r = await vv.api('GET', n); if (r.ok) { this.list.push(...(r.json.data || []).map(x => this.parse(x)).filter(Boolean)); this.next = r.json.paging && r.json.paging.next; } this.render(); }
    if (act === 'replies' && c) { const r = await vv.api('GET', `${c.uri}/replies?per_page=100&fields=${FIELDS}`); if (r.ok) { c.replies = (r.json.data || []).map(x => this.parse(x)).filter(Boolean); this.render(); } }
    if (act === 'reply' && c) { this.replyTo = c; this.time = null; this.updateInput(); $('cInput').focus(); }
    if (act === 'edit' && c) this.edit(c);
    if (act === 'del' && c) this.del(c);
  },

  edit(c) {
    Modal.open(`<h2>Upraviť komentár</h2>${c.time != null ? `<p class="small">Čas vo videu: ${fmt(c.time)}</p>` : ''}<textarea id="eText">${esc(c.text)}</textarea>
      <div class="btns"><button id="eNo">Zrušiť</button><button class="primary" id="eYes">Uložiť</button></div>`);
    $('eNo').onclick = () => Modal.close();
    $('eYes').onclick = async () => {
      const t = $('eText').value.trim(); Modal.close();
      if (!t || t === c.text) return;
      const key = this.collab.includes(c) ? this.textKey : 'text';
      const r = await vv.api('PATCH', c.uri, { [key]: t });
      if (r.ok) { c.text = t; this.render(); } else Modal.alert('Úprava zlyhala', r.error + '\n\nUpraviť môžete len vlastné komentáre (alebo všetky, ak ste vlastník videa).');
    };
  },

  async del(c) {
    if (!await Modal.confirm('Zmazať komentár?', `„${c.text.slice(0, 140)}“\n\nTúto akciu nie je možné vrátiť.`, 'Zmazať')) return;
    const r = await vv.api('DELETE', c.uri);
    if (!r.ok) { Modal.alert('Zmazanie zlyhalo', r.error + '\n\nZmazať môžete len vlastné komentáre (alebo všetky, ak ste vlastník videa).'); return; }
    let i;
    if ((i = this.collab.indexOf(c)) >= 0) this.collab.splice(i, 1);
    else if ((i = this.list.indexOf(c)) >= 0) { this.list.splice(i, 1); this.total = Math.max(0, this.total - 1); }
    else for (const p of this.list) if (p.replies && (i = p.replies.indexOf(c)) >= 0) { p.replies.splice(i, 1); p.replyCount--; }
    this.render();
  },

  begin() { if (!this.ref) return; setMode('video'); this.replyTo = null; pause(); this.time = Player.time; this.updateInput(); $('cInput').focus(); },
  focused() { if (this.ref && !this.replyTo && this.time == null) { pause(); this.time = Player.time; this.updateInput(); } },
  blurred() { if (!$('cInput').value.trim() && !this.replyTo) { this.time = null; this.updateInput(); } },
  updateInput() {
    const chip = $('timeChip');
    $('replyRow').classList.toggle('hidden', !this.replyTo);
    if (this.replyTo) { $('replyLabel').textContent = 'Odpoveď pre: ' + this.replyTo.author; chip.classList.add('hidden'); $('cInput').placeholder = 'Napíšte odpoveď…'; $('cSend').textContent = 'Odpovedať'; }
    else if (this.time != null) { chip.textContent = '⏱ ' + fmt(this.time); chip.classList.remove('hidden'); $('cInput').placeholder = `Komentár k času ${fmt(this.time)}…`; $('cSend').textContent = 'Pridať'; }
    else { chip.classList.add('hidden'); $('cInput').placeholder = 'Kliknite sem – zaznamená sa aktuálny čas videa'; $('cSend').textContent = 'Pridať'; }
  },

  async send() {
    const text = $('cInput').value.trim(); if (!text || !this.ref) return;
    $('cSend').disabled = true;
    try {
      if (this.replyTo) {
        const r = await vv.api('POST', `${this.replyTo.uri}/replies`, { text });
        if (!r.ok) throw new Error(r.error);
        const c = this.parse(r.json); if (c) { this.replyTo.replies = (this.replyTo.replies || []).concat(c); this.replyTo.replyCount++; }
        this.replyTo = null;
      } else {
        const t = this.time != null ? this.time : Player.time;
        let added = false;
        if (this.collabPath && this.timeKey) {
          const r = await vv.api('POST', this.collabPath, { [this.textKey]: text, [this.timeKey]: this.timeValue(t) });
          if (r.ok) { const c = this.parse(r.json) || { uri: String(Math.random()), text, author: 'Ja', date: new Date().toISOString() }; if (c.time == null) c.time = t; this.collab.push(c); this.collab.sort((a, b) => (a.time || 0) - (b.time || 0)); added = true; }
          else log('Komentáre', `POST ${this.collabPath} → ${r.error}`);
        }
        if (!added) {
          const r = await vv.api('POST', `${apiPath(this.ref)}/comments`, { text: `${fmt(t)} ${text}` });
          if (!r.ok) throw new Error(r.error);
          const c = this.parse(r.json); if (c) { c.time = t; this.list.unshift(c); this.total++; }
        }
        toast(`✓ Komentár pridaný v ${fmt(t)}`);
      }
      $('cInput').value = ''; this.time = null; this.updateInput(); this.render();
    } catch (e) {
      Modal.alert('Komentár sa nepodarilo pridať', e.message + '\n\nNa pridávanie komentárov musíte byť prihlásený do Vimea.');
    } finally { $('cSend').disabled = false; }
  },
};
$('cList').addEventListener('click', e => Comments.click(e));
$('cInput').addEventListener('focus', () => Comments.focused());
$('cInput').addEventListener('blur', () => Comments.blurred());
$('cInput').addEventListener('keydown', e => { if (e.key === 'Enter') Comments.send(); });
$('cSend').onclick = () => Comments.send();
$('cancelReply').onclick = () => { Comments.replyTo = null; Comments.updateInput(); };
$('cRefresh').onclick = () => Comments.ref && Comments.load(Comments.ref);

// ====================================================== Zdieľanie
const Share = {
  ref: null, review: null,
  load(ref) { this.ref = ref; this.review = null; $('shareAtTime').checked = false; this.refresh(); },
  url() { return this.ref ? pageURL(this.ref, $('shareAtTime').checked ? Player.time : 0) : ''; },
  refresh() { $('shareLink').value = this.url(); },
  updateTime(t) { const s = fmt(t); if ($('shareTime').textContent !== s) { $('shareTime').textContent = s; if ($('shareAtTime').checked) this.refresh(); } },
  flash(m) { $('shareFeedback').textContent = m; clearTimeout(this.h); this.h = setTimeout(() => { $('shareFeedback').textContent = ''; }, 2000); },
  async download(ref = this.ref, title = Video.title) {
    if (!ref) return;
    const r = await vv.api('GET', `${apiPath(ref)}?fields=name,download`);
    if (!r.ok) { Modal.alert('Sťahovanie zlyhalo', r.error); return; }
    const opts = (r.json.download || []).sort((a, b) => (b.width || 0) - (a.width || 0));
    if (!opts.length) { Modal.alert('Sťahovanie nie je dostupné', 'Vimeo k tomuto videu nesprístupnilo súbory na stiahnutie. Môže to byť vypnuté vlastníkom videa alebo to nepovoľuje typ účtu.'); return; }
    const id = await vv.menu(opts.map((o, i) => ({ id: String(i), label: `${o.public_name || o.rendition || o.quality}${o.size_short ? ' – ' + o.size_short : ''}` })));
    if (id == null) return;
    const o = opts[parseInt(id, 10)];
    const name = `${(r.json.name || title || 'video').replace(/[\\/:*?"<>|]/g, '-')} ${o.public_name || o.rendition || ''}.${/quicktime/.test(o.type || '') ? 'mov' : 'mp4'}`;
    vv.download(o.link, name); Transfers.show();
  },
  async replace() {
    if (!this.ref) return;
    const [file] = await vv.chooseFiles({ title: 'Vyberte nový súbor videa', filters: [{ name: 'Videá', extensions: ['mp4', 'mov', 'm4v', 'avi', 'mkv', 'mxf', 'webm', 'wmv'] }] });
    if (!file) return;
    const title = Video.title || 'video';
    if (!await Modal.confirm(`Nahradiť video „${title}“?`, `Nový súbor: ${file.split(/[\\/]/).pop()}\n\nNahrá sa ako nová verzia toho istého videa – odkaz, review link aj komentáre zostanú.`, 'Nahradiť')) return;
    vv.upload({ kind: 'replace', file, ref: this.ref, title }); Transfers.show();
  },
};
$('shareAtTime').onchange = () => Share.refresh();
$('btnCopyLink').onclick = () => { vv.copy(Share.url()); Share.flash('✓ Odkaz skopírovaný'); };
$('btnEmbed').onclick = () => {
  if (!Share.ref) return;
  const r = Share.ref, t = $('shareAtTime').checked ? Player.time : 0;
  const src = `https://player.vimeo.com/video/${r.id}${r.hash ? '?h=' + r.hash : ''}${t >= 1 ? '#t=' + Math.floor(t) + 's' : ''}`;
  vv.copy(`<div style="padding:56.25% 0 0 0;position:relative;"><iframe src="${src}" style="position:absolute;top:0;left:0;width:100%;height:100%;" frameborder="0" allow="autoplay; fullscreen; picture-in-picture" allowfullscreen title="${esc(Video.title || '')}"></iframe></div>`);
  Share.flash('✓ Embed kód skopírovaný');
};
$('btnQR').onclick = () => {
  const u = Share.url(); if (!u) return;
  Modal.open(`<h2>QR kód</h2><p class="small">${esc(u)}</p><img style="display:block;margin:10px auto;width:240px;height:240px" src="https://api.qrserver.com/v1/create-qr-code/?size=480x480&data=${encodeURIComponent(u)}"><div class="btns"><button class="primary" id="mOk">Zavrieť</button></div>`);
  $('mOk').onclick = () => Modal.close();
};
$('btnSocial').onclick = async () => {
  const u = encodeURIComponent(Share.url()), t = encodeURIComponent(Video.title || '');
  const id = await vv.menu([{ id: 'x', label: 'X / Twitter' }, { id: 'fb', label: 'Facebook' }, { id: 'li', label: 'LinkedIn' }, { id: 'mail', label: 'E-mail' }]);
  const map = { x: `https://twitter.com/intent/tweet?url=${u}&text=${t}`, fb: `https://www.facebook.com/sharer/sharer.php?u=${u}`, li: `https://www.linkedin.com/sharing/share-offsite/?url=${u}`, mail: `mailto:?subject=${t}&body=${u}` };
  if (map[id]) vv.openExternal(map[id]);
};
$('btnReview').onclick = async () => {
  if (!Share.ref) return;
  if (!Share.review) { const r = await vv.api('GET', `${apiPath(Share.ref)}?fields=link`); Share.review = (r.ok && r.json.link) || pageURL(Share.ref); }
  const link = Share.review;
  const id = await vv.menu([{ id: 'h', label: link, enabled: false }, '-', { id: 'copy', label: 'Kopírovať review link' }, { id: 'mail', label: 'Poslať e-mailom' }, { id: 'open', label: 'Otvoriť v prehliadači' }]);
  if (id === 'copy') { vv.copy(link); Share.flash('✓ Review link skopírovaný'); }
  if (id === 'mail') vv.openExternal(`mailto:?subject=${encodeURIComponent('Review: ' + (Video.title || ''))}&body=${encodeURIComponent(`Prosím o komentáre k videu „${Video.title || ''}“ (komentáre sa dajú písať priamo k času vo videu):\n${link}`)}`);
  if (id === 'open') vv.openExternal(link);
};
$('videoMenu').onclick = async () => {
  if (!Share.ref) return;
  const id = await vv.menu([{ id: 'replace', label: 'Nahradiť video novým súborom (Replace)…' }, { id: 'dl', label: 'Stiahnuť video…' },
    { id: 'subs', label: 'Nahrať titulky (.srt, .vtt…)…' }, '-', { id: 'open', label: 'Otvoriť na vimeo.com' }, { id: 'copy', label: 'Kopírovať odkaz' }]);
  if (id === 'replace') Share.replace();
  if (id === 'dl') Share.download();
  if (id === 'subs') Transcript.uploadSubtitles();
  if (id === 'open') vv.openExternal(pageURL(Share.ref));
  if (id === 'copy') { vv.copy(pageURL(Share.ref)); Share.flash('✓ Odkaz skopírovaný'); }
};

// ====================================================== Prenosy
const Transfers = {
  items: [],
  show() { $('transfers').classList.remove('hidden'); this.render(); },
  render() {
    $('trList').innerHTML = this.items.length ? this.items.map(t => `<div class="tr"><div><b>${t.type === 'upload' ? '⬆' : '⬇'} ${esc(t.name)}</b></div>
      ${t.done || t.failed ? '' : `<progress max="1" value="${t.progress}"></progress>`}
      <div class="row"><span class="s ${t.failed ? 'err' : t.done ? 'ok' : ''}">${esc(t.status)}</span><div class="spacer"></div>
      ${t.done || t.failed ? (t.type === 'download' && t.done ? `<button data-show="${esc(t.file)}">Zobraziť v priečinku</button>` : '') : `<button data-cancel="${t.id}">Zrušiť</button>`}</div></div>`).join('') : '<div class="status">Žiadne prenosy.</div>';
  },
};
vv.on('transfers', list => { Transfers.items = list; Transfers.render(); });
$('trList').addEventListener('click', e => {
  const b = e.target.closest('button'); if (!b) return;
  if (b.dataset.cancel) vv.transferCancel(parseFloat(b.dataset.cancel));
  if (b.dataset.show) vv.transferShow(b.dataset.show);
});
$('trClear').onclick = () => vv.transfersClear();
$('trClose').onclick = () => $('transfers').classList.add('hidden');

// ====================================================== Nastavenia, Návod, Diagnostika
const Settings = {
  async show() {
    const s = await vv.settingsGet();
    const d = await vv.defaultBrowserStatus();
    Modal.open(`<h2>Nastavenia</h2>
      <h3>Odkazy na Vimeo</h3>
      <p>Aby sa odkazy na Vimeo z PowerPointu, PDF, Outlooku a iných aplikácií otvárali v tejto aplikácii, nastavte Vimeo Viewer ako predvolený prehliadač. Ostatné odkazy sa okamžite pošlú do vášho pôvodného prehliadača.</p>
      <p class="small">${d.isDefault ? '✓ Vimeo Viewer je predvolený prehliadač' : 'Vimeo odkazy sa zatiaľ otvárajú v inom prehliadači'}${d.fallback ? ' · ostatné odkazy: ' + esc(d.fallback.split('\\').pop()) : ''}</p>
      <button id="setDefault">Nastaviť ako predvolený prehliadač…</button>
      <p class="small">Otvorí sa Nastavenia Windows → Predvolené aplikácie → Vimeo Viewer. Pri „HTTP“ a „HTTPS“ zvoľte Vimeo Viewer.</p>
      <h3>Preklad prepisu</h3>
      <p>Predvolene prekladá Google Prekladač. Pre kvalitnejší preklad zadajte kľúč DeepL (bezplatný účet na deepl.com/pro-api).</p>
      <div class="field"><span>DeepL kľúč:</span><input id="deeplKey" type="password" value="${esc(s.deeplKey || '')}"></div>
      <div class="btns"><button class="primary" id="setSave">Uložiť a zavrieť</button></div>`);
    $('setDefault').onclick = () => vv.makeDefaultBrowser();
    $('setSave').onclick = async () => { await vv.settingsSet({ deeplKey: $('deeplKey').value.trim() }); Modal.close(); };
  },
};

const Help = {
  show() {
    const sec = (t, items) => `<h3>${t}</h3><ul>${items.map(i => `<li>${i}</li>`).join('')}</ul>`;
    Modal.open(`<h2>Vimeo Viewer – návod</h2>` +
      sec('Inštalácia a nastavenie', [
        'Spustite <code>VimeoViewer-Setup.exe</code>. Windows ukáže modré okno „Systém Windows ochránil váš počítač“, lebo aplikácia nie je podpísaná certifikátom. Kliknite <b>Ďalšie informácie → Spustiť aj tak</b>. Inštalácia prebehne sama a vytvorí odkaz na ploche aj v ponuke Štart.',
        'Prihláste sa cez ikonu 👤 vpravo hore. Funguje aj prihlásenie cez Google.',
        'Aby sa odkazy na Vimeo z PowerPointu, PDF alebo Outlooku otvárali v aplikácii, otvorte <b>☰ → Nastavenia → Nastaviť ako predvolený prehliadač</b>. V Nastaveniach Windows potom pri <b>HTTP</b> a <b>HTTPS</b> vyberte <b>Vimeo Viewer</b>. Ostatné odkazy aplikácia pošle do vášho pôvodného prehliadača.',
        'Windows verzia má rovnaké funkcie ako Mac verzia. Menu je pod ikonou ☰ vpravo hore (Nastavenia, Prenosy, Návod cez F1, Diagnostika, Aktualizácie). Obraz v obraze funguje, keďže aplikácia beží na Chrome. Ďalšie verzie sa aktualizujú samy.',
      ]) +
      sec('Úvod', ['Hore prepínate Knižnica (Ctrl+1) a Video (Ctrl+2). 🌐 otvorí web vimeo.com, ⌂ sa vráti na úvodnú obrazovku knižnice.', 'Do adresného riadku vložte odkaz na Vimeo, číslo videa alebo hľadaný výraz.']) +
      sec('Prihlásenie', ['Ikona 👤 hore vpravo otvorí prihlásenie do Vimea (aj cez Google/Apple). Po prihlásení sa okno samo zavrie.', 'Prihlásenie je potrebné pre knižnicu, komentáre, nahrávanie a sťahovanie.']) +
      sec('Knižnica', ['Vľavo je strom priečinkov – ▸ rozbalí podpriečinky, kliknutím priečinok otvoríte.', 'Vpravo je mriežka: priečinky, potom videá. Cesta hore slúži na návrat, ‹ ide o úroveň vyššie.', 'Obľúbené: ☆ pri ceste alebo pravý klik na priečinok. Obľúbené sú navrchu bočného panela.', 'Pravý klik na video: Otvoriť, Stiahnuť, Kopírovať odkaz. „Nahrať video…“ (Ctrl+U) nahrá videá do otvoreného priečinka.']) +
      sec('Video a ovládanie', ['Ovládanie je v lište pod videom: prehrať/pauza (Ctrl+Enter), ±10 s, čas, časová os, hlasitosť, rýchlosť, titulky (CC), kvalita, obraz v obraze, celá obrazovka.', 'Bodky na časovej osi sú komentáre – oranžové od kolaborátorov, modré s časom v texte. Prejdite myšou pre text, kliknite pre skok.']) +
      sec('Prepis', ['Prepis sa načíta automaticky. Kliknutím na vetu pretočíte video, aktuálna veta sa zvýrazňuje.', '„Jazyk“: originál alebo preklad (slovenčina, čeština, angličtina…). Voľbu si aplikácia pamätá.', 'Menu ⋯: kopírovať, uložiť .txt / .srt, nahrať vlastné titulky na Vimeo. Hľadanie: Ctrl+F.']) +
      sec('Komentáre', ['Kliknite do poľa komentára – video sa zastaví a zaznamená sa čas (štítok ⏱). Napíšte text a stlačte Pridať alebo Enter. Rovnako Ctrl+K.', 'Pod komentárom: Odpovedať, Upraviť, Zmazať (vlastné komentáre alebo všetky, ak ste vlastník videa).']) +
      sec('Zdieľanie a menu Video', ['Review link: odkaz, cez ktorý môžu ostatní pozerať a komentovať (kopírovať, e-mail, otvoriť).', 'Menu „Video ▾“: Nahradiť video novým súborom (nová verzia – odkaz aj komentáre ostanú), Stiahnuť, Nahrať titulky, Otvoriť na vimeo.com.', 'Lišta: kopírovať odkaz (aj od aktuálneho času), embed kód, QR kód, sociálne siete.']) +
      sec('Odkazy z iných aplikácií', ['Menu ☰ → Nastavenia → „Nastaviť ako predvolený prehliadač“. Vimeo odkazy sa potom otvoria tu, ostatné vo vašom prehliadači.']) +
      sec('Aktualizácie a problémy', ['Aplikácia pri spustení sama skontroluje novú verziu (☰ → Skontrolovať aktualizácie…).', '☰ → Diagnostika: zopakujte problém, skopírujte text a pošlite ho.']) +
      `<div class="btns"><button class="primary" id="mOk">Zavrieť</button></div>`);
    $('mOk').onclick = () => Modal.close();
  },
};

const Diagnostics = {
  async show() {
    const i = await vv.appInfo();
    const text = `Vimeo Viewer ${i.version} · Windows · Electron ${i.electron}\n\n` + (await vv.diag() || '(zatiaľ žiadne záznamy)');
    Modal.open(`<h2>Diagnostika</h2><p class="small">Zopakujte problém, potom kliknite „Kopírovať všetko“ a text pošlite. Heslá sa nezaznamenávajú.</p><pre>${esc(text)}</pre>
      <div class="btns"><button id="dClear">Vymazať</button><button id="dCopy">Kopírovať všetko</button><button class="primary" id="mOk">Zavrieť</button></div>`);
    $('dCopy').onclick = () => { vv.copy(text); toast('✓ Skopírované'); };
    $('dClear').onclick = async () => { await vv.diagClear(); Diagnostics.show(); };
    $('mOk').onclick = () => Modal.close();
  },
};

// ====================================================== Štart
setMode('library');
