// WhatsApp preload — runs in the page before any page script.
// Guarantees desktop notifications are ENABLED and SILENT:
//   1. Notification.permission always reads "granted" (so WhatsApp stops
//      showing its "Autoriser les notifications / icône près de la barre
//      d'adresse" banner and starts using the real Notification API).
//   2. Every Notification we construct is forced to silent:true, so the OS
//      notification pops up VISIBLY without playing any sound.
(() => {
  'use strict';

  // Bridge to the main process so clicking a notification can raise the
  // window. WhatsApp Web manages the notification in the page, but clicking
  // the OS popup only fires the page-side click handler — it never shows the
  // window the user closed to the tray. We forward every click to main.js,
  // which calls showWindow() on the real BrowserWindow.
  let ipcRenderer = null;
  try {
    ({ ipcRenderer } = require('electron'));
  } catch (e) {
    ipcRenderer = null;
  }

  const ForcedNotification = function Notification(title, options) {
    if (!(this instanceof ForcedNotification)) {
      return new ForcedNotification(title, options);
    }
    const opts = Object.assign({}, options || {}, { silent: true });
    let n = null;
    try {
      n = new nativeNotification(title, opts);
    } catch (e) {
      // Fallback: if the native constructor throws, ignore quietly.
      return null;
    }
    // Additive listener: WhatsApp's own onclick stays intact, ours just asks
    // the main process to surface the window.
    try {
      if (n && ipcRenderer) {
        n.addEventListener('click', () => {
          try { ipcRenderer.send('whatsapp:notification-click'); } catch (e) { /* ignore */ }
        });
      }
    } catch (e) { /* ignore */ }
    return n;
  };

  // Capture the real, page-native Notification before we shadow it.
  let nativeNotification = null;
  try {
    nativeNotification = window.Notification;
  } catch (e) {
    nativeNotification = null;
  }

  if (nativeNotification) {
    // Static permission -> always granted.
    try {
      Object.defineProperty(ForcedNotification, 'permission', {
        configurable: true,
        get: () => 'granted',
      });
    } catch (e) { /* ignore */ }

    // Copy any static helpers WhatsApp might reach for.
    try {
      ForcedNotification.requestPermission = () =>
        Promise.resolve('granted');
    } catch (e) { /* ignore */ }

    // Replace the global constructor.
    try {
      Object.defineProperty(window, 'Notification', {
        configurable: true,
        writable: true,
        value: ForcedNotification,
      });
    } catch (e) {
      try { window.Notification = ForcedNotification; } catch (e2) { /* ignore */ }
    }
  }

  // Some builds consult navigator.permissions.query({name:'notifications'}).
  // Make that report "granted" too, so nothing stays stuck in "default".
  try {
    const origQuery = navigator.permissions && navigator.permissions.query;
    if (origQuery) {
      navigator.permissions.query = (desc) => {
        try {
          if (desc && desc.name === 'notifications') {
            return Promise.resolve({ state: 'granted', status: 'granted' });
          }
        } catch (e) { /* fall through */ }
        return origQuery.call(navigator.permissions, desc);
      };
    }
  } catch (e) { /* ignore */ }
})();
