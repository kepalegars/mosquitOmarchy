---
name: mosquitomarchy-crash
description: >
  Diagnose a failure in a mosquitOmarchy script from its crash log, and propose
  a fix. Use when a "mosquitOmarchy: <tool> failed" desktop notification is
  acted on, when pointed at a log under .local/crash-logs/, or when asked why a
  mosquitOmarchy module (setup, update, backup, VM, battery, TUI, ...) failed.
  Triggers: mosquitOmarchy, mosquitomarchy, crash log, "finished with errors",
  customarchy, mosquitomarchy-setup, .local/crash-logs. The agent only PROPOSES;
  it never applies a change without the user confirming.
---

# Diagnosing a mosquitOmarchy crash

You are given **one** crash log: a dated transcript of a single mosquitOmarchy
run that ended in an error. Work from evidence, not from a plausible story.

The repository is the mosquitOmarchy checkout (the log's `# cmd:` line and the
log path both point inside it; `<repo>/.local/crash-logs/` is where logs live).
Everything is plain shell (`scripts/`, `mosquitomarchy-setup.sh`) plus one Go TUI
(`scripts/apps/mosquitomarchy/tui-go/`).

## 1. Read the log first

- `# tool:`, `# date:`, `# cmd:` — what ran, when, and how it was invoked.
- The body is the real terminal output: the `==>` / `✓` / `!` / `✗` lines are
  the shared `msg`/`ok`/`warn`/`err` helpers in `scripts/lib/common.bash`.
- For a generic (trap-generated) log, the body is just `exit status`,
  `failed command` and `at line` — use those to locate the script.

## 2. Locate the failing script

- A named tool maps to `scripts/<area>/...` or a `setup-<name>.sh` module.
  `/usr/bin/env bash` scripts source `scripts/lib/common.bash` (helpers) and,
  for the launcher, `scripts/apps/mosquitomarchy/mosquitomarchy-actions`.
- The TUI streams the backend through `tui-go/actions.go`; its error detection
  lives in `screens.go` (`outputHasError`, the "finished with errors" prompt).

## 3. Establish the cause

- Reproduce read-only where you can (`bash -n`, `--help`, a dry status query).
- Check the environment the log shows: `pkexec`/polkit, missing packages,
  network, an empty selection, a stale state file, a permissions issue.
- Distinguish what the log **proves** from what you are **inferring**. If the
  cause is genuinely ambiguous, say so.

## 4. Report and propose — do not apply

1. What failed, in one or two sentences.
2. The most likely mechanism, separating evidence from inference.
3. A concrete fix: an exact diff (`scripts/...` + line context) or exact
   commands. Keep it minimal and idiomatic to the surrounding script.
4. Any follow-up the user should confirm (a `bash -n`, a re-run, a deploy).

**Leave the system as you found it.** You are diagnosing: do not edit files,
install packages, or reconfigure anything. Present the proposed change and wait
for the user to say go.
