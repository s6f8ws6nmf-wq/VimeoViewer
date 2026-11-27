// Vimeo Viewer pre Windows – hlavný proces (Electron)
'use strict';
const { app, BrowserWindow, ipcMain, session, shell, dialog, Menu, clipboard } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execFile, spawn } = require('child_process');

const REPO = 's6f8ws6nmf-wq/VimeoViewer';
let win = null;
let pendingURL = null;
const diag = [];

function log(src, msg) {
  const t = new Date().toTimeString().slice(0, 8);
  diag.push(`[${t}] ${src}: ${msg}`);
  if (diag.length > 400) diag.shift();
}

// ---------- Nastavenia ----------
const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');
let settings = {};
function loadSettings() { try { settings = JSON.parse(fs.readFileSync(settingsFile(), 'utf8')); } catch { settings = {}; } }
function saveSettings() { try { fs.writeFileSync(settingsFile(), JSON.stringify(settings, null, 2)); } catch (e) { log('Nastavenia', e.message); } }

// ---------- Odkazy ----------
function isVimeoHost(h) { h = (h || '').toLowerCase(); return h === 'vimeo.com' || h.endsWith('.vimeo.com'); }

function videoRef(raw) {
  let u;
  try { u = new URL(raw); } catch { return null; }
  if (!/^https?:$/.test(u.protocol) || !isVimeoHost(u.hostname)) return null;
  const c = u.pathname.split('/').filter(Boolean);
  const num = s => /^\d+$/.test(s || '');
  const hex = s => /^[0-9a-f]{6,24}$/i.test(s || '');
  let id = null, hash = null;
  if (u.hostname === 'player.vimeo.com') {
    if (c[0] === 'video' && num(c[1])) { id = c[1]; if (hex(c[2])) hash = c[2]; }
  } else if (num(c[0])) { id = c[0]; if (hex(c[1])) hash = c[1]; }
  else if (c[0] === 'channels' && num(c[2])) id = c[2];
  else for (let i = 0; i < c.length - 1; i++) {
    if ((c[i] === 'video' || c[i] === 'videos') && num(c[i + 1])) { id = c[i + 1]; if (hex(c[i + 2])) hash = c[i + 2]; break; }
  }
  if (!id) return null;
  if (!hash && hex(u.searchParams.get('h'))) hash = u.searchParams.get('h');
  return { id, hash };
}

function normalize(raw) {
  let s = String(raw || '').trim();
  if (s.toLowerCase().startsWith('vimeoviewer:')) {
    try {
      const u = new URL(s);
      const inner = u.searchParams.get('url');
      if (inner) s = inner;
      else s = 'https://' + s.replace(/^vimeoviewer:\/*/i, '');
    } catch { s = 'https://' + s.replace(/^vimeoviewer:\/*/i, ''); }
  }
  for (let i = 0; i < 4; i++) {
    try {
      const u = new URL(s);
      const h = u.hostname.toLowerCase();
      let next = null;
      if (h.endsWith('safelinks.protection.outlook.com')) next = u.searchParams.get('url');
      else if (/^(www\.)?google\./.test(h) && u.pathname === '/url') next = u.searchParams.get('q') || u.searchParams.get('url');
      else if (h === 'l.facebook.com') next = u.searchParams.get('u');
      if (!next) break;
      s = next;
    } catch { break; }
  }
  return s;
}

function findURL(argv) {
  return argv.find(a => /^(https?|vimeoviewer):/i.test(a));
}

function route(raw) {
  const url = normalize(raw);
  const ref = videoRef(url);
  if (ref) {
    if (win) { win.webContents.send('open-video', ref); focusWin(); } else pendingURL = url;
    return;
  }
  try {
    const u = new URL(url);
    if (isVimeoHost(u.hostname)) { openBrowse(url); return; }
  } catch {}
  openInBrowser(url);
}

function focusWin() {
  if (!win) return;
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}

