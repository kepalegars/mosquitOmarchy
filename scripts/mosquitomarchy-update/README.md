# Module `mosquitomarchy-update` — update watchdog

Installs a **post-boot hook** (`omarchy hook` event, script in
`~/.config/omarchy/hooks/post-boot.d/zzz-mosquitomarchy-update-check`).

At each desktop start it checks, **in priority order**:

1. **mosquitOmarchy GitHub repo**: is there a newer version than the
   local checkout (`git -C ~/mosquitOmarchy ls-remote origin
   refs/heads/master`, 15 s timeout)? If yes → notification, and the
   "update zone" rules apply (see `setup-customarchy.sh --help` / README):
   - **Owner** → update the repo as fast as possible (commit + push).
   - **Users** → self-update **in an emergency** via
     `./setup-customarchy.sh --update-repo`.
   - **Recommended** → wait for the owner's update instead of pulling yourself.
2. Otherwise — **pending Omarchy-related updates** (`pacman -Qu` on the
   synced databases — no network at boot; a weekly best-effort refresh via
   `fakeroot pacman -Syu --print` keeps the databases fresh without a
   password). If any are pending, a **persistent notification** is shown —
   repeated at every boot until the update is actually installed with
   `omarchy update`.

The Omarchy-update notification action **"Review with opencode"** opens a
terminal running `opencode` with a pre-written review prompt:

- **Simple conflicts** (paths/keys renamed, broken references in our blocks)
  → the review proposes the fixes for the corresponding
  `mosquitOmarchy` scripts.
- **Deep conflicts** (duplicated functions such as battery stay-awake /
  mega-caffeine, bar or idle overhaul) → the review proposes adjustments
  but does **not** integrate them before a discussion.

## Install / remove

```bash
./setup-mosquitomarchy-update.sh -y       # install the hook
./setup-customarchy.sh                # offered as module "mosquitomarchy-update"
./setup-customarchy.sh --uninstall    # per-module uninstall (or --uninstall mosquitomarchy-update)
```

## State / debug

- `~/.local/state/omarchy-update-check/scripts-update.txt` — scripts-repo
  update message (only present when task 1 fired)
- `~/.local/state/omarchy-update-check/pending.txt` — pacman -Qu output
- `~/.local/state/omarchy-update-check/relevant.txt` — the Omarchy-related subset
- `~/.local/state/omarchy-update-check/review.txt` — the opencode review prompt
- `~/.local/state/omarchy-update-check/last-refresh` — last DB refresh date

Test the hook manually:

```bash
bash ~/.config/omarchy/hooks/post-boot.d/zzz-mosquitomarchy-update-check
```