// WhatsApp preload — runs in the page before any page script.
// Guarantees desktop notifications are ENABLED and SILENT:
//   1. Notification.permission always reads "granted" (so WhatsApp stops
//      showing its "Autoriser les notifications / icône près de la barre
//      d'adresse" banner and starts using the real Notification API).
//   2. Every Notification we construct is forced to silent:true, so the OS
//      notification pops up VISIBLY without playing any sound.
(() => {
  'use strict';

  const ForcedNotification = function Notification(title, options) {
    if (!(this instanceof ForcedNotification)) {
      return new ForcedNotification(title, options);
    }
    const opts = Object.assign({}, options || {}, { silent: true });
    try {
      return new nativeNotification(title, opts);
    } catch (e) {
      // Fallback: if the native constructor throws, ignore quietly.
      return null;
    }
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