// ---------- Predvolený prehliadač (Windows) ----------
function reg(args) {
  return new Promise(res => execFile('reg', args, { windowsHide: true }, (err, out) => res(err ? '' : String(out))));
}

async function currentDefaultProgId() {
  const out = await reg(['query', 'HKCU\\Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\https\\UserChoice', '/v', 'ProgId']);
  const m = out.match(/ProgId\s+REG_SZ\s+(\S+)/);
  return m ? m[1] : null;
}

async function commandForProgId(progId) {
  const out = await reg(['query', `HKCR\\${progId}\\shell\\open\\command`, '/ve']);
  const m = out.match(/REG_SZ\s+(.+)/);
  if (!m) return null;
  const cmd = m[1].trim();
  const exe = cmd.startsWith('"') ? cmd.slice(1, cmd.indexOf('"', 1)) : cmd.split(' ')[0];
  return exe && fs.existsSync(exe) ? exe : null;
}

async function rememberFallbackBrowser() {
  if (process.platform !== 'win32') return;
  const prog = await currentDefaultProgId();
  if (prog && prog !== 'VimeoViewerURL') {
    const exe = await commandForProgId(prog);
    if (exe) { settings.fallbackBrowser = exe; settings.fallbackProgId = prog; saveSettings(); }
  }
}

async function isDefaultBrowser() {
  if (process.platform !== 'win32') return false;
  return (await currentDefaultProgId()) === 'VimeoViewerURL';
}

function openInBrowser(url) {
  if (process.platform === 'win32') {
    isDefaultBrowser().then(isDef => {
      if (!isDef) { shell.openExternal(url); return; }
      const exe = settings.fallbackBrowser;
      if (exe && fs.existsSync(exe)) spawn(exe, [url], { detached: true, stdio: 'ignore' }).unref();
      else shell.openExternal('microsoft-edge:' + url);
    });
  } else shell.openExternal(url);
}

