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
  ipcMain,
  powerMonitor,
} = require('electron');
const path = require('path');

const START_URL = 'https://web.whatsapp.com/';
const ICON_PATH = path.join(__dirname, 'icon.png');

// WhatsApp Web refuses to load in a browser it considers unsupported, and a
// rejected client renders as a permanent, silent WHITE window (no error page).
// Electron's own default UA advertises "Electron/<v>" (and its bundled Chromium
// may be far newer than the Chrome token we used to hard-code: Electron 43 ships
// Chromium 150, while the old string said Chrome/130) — an inconsistency
// WhatsApp's client-side checks can flag. Report the REAL bundled Chromium
// version, and drop the Electron token, so the UA matches navigator.userAgentData.
const CHROME_VERSION = process.versions.chrome || '130.0.0.0';
const USER_AGENT =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/' + CHROME_VERSION + ' Safari/537.36';

let mainWindow = null;
let tray = null;
let isQuitting = false;
let lastRecovery = 0;

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

// After suspend/resume (and after a GPU process crash) the Wayland surface can
// come back blank while the page itself is still loaded. Reload once, throttled
// so a crash loop cannot turn into a reload loop.
function recoverWindow(why) {
  if (isQuitting || !mainWindow || mainWindow.isDestroyed()) return;
  if (mainWindow.webContents.isLoading()) return;
  const now = Date.now();
  if (now - lastRecovery < 5000) return;
  lastRecovery = now;
  console.error('WhatsApp: ' + why + ' — reloading');
  mainWindow.webContents.reload();
}

// Clicking a desktop notification (forwarded by preload.js) must raise the
// window — even when it was closed to the tray.
ipcMain.on('whatsapp:notification-click', () => {
  showWindow();
});

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

function createWindow(startHidden) {
  startHidden = !!startHidden;
  mainWindow = new BrowserWindow({
    show: !startHidden,
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

  mainWindow.loadURL(START_URL, { userAgent: USER_AGENT });

  // A failed main-frame load used to leave the window blank forever (there was
  // no handler at all). WhatsApp Web can also lose its renderer; retry instead
  // of staying white. `-3` is ERR_ABORTED, which fires on ordinary in-app
  // navigations, so ignore it.
  let reloadTimer = null;
  const retryLoad = (why) => {
    if (reloadTimer) return;
    console.error('WhatsApp: ' + why + ' — reloading in 2s');
    reloadTimer = setTimeout(() => {
      reloadTimer = null;
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.loadURL(START_URL, { userAgent: USER_AGENT });
      }
    }, 2000);
  };
  mainWindow.webContents.on('did-fail-load', (_e, code, desc, _url, isMainFrame) => {
    if (isMainFrame && code !== -3) retryLoad('main-frame load failed (' + code + ' ' + desc + ')');
  });
  mainWindow.webContents.on('render-process-gone', (_e, details) => {
    if (details.reason !== 'clean-exit') retryLoad('renderer gone (' + details.reason + ')');
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
  mainWindow.on('show', () => {
    if (mainWindow) mainWindow.webContents.invalidate();
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
  const startInTray = process.argv.some((a) => a === '--start-in-tray');
  createWindow(startInTray);
  createTray();
  if (startInTray && mainWindow) {
    mainWindow.hide();
  }

  powerMonitor.on('resume', () => {
    setTimeout(() => recoverWindow('resumed from sleep'), 2000);
  });

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

app.on('child-process-gone', (_event, details) => {
  if (details.type === 'GPU' && details.reason !== 'clean-exit') {
    recoverWindow('GPU process gone (' + details.reason + ')');
  }
});

app.on('before-quit', () => {
  isQuitting = true;
});
