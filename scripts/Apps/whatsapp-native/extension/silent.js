// Force every WhatsApp Web notification to be silent.
//
// WhatsApp asks for notification permission and plays its own chime only while
// the window is not focused. The tray supervisor mutes the Chromium audio
// stream while WhatsApp is hidden; this content script removes the other sound
// source, the desktop notification itself.
(() => {
  const Orig = window.Notification;
  if (typeof Orig !== 'function') return;

  function SilentNotification(title, options) {
    const opts = Object.assign({}, options || {}, { silent: true });
    return new Orig(title, opts);
  }
  SilentNotification.requestPermission = Orig.requestPermission.bind(Orig);
  Object.defineProperty(SilentNotification, 'permission', {
    get: () => Orig.permission,
  });
  SilentNotification.maxActions = Orig.maxActions;
  window.Notification = SilentNotification;
})();
