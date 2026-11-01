'use strict';

// WhatsApp tray supervisor.
//
// The visible app is Chromium in web-app mode (`--app=https://web.whatsapp.com`),
// the same mechanism Omarchy uses for its web apps. This Electron process owns
// ONLY the tray icon and the lifecycle:
//   * start Chromium on the hidden `special:whatsapp` workspace at login;
//   * show/focus it from the tray or from a menu launch;
//   * when the Chromium window is closed, relaunch it hidden (close-to-tray);
//   * mute WhatsApp's audio stream while it is hidden, so notification chimes
//     stay silent; the extension also forces `silent: true` on notifications.
//
// There is deliberately no BrowserWindow here: the white first-paint bug of the
// old wrapper cannot happen because Electron never renders WhatsApp.

const { app, Tray, Menu, nativeImage } = require('electron');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = os.homedir();
const DATA = path.join(HOME, '.local/share/whatsapp-web');
const STATE = path.join(HOME, '.local/state/whatsapp-web');
const PROFILE = path.join(DATA, 'profile');
const EXT = path.join(DATA, 'extension');
const ICON = path.join(__dirname, 'icon.png');
const PIDFILE = path.join(STATE, 'tray.pid');
const CMD = path.join(STATE, 'command');
const URL = 'https://web.whatsapp.com/';
const CHROMIUM = process.env.WHATSAPP_CHROMIUM || '/usr/bin/chromium';
const ARGS = [
  `--app=${URL}`,
  `--user-data-dir=${PROFILE}`,
  // Keep the cookie-encryption key in the profile instead of the desktop
  // keyring. At login the tray starts before the keyring is unlocked, and a
  // Chromium that cannot read that key treats every saved cookie as invalid —
  // WhatsApp then asks for the QR code again on the next launch.
  '--password-store=basic',
  `--load-extension=${EXT}`,
  `--disable-extensions-except=${EXT}`,
  '--no-first-run',
  '--no-default-browser-check',
  '--hide-crash-restore-bubble',
  '--disable-background-timer-throttling',
  '--disable-backgrounding-occluded-windows',
  '--disable-renderer-backgrounding',
  '--ozone-platform-hint=auto',
  '--enable-features=WaylandWindowDecorations',
  '--enable-wayland-ime',
];

let tray = null;
let quitting = false;
let lastStart = 0;
let launchingUntil = 0;
let noWindowSince = 0;
let pollTimer = null;
let cmdTimer = null;

fs.mkdirSync(STATE, { recursive: true });
fs.mkdirSync(PROFILE, { recursive: true });