// ---------- Vimeo API (relácia prihláseného používateľa) ----------
let jwt = null, jwtTime = 0;
async function getJwt() {
  if (jwt && Date.now() - jwtTime < 240000) return jwt;
  for (const p of ['/_next/viewer', '/_rv/viewer']) {
    try {
      const r = await session.defaultSession.fetch('https://vimeo.com' + p, {
        headers: { Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest' } });
      if (r.ok) {
        const j = await r.json();
        if (j && j.jwt) { jwt = j.jwt; jwtTime = Date.now(); return jwt; }
      }
    } catch (e) { log('Relácia', p + ' → ' + e.message); }
  }
  throw new Error('Vimeo nevrátilo prístupový kľúč');
}

async function api(method, p, body) {
  try {
    const token = await getJwt();
    const url = p.startsWith('http') ? p : 'https://api.vimeo.com' + p;
    const headers = { Authorization: 'jwt ' + token, Accept: 'application/vnd.vimeo.*+json;version=3.4' };
    if (body) headers['Content-Type'] = 'application/json';
    const r = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await r.text();
    let json = {};
    try { json = text ? JSON.parse(text) : {}; } catch { json = {}; }
    if (r.status === 401) jwt = null;
    const error = r.ok ? null : ((json && (json.developer_message || json.error)) || ('HTTP ' + r.status));
    if (!r.ok) log('API', `${method} ${p} → ${r.status} ${error}`);
    return { ok: r.ok, status: r.status, json, error };
  } catch (e) {
    log('API', `${method} ${p} → ${e.message}`);
    return { ok: false, status: 0, json: {}, error: e.message };
  }
}

// ---------- Prepis: titulky cez konfiguráciu prehrávača alebo zachytené z prehrávača ----------
let lastTrackURL = null;
async function playerTracks(ref) {
  const url = `https://player.vimeo.com/video/${ref.id}/config` + (ref.hash ? `?h=${ref.hash}` : '');
  try {
    const r = await session.defaultSession.fetch(url, { headers: { Referer: 'https://vimeo.com/' } });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const j = await r.json();
    const tt = (j.request && j.request.text_tracks) || [];
    return { ok: true, tracks: tt.map(t => ({ label: t.label || t.lang, lang: t.lang || '', url: new URL(t.url, 'https://player.vimeo.com').href, kind: t.kind || 'captions' })) };
  } catch (e) {
    log('Prepis', 'config → ' + e.message);
    return { ok: false, tracks: [], error: e.message };
  }
}

async function fetchText(url) {
  try {
    const r = await session.defaultSession.fetch(url, { headers: { Referer: 'https://player.vimeo.com/' } });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return { ok: true, text: await r.text() };
  } catch (e) {
    log('Prepis', url.slice(0, 80) + ' → ' + e.message);
    return { ok: false, error: e.message };
  }
}

// ---------- Prenosy (nahrávanie tus, sťahovanie) ----------
const transfers = [];
function pushTransfers() { if (win) win.webContents.send('transfers', transfers.map(t => ({ ...t, cancel: undefined }))); }

async function tusUpload(t, uploadLink, file, size) {
  const chunk = 16 * 1024 * 1024;
  let offset = 0;
  const fh = await fs.promises.open(file, 'r');
  try {
    while (offset < size) {
      if (t.cancelled) throw new Error('Zrušené');
      const len = Math.min(chunk, size - offset);
      const buf = Buffer.alloc(len);
      await fh.read(buf, 0, len, offset);
      let ok = false, lastErr = '';
      for (let attempt = 0; attempt < 4 && !ok; attempt++) {
        try {
          const r = await fetch(uploadLink, { method: 'PATCH', body: buf, headers: {
            'Tus-Resumable': '1.0.0', 'Upload-Offset': String(offset), 'Content-Type': 'application/offset+octet-stream' } });
          if (r.ok) { offset = Number(r.headers.get('upload-offset') || offset + len); ok = true; }
          else {
            lastErr = 'HTTP ' + r.status;
            const h = await fetch(uploadLink, { method: 'HEAD', headers: { 'Tus-Resumable': '1.0.0' } });
            offset = Number(h.headers.get('upload-offset') || offset);
          }
        } catch (e) { lastErr = e.message; await new Promise(res => setTimeout(res, 3000)); }
      }
      if (!ok) throw new Error(lastErr || 'Nahrávanie zlyhalo');
      t.progress = offset / size;
      t.status = `Nahrávam ${(offset / 1048576).toFixed(0)} z ${(size / 1048576).toFixed(0)} MB`;
      pushTransfers();
    }
  } finally { await fh.close(); }
}

async function startUpload({ kind, file, owner, folder, ref, title }) {
  const size = fs.statSync(file).size;
  const name = path.basename(file);
  const t = { id: Date.now() + Math.random(), type: 'upload', name: kind === 'replace' ? `Nahradenie: ${title} ← ${name}` : name,
              file, progress: 0, status: 'Pripravujem…', done: false, failed: false };
  transfers.unshift(t); pushTransfers();
  try {
    const body = { upload: { approach: 'tus', size } };
    let res;
    if (kind === 'replace') { body.file_name = name; res = await api('POST', `/videos/${ref.id}/versions`, body); }
    else { body.name = name.replace(/\.[^.]+$/, ''); res = await api('POST', `${owner}/videos`, body); }
    if (!res.ok) throw new Error(res.error);
    const link = res.json.upload && res.json.upload.upload_link;
    if (!link) throw new Error('Vimeo nevrátilo adresu na nahrávanie');
    await tusUpload(t, link, file, size);
    if (kind !== 'replace' && folder && res.json.uri) {
      const vid = res.json.uri.split('/').pop();
      const mv = await api('PUT', `${folder}/videos/${vid}`);
      if (!mv.ok) log('Nahrávanie', 'presun do priečinka → ' + mv.error);
    }
    t.done = true; t.progress = 1;
    t.status = kind === 'replace' ? 'Video nahradené – Vimeo spracúva novú verziu' : 'Nahraté – Vimeo video spracúva';
  } catch (e) {
    t.failed = true; t.status = 'Chyba: ' + e.message;
    log('Nahrávanie', e.message);
  }
  pushTransfers();
  if (win) win.webContents.send('upload-finished');
}

function startDownload(url, name) {
  dialog.showSaveDialog(win, { defaultPath: path.join(app.getPath('downloads'), name) }).then(r => {
    if (r.canceled || !r.filePath) return;
    const t = { id: Date.now() + Math.random(), type: 'download', name, file: r.filePath, progress: 0, status: 'Sťahujem…', done: false, failed: false };
    transfers.unshift(t); pushTransfers();
    pendingDownloads.push({ t, path: r.filePath });
    win.webContents.downloadURL(url);
  });
}
const pendingDownloads = [];

// ---------- Okná ----------
function createWindow() {
  win = new BrowserWindow({
    width: 1440, height: 900, minWidth: 1000, minHeight: 620,
    title: 'Vimeo Viewer', backgroundColor: '#f5f5f7',
    icon: path.join(__dirname, 'build', 'icon.ico'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  win.removeMenu();
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { route(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('file:')) { e.preventDefault(); route(url); } });
  win.webContents.once('did-finish-load', () => { if (pendingURL) { const u = pendingURL; pendingURL = null; route(u); } });
  win.on('closed', () => { win = null; });

  session.defaultSession.on('will-download', (e, item) => {
    const p = pendingDownloads.shift();
    if (!p) return;
    item.setSavePath(p.path);
    p.t.cancel = () => item.cancel();
    item.on('updated', () => {
      const total = item.getTotalBytes();
      if (total > 0) { p.t.progress = item.getReceivedBytes() / total; p.t.status = `${(item.getReceivedBytes() / 1048576).toFixed(0)} z ${(total / 1048576).toFixed(0)} MB`; }
      pushTransfers();
    });
    item.once('done', (ev, state) => {
      if (state === 'completed') { p.t.done = true; p.t.progress = 1; p.t.status = 'Hotovo'; }
      else { p.t.failed = true; p.t.status = state === 'cancelled' ? 'Zrušené' : 'Sťahovanie zlyhalo'; }
      pushTransfers();
    });
  });
}

let browseWin = null;
function openBrowse(url) {
  if (!browseWin) {
    browseWin = new BrowserWindow({ width: 1280, height: 860, title: 'Vimeo', icon: path.join(__dirname, 'build', 'icon.ico'),
      webPreferences: { contextIsolation: true } });
    browseWin.removeMenu();
    browseWin.on('closed', () => { browseWin = null; });
    const check = (e, u) => {
      const ref = videoRef(u);
      if (ref && !(browseWin.allowVideo === ref.id)) {
        if (e && e.preventDefault) e.preventDefault();
        if (win) { win.webContents.send('open-video', ref); focusWin(); }
        return true;
      }
      return false;
    };
    browseWin.webContents.on('will-navigate', (e, u) => check(e, u));
    browseWin.webContents.on('did-navigate-in-page', (e, u) => { if (check(null, u) && browseWin.webContents.canGoBack()) browseWin.webContents.goBack(); });
    browseWin.webContents.setWindowOpenHandler(({ url: u }) => {
      try { if (isVimeoHost(new URL(u).hostname) || /accounts\.google\.com|appleid\.apple\.com/.test(u)) return { action: 'allow' }; } catch {}
      openInBrowser(u); return { action: 'deny' };
    });
  }
  const ref = videoRef(url);
  browseWin.allowVideo = ref ? ref.id : null;
  browseWin.loadURL(url);
  browseWin.show();
  browseWin.focus();
}

function openLogin() {
  return new Promise(resolve => {
    const lw = new BrowserWindow({ width: 560, height: 780, title: 'Prihlásenie do Vimea', parent: win, modal: false,
      icon: path.join(__dirname, 'build', 'icon.ico'), webPreferences: { contextIsolation: true } });
    lw.removeMenu();
    lw.webContents.setWindowOpenHandler(() => ({ action: 'allow' }));
    let done = false;
    const check = async () => {
      if (done) return;
      jwt = null;
      const me = await api('GET', '/me?fields=name,uri');
      if (me.ok && me.json.name) { done = true; resolve({ ok: true, name: me.json.name }); if (!lw.isDestroyed()) lw.close(); }
    };
    lw.webContents.on('did-navigate', check);
    lw.webContents.on('did-navigate-in-page', check);
    lw.on('closed', () => { if (!done) { done = true; jwt = null; api('GET', '/me?fields=name').then(me => resolve({ ok: me.ok && !!me.json.name, name: me.json.name })); } });
    lw.loadURL('https://vimeo.com/log_in');
  });
}

// ---------- Aktualizácie ----------
function isNewer(a, b) {
  const pa = a.split('.').map(Number), pb = b.split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0, y = pb[i] || 0;
    if (x !== y) return x > y;
  }
  return false;
}

async function checkUpdates(userInitiated) {
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { 'User-Agent': 'VimeoViewer', Accept: 'application/vnd.github+json' } });
    const j = await r.json();
    const latest = String(j.tag_name || '').replace(/^v/, '');
    const asset = (j.assets || []).find(a => a.name === 'VimeoViewer-Setup.exe');
    if (asset && isNewer(latest, app.getVersion())) {
      const res = await dialog.showMessageBox(win, { type: 'info', buttons: ['Aktualizovať', 'Neskôr'], defaultId: 0,
        message: `Je dostupná nová verzia ${latest}`, detail: `Máte verziu ${app.getVersion()}. Aplikácia sa po aktualizácii sama znova spustí.` });
      if (res.response !== 0) return;
      const d = await fetch(asset.browser_download_url);
      const file = path.join(os.tmpdir(), 'VimeoViewer-Setup.exe');
      fs.writeFileSync(file, Buffer.from(await d.arrayBuffer()));
      spawn(file, ['--updated'], { detached: true, stdio: 'ignore' }).unref();
      app.quit();
    } else if (userInitiated) {
      dialog.showMessageBox(win, { message: 'Máte najnovšiu verziu', detail: `Vimeo Viewer ${app.getVersion()} je aktuálny.` });
    }
  } catch (e) {
    log('Aktualizácie', e.message);
    if (userInitiated) dialog.showMessageBox(win, { type: 'warning', message: 'Aktualizácie sa nepodarilo overiť', detail: e.message });
  }
}

// ---------- IPC ----------
ipcMain.handle('api', (e, method, p, body) => api(method, p, body));
ipcMain.handle('reset-session', () => { jwt = null; return true; });
ipcMain.handle('login', () => openLogin());
ipcMain.handle('logout', async () => {
  const cookies = await session.defaultSession.cookies.get({});
  for (const c of cookies) if ((c.domain || '').includes('vimeo')) {
    const url = `https://${c.domain.replace(/^\./, '')}${c.path}`;
    await session.defaultSession.cookies.remove(url, c.name);
  }
  jwt = null;
  return true;
});
ipcMain.handle('player-tracks', (e, ref) => playerTracks(ref));
ipcMain.handle('fetch-text', (e, url) => fetchText(url));
ipcMain.handle('last-track-url', () => lastTrackURL);
ipcMain.handle('open-external', (e, url) => { openInBrowser(url); return true; });
ipcMain.handle('open-browse', (e, url) => { openBrowse(url); return true; });
ipcMain.handle('route', (e, url) => { route(url); return true; });
ipcMain.handle('copy', (e, text) => { clipboard.writeText(text); return true; });
ipcMain.handle('choose-files', async (e, opts) => {
  const r = await dialog.showOpenDialog(win, { properties: opts.multiple ? ['openFile', 'multiSelections'] : ['openFile'],
    filters: opts.filters, title: opts.title });
  return r.canceled ? [] : r.filePaths;
});
ipcMain.handle('read-file', (e, file) => { try { return fs.readFileSync(file, 'utf8'); } catch { return null; } });
ipcMain.handle('save-text', async (e, name, text) => {
  const r = await dialog.showSaveDialog(win, { defaultPath: path.join(app.getPath('documents'), name) });
  if (r.canceled || !r.filePath) return false;
  fs.writeFileSync(r.filePath, text, 'utf8');
  return true;
});
ipcMain.handle('upload', (e, opts) => { startUpload(opts); return true; });
ipcMain.handle('download', (e, url, name) => { startDownload(url, name); return true; });
ipcMain.handle('transfer-cancel', (e, id) => {
  const t = transfers.find(x => x.id === id);
  if (t) { t.cancelled = true; if (t.cancel) t.cancel(); }
  return true;
});
ipcMain.handle('transfer-show', (e, file) => { shell.showItemInFolder(file); return true; });
ipcMain.handle('transfers-clear', () => { for (let i = transfers.length - 1; i >= 0; i--) if (transfers[i].done || transfers[i].failed) transfers.splice(i, 1); pushTransfers(); return true; });
ipcMain.handle('upload-subtitles', async (e, ref, file, language, kind, name) => {
  const res = await api('POST', `/videos/${ref.id}/texttracks`, { type: kind, language, name });
  if (!res.ok) return { ok: false, error: res.error };
  try {
    const data = fs.readFileSync(file);
    const r = await fetch(res.json.link, { method: 'PUT', body: data, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
    if (!r.ok) return { ok: false, error: 'HTTP ' + r.status };
    await api('PATCH', res.json.uri, { active: true });
    return { ok: true };
  } catch (err) { return { ok: false, error: err.message }; }
});
ipcMain.handle('translate', async (e, texts, target, deeplKey) => translate(texts, target, deeplKey));
ipcMain.handle('settings-get', () => settings);
ipcMain.handle('settings-set', (e, patch) => { Object.assign(settings, patch); saveSettings(); return settings; });
ipcMain.handle('diag', () => diag.join('\n'));
ipcMain.handle('diag-log', (e, src, msg) => { log(src, msg); return true; });
ipcMain.handle('diag-clear', () => { diag.length = 0; return true; });
ipcMain.handle('check-updates', () => checkUpdates(true));
ipcMain.handle('default-browser-status', async () => ({ isDefault: await isDefaultBrowser(), fallback: settings.fallbackBrowser || null }));
ipcMain.handle('make-default-browser', async () => {
  await rememberFallbackBrowser();
  shell.openExternal('ms-settings:defaultapps?registeredAppUser=VimeoViewer');
  return true;
});
ipcMain.handle('app-info', () => ({ version: app.getVersion(), platform: process.platform, electron: process.versions.electron }));
ipcMain.handle('menu', (e, items) => new Promise(resolve => {
  let picked = false;
  const tpl = items.map(i => i === '-' ? { type: 'separator' } : { label: i.label, enabled: i.enabled !== false,
    click: () => { picked = true; resolve(i.id); } });
  Menu.buildFromTemplate(tpl).popup({ window: win, callback: () => setTimeout(() => { if (!picked) resolve(null); }, 80) });
}));

// ---------- Preklad ----------
async function translate(texts, target, deeplKey) {
  const out = texts.slice();
  try {
    if (deeplKey) {
      const host = deeplKey.endsWith(':fx') ? 'https://api-free.deepl.com' : 'https://api.deepl.com';
      let t = target.toUpperCase(); if (t === 'EN') t = 'EN-GB'; if (t === 'PT') t = 'PT-PT';
      for (let i = 0; i < texts.length; i += 50) {
        const part = texts.slice(i, i + 50);
        const r = await fetch(host + '/v2/translate', { method: 'POST', headers: { Authorization: 'DeepL-Auth-Key ' + deeplKey, 'Content-Type': 'application/json' },
          body: JSON.stringify({ text: part, target_lang: t }) });
        if (!r.ok) throw new Error(r.status === 403 ? 'Neplatný DeepL kľúč' : 'DeepL HTTP ' + r.status);
        const j = await r.json();
        j.translations.forEach((x, k) => { out[i + k] = x.text; });
        if (win) win.webContents.send('translate-progress', Math.min(1, (i + 50) / texts.length));
      }
      return { ok: true, texts: out };
    }
    const batches = [];
    let cur = [], chars = 0;
    texts.forEach((t, i) => {
      if (cur.length && (chars + t.length > 1500 || cur.length >= 200)) { batches.push(cur); cur = []; chars = 0; }
      cur.push(i); chars += t.length + 1;
    });
    if (cur.length) batches.push(cur);
    const g = async q => {
      const u = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&dt=t&tl=' + encodeURIComponent(target) + '&q=' + encodeURIComponent(q);
      const r = await fetch(u);
      if (!r.ok) throw new Error('Prekladač HTTP ' + r.status);
      const j = await r.json();
      return (j[0] || []).map(s => s[0]).join('');
    };
    for (let b = 0; b < batches.length; b++) {
      const idx = batches[b];
      const res = (await g(idx.map(i => texts[i].replace(/\n/g, ' ')).join('\n'))).split('\n').map(s => s.trim());
      if (res.length === idx.length) idx.forEach((i, k) => { out[i] = res[k]; });
      else for (const i of idx) out[i] = (await g(texts[i])).trim();
      if (win) win.webContents.send('translate-progress', (b + 1) / batches.length);
    }
    return { ok: true, texts: out };
  } catch (e) {
    log('Preklad', e.message);
    return { ok: false, error: e.message };
  }
}

// ---------- Štart ----------
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (e, argv) => {
    const u = findURL(argv);
    if (u) route(u); else focusWin();
  });
  app.on('open-url', (e, url) => { e.preventDefault(); route(url); });
  app.setAsDefaultProtocolClient('vimeoviewer');

  app.whenReady().then(() => {
    loadSettings();
    // Vystupovať ako bežný Chrome (prihlasovanie cez Google odmieta Electron).
    const ua = session.defaultSession.getUserAgent().replace(/ Electron\/\S+/, '').replace(/ vimeo-viewer\/\S+/i, '');
    session.defaultSession.setUserAgent(ua);
    app.userAgentFallback = ua;
    // Prehrávač vo vnútri aplikácie sa tvári ako vložený na vimeo.com (kvôli obmedzeniam vkladania).
    session.defaultSession.webRequest.onBeforeSendHeaders({ urls: ['*://player.vimeo.com/*'] }, (d, cb) => {
      if (!d.requestHeaders.Referer || d.requestHeaders.Referer.startsWith('file:')) d.requestHeaders.Referer = 'https://vimeo.com/';
      cb({ requestHeaders: d.requestHeaders });
    });
    // Zachytenie adresy titulkov, ktoré si stiahne prehrávač (pre prepis).
    session.defaultSession.webRequest.onCompleted({ urls: ['*://captions.vimeo.com/*', '*://*.vimeo.com/*texttrack*', '*://*.vimeocdn.com/*.vtt*'] }, d => {
      if (d.statusCode < 400) lastTrackURL = d.url;
    });
    createWindow();
    const u = findURL(process.argv);
    if (u) pendingURL = normalize(u);
    setTimeout(() => checkUpdates(false), 5000);
  });
  app.on('window-all-closed', () => app.quit());
}
