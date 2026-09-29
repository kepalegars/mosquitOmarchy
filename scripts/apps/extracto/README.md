# extracto — a simple custom install script for file-roller

Seamless archive handling in Nautilus, which no longer has any by itself.

## What it is

A **simple custom install script for file-roller**. It is not an app and it
adds **no desktop entry** — the point is that Nautilus itself regains its
archive actions, exactly as they were before Nautilus dropped built-in support.

## The gap it fills

- Nautilus dropped built-in archive support (GNOME 45+). On this machine that
  left **no graphical archive tool at all**: no "Extract Here" in the context
  menu, double-clicking a `.zip`/`.tar.zst` did nothing, and a **password-
  protected archive could not be opened graphically**. Only the `7z`/`bsdtar`
  CLIs were present.
- This is not a broken feature, it was a **missing** one: no file in the stack
  mentioned archives.

## What it does

`setup-extracto.sh` installs **file-roller** + **7zip** + **unrar**:

- file-roller links `libnautilus-extension` and ships the Nautilus C extension,
  so Nautilus regains **Extract Here** / **Create Archive** and per-archive
  actions (list, test, open without extracting, delete inside an archive).
- **7zip** backs the password-protected and exotic formats (zip AES, 7z, ISO,
  lha, lrzip) that libarchive alone refuses.
- **unrar** is the only backend that reliably applies a RAR password —
  libarchive (which file-roller uses for RAR) does not prompt and silently
  does nothing, so file-roller's "Extract Here" fails on encrypted RAR.
- Sets the common formats to open **with file-roller** (mimeapps.default), so
  double-clicking an archive really opens it.
- **Hides file-roller's own package .desktop** so the apps menu is not
  cluttered with a second archive entry — and creates no entry of our own.
  The override is a **full copy of the package file plus `NoDisplay=true`**,
  not a bare `Hidden` stub: a user `.desktop` of the same name *replaces* the
  package one (it does not merge), so a stub would drop its `Exec`/`MimeType`
  and then Nautilus' "Open With → File Roller" — and a double-click on any
  archive, since `mimeapps.list` still points at that id — would resolve to a
  file with no `Exec` and do nothing. `NoDisplay` still hides it from the
  Omarchy menu (which skips both `Hidden` and `NoDisplay`) while keeping the
  entry launchable.
- Installs a **Nautilus script**, `Extract with password`
  (`~/.local/share/nautilus/scripts/`), which prompts for the password and
  extracts with the backend that applies it. This is the fix for
  password-protected RAR (and any archive file-roller cannot decrypt). It
  appears in Nautilus' right-click → **Scripts** menu; it is not a desktop entry.
- Adds a per-class Hyprland rule: file-roller is a floating GTK4 dialog, so it
  is floated + centered and exempted from the default window opacity.

## Password-protected archives

- **Right-click the archive → Scripts → Extract with password**, enter the
  password. RAR is handled by unrar, everything else by 7z — both apply the
  password.
- file-roller's own **Extract Here** still covers unencrypted archives.

## Usage

```bash
./setup-extracto.sh            # interactive
./setup-extracto.sh -y         # non-interactive
./setup-extracto.sh --status   # current state, changes nothing
./setup-extracto.sh --remove   # remove our glue (keeps packages)
```

Idempotent: may be re-run without risk.