function hypr(...args) {
  return execFileSync('hyprctl', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
}

function luaEval(code) {
  return hypr('eval', code);
}

function activeWorkspaceName() {
  // The workspace the user is actually looking at. `activeWorkspace` is the
  // normal workspace even while a special (scratchpad) is displayed, so this
  // never re-opens WhatsApp inside a special workspace.
  try {
    const monitors = JSON.parse(hypr('monitors', '-j'));
    const m = monitors.find(x => x.focused) || monitors[0];
    return String(m?.activeWorkspace?.name || '1');
  } catch {
    return '1';
  }
}

function shellQuote(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

function chromiumRunning() {
  try {
    execFileSync('pgrep', ['-f', '--', `--app=${URL}`], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function findWindow() {
  try {
    const clients = JSON.parse(hypr('clients', '-j'));
    return clients.find(c => {
      const cls = `${c.class || ''} ${c.initialClass || ''}`.toLowerCase();
      const title = `${c.title || ''} ${c.initialTitle || ''}`.toLowerCase();
      return cls.includes('whatsapp') || title.includes('whatsapp');
    }) || null;
  } catch {
    return null;
  }
}

function setMuted(mute) {
  try {
    const inputs = JSON.parse(execFileSync('pactl', ['-f', 'json', 'list', 'sink-inputs'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }));
    for (const si of inputs) {
      const name = String(si.properties?.['application.name'] || '').toLowerCase();
      if (name.includes('whatsapp')) {
        execFileSync('pactl', ['set-sink-input-mute', String(si.index), mute ? '1' : '0'],
          { stdio: 'ignore' });
      }
    }
  } catch {
    // No PipeWire/PulseAudio stream yet, or pactl missing: audio is best-effort.
  }
}

function spawnVisible() {
  lastStart = Date.now();
  launchingUntil = lastStart + 15000;
  noWindowSince = 0;
  const child = spawn(CHROMIUM, ARGS, {
    env: { ...process.env, PULSE_PROP: 'application.name=WhatsApp' },
    detached: true,
    stdio: 'ignore',
  });
  child.unref();
  setMuted(false);
}

function luaQuote(s) {
  return JSON.stringify(String(s));
}

function spawnHidden() {
  if (chromiumRunning()) { hideWindow(); return; }
  lastStart = Date.now();
  launchingUntil = lastStart + 15000;
  noWindowSince = 0;
  const cmd = `[workspace special:whatsapp silent] env PULSE_PROP=application.name=WhatsApp ${shellQuote(CHROMIUM)} ${ARGS.map(shellQuote).join(' ')}`;
  try {
    hypr('eval', `hl.dispatch(hl.dsp.exec_cmd(${luaQuote(cmd)}))`);
  } catch {
    // A Hyprland that refuses the rule still gets a visible window; better than
    // no WhatsApp at all.
    spawnVisible();
    return;
  }
  setTimeout(() => setMuted(true), 1500);
}

function showWindow() {
  const win = findWindow();
  if (!win) {
    if (!chromiumRunning()) {
      // A launch is already in flight (e.g. login's hidden start still
      // loading): do not start a second Chromium on the same profile.
      if (Date.now() < launchingUntil) setTimeout(showWindow, 800);
      else spawnVisible();
    } else {
      setTimeout(showWindow, 800);
    }
    return;
  }
  const ws = String(win.workspace?.name || '');
  const focusWin = () => {
    try {
      luaEval(`hl.dispatch(hl.dsp.focus({ window = ${luaQuote(`address:${win.address}`)} }))`);
    } catch {}
  };
  // Login starts the window on special:whatsapp (hidden). Opening it from the
  // tray/menu moves it to the normal workspace the user is on — never by
  // toggling the special workspace, which looked like a scratchpad.
  if (ws.startsWith('special:')) {
    const target = activeWorkspaceName();
    try {
      luaEval(`hl.dispatch(hl.dsp.window.move({ window = ${luaQuote(`address:${win.address}`)}, workspace = ${luaQuote(target)} }))`);
    } catch {}
    // The move is asynchronous; focusing in the same tick can lose to the
    // workspace's previous window (Nautilus/Zen stayed on top).
    setTimeout(focusWin, 250);
  } else {
    focusWin();
  }
  setMuted(false);
}

function hideWindow() {
  const win = findWindow();
  if (!win) return;
  try {
    luaEval(`hl.dispatch(hl.dsp.window.move({ window = ${luaQuote(`address:${win.address}`)}, workspace = "special:whatsapp", follow = false }))`);
  } catch {}
  setMuted(true);
}

function quitApp() {
  if (quitting) return;
  quitting = true;
  killChromium();
  try { fs.unlinkSync(PIDFILE); } catch {}
  app.quit();
}

function killChromium() {
  try { execFileSync('pkill', ['-TERM', '-f', '--', `--app=${URL}`], { stdio: 'ignore' }); } catch {}
}

function poll() {
  if (quitting) return;
  const win = findWindow();
  if (win) {
    noWindowSince = 0;
    const ws = String(win.workspace?.name || '');
    setMuted(ws.startsWith('special:whatsapp'));
    return;
  }
  // No window: either Chromium exited (close-to-tray: relaunch it hidden) or
  // it is running without ever mapping a window (stuck startup). The 15 s
  // launching window keeps login/menu launches from being doubled.
  if (!chromiumRunning()) {
    if (Date.now() > launchingUntil) spawnHidden();
    return;
  }
  if (!noWindowSince) noWindowSince = Date.now();
  if (Date.now() - noWindowSince > 20000 && Date.now() > launchingUntil) {
    noWindowSince = 0;
    killChromium();
    spawnHidden();
  }
}

function readCommand() {
  if (!fs.existsSync(CMD)) return;
  let cmd = '';
  try {
    cmd = fs.readFileSync(CMD, 'utf8').trim();
    fs.unlinkSync(CMD);
  } catch {
    return;
  }
  if (cmd === 'show') showWindow();
  else if (cmd === 'quit') quitApp();
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.setName('WhatsApp');
  app.on('second-instance', () => showWindow());
  app.whenReady().then(() => {
    // Write the PID before anything can fail: the launcher uses it to decide
    // whether another supervisor is already running.
    try { fs.writeFileSync(PIDFILE, `${process.pid}\n`); } catch {}

    // Electron's Tray needs the StatusNotifier host. At login the supervisor
    // can start a second before the Omarchy shell has registered it; retry
    // instead of dying and leaving the user without WhatsApp for the session.
    const createTray = () => {
      try {
        let image = nativeImage.createFromPath(ICON);
        if (image.isEmpty()) image = nativeImage.createEmpty();
        tray = new Tray(image);
        tray.setToolTip('WhatsApp');
        tray.setContextMenu(Menu.buildFromTemplate([
          { label: 'Ouvrir WhatsApp', click: showWindow },
          { label: 'Masquer dans la tray', click: hideWindow },
          { type: 'separator' },
          { label: 'Quitter', click: quitApp },
        ]));
        tray.on('click', showWindow);
        return true;
      } catch {
        tray = null;
        return false;
      }
    };
    if (!createTray()) {
      const retry = setInterval(() => {
        if (quitting) { clearInterval(retry); return; }
        if (createTray()) clearInterval(retry);
      }, 2000);
    }

    if (process.env.WHATSAPP_START_HIDDEN === '1') spawnHidden();
    else showWindow();

    pollTimer = setInterval(poll, 1000);
    cmdTimer = setInterval(readCommand, 400);
  });
}

app.on('before-quit', () => {
  quitting = true;
  if (pollTimer) clearInterval(pollTimer);
  if (cmdTimer) clearInterval(cmdTimer);
  try { fs.unlinkSync(PIDFILE); } catch {}
});
