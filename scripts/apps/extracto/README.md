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
- **unrar** backs RAR. With both installed, file-roller's own **Extract Here**
  prompts for the password itself and hands it to the right backend.
- **Makes sure file-roller is *not* the default application** for archive types.
  Earlier revisions ran `xdg-mime default org.gnome.FileRoller.desktop` per
  MIME type, which was self-defeating: `xdg-mime default` writes a *single* app,
  not a list, so it **replaced** the candidate list instead of adding to it. The
  system list in `mimeinfo.cache` is
  `application/zip=org.gnome.FileRoller.desktop;org.gnome.Nautilus.desktop;` —
  Nautilus was a co-candidate and the override dropped it. Extraction in
  Nautilus does not need a MIME default anyway; it goes through file-roller's
  `libnautilus-extension`. This step now only **removes** those old bindings, so
  a machine that ran a previous version is repaired rather than left pinned.
- **Hides file-roller's own package .desktop** so the apps menu is not
  cluttered with a second archive entry — and creates no entry of our own.
  The override is a **full copy of the package file plus `NoDisplay=true`**,
  not a bare `Hidden` stub: a user `.desktop` of the same name *replaces* the
  package one (it does not merge), so a stub would drop its `Exec`/`MimeType`
  and then Nautilus' "Open With → File Roller" would resolve to a file with no
  `Exec` and do nothing. `NoDisplay` still hides it from the
  Omarchy menu (which skips both `Hidden` and `NoDisplay`) while keeping the
  entry launchable.
- Adds a per-class Hyprland rule: file-roller is a floating GTK4 dialog, so it
  is floated + centered and exempted from the default window opacity.

Nothing is written to `~/.local/share/nautilus/scripts/` and no desktop entry
is created: packages plus a few config edits, that is the whole module.

## Password-protected archives

- **Right-click the archive → Extract Here** and enter the password when
  file-roller asks. RAR goes through unrar, zip-AES / 7z / ISO through 7z.
- Extract Here goes through the Nautilus extension, so no MIME association is
  involved and file-roller is never forced as the system handler.

## Usage

```bash
scripts/apps/extracto/setup-extracto.sh            # interactive
scripts/apps/extracto/setup-extracto.sh -y         # non-interactive
scripts/apps/extracto/setup-extracto.sh --status   # current state, changes nothing
scripts/apps/extracto/setup-extracto.sh --remove   # remove our glue (keeps packages)
```

Idempotent: may be re-run without risk.
