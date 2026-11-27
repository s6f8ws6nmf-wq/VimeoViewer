'use strict';
const { contextBridge, ipcRenderer } = require('electron');

const inv = (ch, ...a) => ipcRenderer.invoke(ch, ...a);

contextBridge.exposeInMainWorld('vv', {
  api: (method, path, body) => inv('api', method, path, body),
  resetSession: () => inv('reset-session'),
  login: () => inv('login'),
  logout: () => inv('logout'),
  playerTracks: ref => inv('player-tracks', ref),
  fetchText: url => inv('fetch-text', url),
  lastTrackURL: () => inv('last-track-url'),
  openExternal: url => inv('open-external', url),
  openBrowse: url => inv('open-browse', url),
  route: url => inv('route', url),
  copy: text => inv('copy', text),
  chooseFiles: opts => inv('choose-files', opts),
  readFile: file => inv('read-file', file),
  saveText: (name, text) => inv('save-text', name, text),
  upload: opts => inv('upload', opts),
  download: (url, name) => inv('download', url, name),
  transferCancel: id => inv('transfer-cancel', id),
  transferShow: file => inv('transfer-show', file),
  transfersClear: () => inv('transfers-clear'),
  uploadSubtitles: (ref, file, lang, kind, name) => inv('upload-subtitles', ref, file, lang, kind, name),
  translate: (texts, target, key) => inv('translate', texts, target, key),
  settingsGet: () => inv('settings-get'),
  settingsSet: patch => inv('settings-set', patch),
  diag: () => inv('diag'),
  diagLog: (src, msg) => inv('diag-log', src, msg),
  diagClear: () => inv('diag-clear'),
  checkUpdates: () => inv('check-updates'),
  defaultBrowserStatus: () => inv('default-browser-status'),
  makeDefaultBrowser: () => inv('make-default-browser'),
  appInfo: () => inv('app-info'),
  menu: items => inv('menu', items),
  on: (channel, cb) => {
    const ok = ['open-video', 'transfers', 'upload-finished', 'translate-progress'];
    if (ok.includes(channel)) ipcRenderer.on(channel, (e, ...a) => cb(...a));
  },
});
