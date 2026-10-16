// WhatsApp — minimal, self-contained Electron wrapper.
//
// What it does (and why):
//   * Loads WhatsApp Web (web.whatsapp.com).
//   * Grants the `notifications` permission (request AND check handlers) so
//     WhatsApp actually shows real desktop notifications instead of the
//     "Autoriser les notifications" banner.
//   * Removes the application menu entirely (no WhatsApp/Edit/Help menu bar).
//   * Adds a tray icon; closing the window hides it to the tray instead of
//     quitting, and the tray menu can show it again or really quit.
//   * Audio is left to WhatsApp itself; visual notifications are forced silent
//     by preload.js, so the user gets popups with no notification sound.
'use strict';

const {
  app,
  BrowserWindow,
  Menu,
  Tray,
  nativeImage,
  session,
  shell,
} = require('electron');
const path = require('path');

const START_URL = 'https://web.whatsapp.com/';
const ICON_PATH = path.join(__dirname, 'icon.png');

let mainWindow = null;
let tray = null;
let isQuitting = false;

// Single instance: a second launch just focuses the existing window.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    showWindow();
  });
}

function showWindow() {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
}

function createTray() {
  let image = nativeImage.createFromPath(ICON_PATH);
  if (image.isEmpty()) {
    // Fall back to an empty image so the tray still exists.
    image = nativeImage.createEmpty();
  }
  tray = new Tray(image);
  tray.setToolTip('WhatsApp');

  const menu = Menu.buildFromTemplate([
    { label: 'Ouvrir WhatsApp', click: showWindow },
    { type: 'separator' },
    {
      label: 'Quitter',
      click: () => {
        isQuitting = true;
        app.quit();
      },
    },
  ]);
  tray.setContextMenu(menu);
  tray.on('click', showWindow);
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 780,
    icon: ICON_PATH,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      // The preload must patch the PAGE's globals (window.Notification,
      // navigator.permissions). With contextIsolation on, those changes would
      // stay in an isolated world and never reach WhatsApp's code — so we keep
      // it off. nodeIntegration stays off, so the page still has no require().
      contextIsolation: false,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  // Belt-and-braces: no menu bar at all.
  mainWindow.setMenuBarVisibility(false);
  mainWindow.removeMenu();

  mainWindow.loadURL(START_URL, {
    userAgent:
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' +
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
  });

  // Open external links (e.g. wa.me, help pages) in the system browser.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      shell.openExternal(url);
    }
    return { action: 'deny' };
  });

  // Silent notifications: WhatsApp plays its own in-page notification sound
  // (independent of the OS notification API). That sound only ever fires while
  // the window is NOT focused, so we mute the renderer whenever it loses focus
  // and unmute when it regains focus — voice messages while you're looking at
  // the app keep their audio, notification pings are silent.
  mainWindow.on('blur', () => {
    if (mainWindow) mainWindow.webContents.setAudioMuted(true);
  });
  mainWindow.on('focus', () => {
    if (mainWindow) mainWindow.webContents.setAudioMuted(false);
  });
  mainWindow.on('hide', () => {
    if (mainWindow) mainWindow.webContents.setAudioMuted(true);
  });

  // Close-to-tray: hide instead of quitting when the user closes the window.
  mainWindow.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

function grantNotifications() {
  const ses = session.defaultSession;

  ses.setPermissionRequestHandler((_wc, permission, callback) => {
    if (permission === 'notifications' || permission === 'media') {
      return callback(true);
    }
    // Grant the common web-app permissions WhatsApp may ask for.
    const allowed = new Set([
      'fullscreen',
      'clipboard-read',
      'clipboard-sanitized-write',
      'display-capture',
    ]);
    return callback(allowed.has(permission));
  });

  ses.setPermissionCheckHandler((_wc, permission) => {
    if (permission === 'notifications' || permission === 'media') {
      return true;
    }
    return false;
  });
}

app.whenReady().then(() => {
  Menu.setApplicationMenu(null);
  grantNotifications();
  createWindow();
  createTray();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    } else {
      showWindow();
    }
  });
});

// Do NOT quit on window close — we live in the tray.
app.on('window-all-closed', () => {
  // Keep running in the tray on all platforms.
});

app.on('before-quit', () => {
  isQuitting = true;
});
