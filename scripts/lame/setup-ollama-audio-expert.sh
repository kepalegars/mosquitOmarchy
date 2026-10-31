#!/usr/bin/env bash
#
# Ollama + OpenCode setup for REAPER/audio workflow
# Run on a fresh Omarchy install (needs sudo for Ollama install + systemd)
#
# Usage:
#   sudo bash setup-ollama-audio-expert.sh
#
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${B}[INFO]${NC}  $*"; }
ok()    { echo -e "${G}[ OK ]${NC}  $*"; }
warn()  { echo -e "${Y}[WARN]${NC}  $*"; }
fail()  { echo -e "${R}[FAIL]${NC}  $*"; exit 1; }

# ── Detect real user (not root) ──────────────────────────────────
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER")

info "Setting up for user: $REAL_USER ($REAL_HOME)"

# ── 1. Install Ollama ───────────────────────────────────────────
if command -v ollama &>/dev/null; then
    ok "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown version')"
else
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama installed"
fi

# ── 2. Enable + start the service ───────────────────────────────
info "Enabling Ollama service..."
systemctl enable ollama 2>/dev/null || true
systemctl start ollama 2>/dev/null || true
sleep 2

# Wait for Ollama API to be ready
info "Waiting for Ollama API..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:11434/api/version &>/dev/null; then
        ok "Ollama API ready"
        break
    fi
    [ "$i" -eq 30 ] && fail "Ollama API did not start in time"
    sleep 1
done

# ── 3. Create modelfiles directory ──────────────────────────────
info "Creating modelfiles directory..."
mkdir -p "$REAL_HOME/.ollama/modelfiles"
ok "Done"

# ── 4. Create REAPER Audio Expert Modelfile ─────────────────────
info "Creating REAPER Audio Expert modelfile..."
cat > "$REAL_HOME/.ollama/modelfiles/reaper-audio-expert" << 'MODELFROM'
FROM qwen3:14b

PARAMETER num_ctx 16384
PARAMETER temperature 0.6
PARAMETER top_p 0.95
PARAMETER top_k 20

SYSTEM """You are an expert in audio engineering, music production, and REAPER DAW scripting. Your knowledge covers:

**REAPER DAW:**
- ReaScript API (Lua, EEL2, Python) - all 2,282+ functions
- JSFX programming (audio effects, MIDI effects)
- ReaPack, SWS extensions, OSARA
- Project management, routing, FX chains
- Action list, custom actions, toolbars
- Track/item/take manipulation
- Envelopes, automation, MIDI editing
- Rendering, batch processing
- Theme/skin customization

**Audio Engineering:**
- Signal processing: EQ (parametric, graphic, shelving, pass filters), compression (feed-forward, feedback, multiband, parallel), limiting, gating, expansion
- Digital audio fundamentals: sample rates, bit depth, dithering, aliasing, Nyquist theorem
- Mixing: gain staging, panning, stereo imaging, frequency masking, phase coherence
- Mastering: loudness standards (LUFS, RMS, peak), stereo correction, limiting, dithering
- Effects: reverb (algorithmic, convolution, plate, room, hall), delay (tape, digital, ping-pong), chorus, flanger, phaser, tremolo, vibrato, saturation, distortion
- Dynamics: attack/release times, ratio, knee, makeup gain, sidechain routing
- Spatial audio: binaural, ambisonics, object-based (Atmos)
- Recording: microphone techniques, impedance matching, phantom power, gain staging

**Music Theory & Production:**
- Harmonic analysis, chord progressions, modes, scales
- Arrangement, song structure, genre conventions
- Sound design: synthesis (subtractive, FM, wavetable, granular, physical modeling)
- Sampling: time-stretching, pitch-shifting, slicing, layering
- MIDI: note events, CC, pitch bend, program change, SysEx

**DSP Concepts:**
- Fourier analysis, FFT, windowing functions
- Filter design: Butterworth, Chebyshev, elliptic, FIR, IIR
- Delay lines, all-pass filters, comb filters
- Waveshaping, oversampling, anti-aliasing
- Latency compensation, plugin delay

When writing REAPER Lua scripts, always use the correct ReaScript API functions. Provide working, tested code. Explain audio concepts clearly and accurately. When discussing plugins, focus on signal flow and DSP principles rather than specific plugin brands unless asked."""
MODELFROM
chown "$REAL_UID:$REAL_UID" "$REAL_HOME/.ollama/modelfiles/reaper-audio-expert"
ok "Modelfile created"

# ── 5. Create shell helper scripts ──────────────────────────────
info "Creating helper scripts..."
mkdir -p "$REAL_HOME/.local/bin"

cat > "$REAL_HOME/.local/bin/ollama-load-small" << 'SCRIPT'
#!/bin/bash
MODEL="qwen2.5-coder:7b"
KEEP=180
echo "Loading $MODEL (auto-unloads after 3 min)..."
curl -sf http://localhost:11434/api/generate \
  -d "{\"model\":\"$MODEL\",\"keep_alive\":$KEEP,\"prompt\":\"\",\"stream\":false}" \
  | python3 -c "import sys,json; print('Ready:', json.load(sys.stdin)['model'])" 2>/dev/null \
  || echo "Error: is Ollama running?"
SCRIPT

cat > "$REAL_HOME/.local/bin/ollama-load-big" << 'SCRIPT'
#!/bin/bash
MODEL="reaper-audio-expert"
echo "Loading $MODEL (auto-unloads after 5 min)..."
curl -sf http://localhost:11434/api/generate \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"\",\"stream\":false}" \
  | python3 -c "import sys,json; print('Ready:', json.load(sys.stdin)['model'])" 2>/dev/null \
  || echo "Error: is Ollama running?"
SCRIPT

cat > "$REAL_HOME/.local/bin/ollama-unload" << 'SCRIPT'
#!/bin/bash
MODELS=$(curl -sf http://localhost:11434/api/ps | python3 -c "
import sys,json
models = json.load(sys.stdin).get('models',[])
if not models:
    print('NONE')
else:
    for m in models:
        print(m['name'])
" 2>/dev/null)

if [ "$MODELS" = "NONE" ] || [ -z "$MODELS" ]; then
    echo "No models loaded."
    exit 0
fi

echo "$MODELS" | while read -r m; do
    [ -z "$m" ] && continue
    curl -sf http://localhost:11434/api/generate \
      -d "{\"model\":\"$m\",\"keep_alive\":0,\"prompt\":\"\",\"stream\":false}" > /dev/null 2>&1
    echo "Unloaded: $m"
done

echo "RAM freed."
free -h | head -2
SCRIPT

cat > "$REAL_HOME/.local/bin/ollama-status" << 'SCRIPT'
#!/bin/bash
echo "=== Loaded Models ==="
curl -sf http://localhost:11434/api/ps | python3 -c "
import sys,json
models = json.load(sys.stdin).get('models',[])
if not models:
    print('  (none)')
else:
    for m in models:
        print(f'  {m[\"name\"]}  ({m[\"size\"]/1e9:.1f} GB)')
" 2>/dev/null || echo "  Ollama not running"
echo ""
echo "=== RAM ==="
free -h | head -2
SCRIPT

chmod +x "$REAL_HOME/.local/bin"/ollama-{load-small,load-big,unload,status}
chown "$REAL_UID:$REAL_UID" "$REAL_HOME/.local/bin"/ollama-*
ok "Helper scripts created in ~/.local/bin/"

# ── 6. Add ~/.local/bin to PATH if needed ──────────────────────
PROFILE="$REAL_HOME/.bashrc"
if ! grep -q 'LOCAL/bin' "$PROFILE" 2>/dev/null; then
    info "Adding ~/.local/bin to PATH in $PROFILE..."
    echo '' >> "$PROFILE"
    echo '# Ollama helper scripts' >> "$PROFILE"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$PROFILE"
    ok "PATH updated (restart shell or run: source ~/.bashrc)"
fi

# ── 7. OpenCode config ──────────────────────────────────────────
info "Configuring OpenCode..."
mkdir -p "$REAL_HOME/.config/opencode/commands"
cat > "$REAL_HOME/.config/opencode/opencode.json" << 'OCJSON'
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": {
        "reaper-audio-expert": {
          "name": "REAPER Audio Expert (14B)"
        },
        "qwen2.5-coder:7b": {
          "name": "Qwen Coder 7B (fast)"
        },
        "qwen3:14b": {
          "name": "Qwen3 14B"
        }
      }
    }
  }
}
OCJSON
chown "$REAL_UID:$REAL_UID" "$REAL_HOME/.config/opencode/opencode.json"
ok "OpenCode config written"

# ── 8. OpenCode commands ────────────────────────────────────────
info "Creating OpenCode commands..."

cat > "$REAL_HOME/.config/opencode/commands/load-small.md" << 'CMD'
---
description: Load the small fast coding model (3 min auto-unload)
---
!`~/.local/bin/ollama-load-small`
Model loaded. It will auto-unload after 3 minutes of inactivity.
CMD

cat > "$REAL_HOME/.config/opencode/commands/load-big.md" << 'CMD'
---
description: Load the big REAPER/audio expert model (5 min auto-unload)
---
!`~/.local/bin/ollama-load-big`
Model loaded. It will auto-unload after 5 minutes of inactivity.
CMD

cat > "$REAL_HOME/.config/opencode/commands/free.md" << 'CMD'
---
description: Unload all models and free RAM
---
!`~/.local/bin/ollama-unload`
All models unloaded, RAM freed.
CMD

cat > "$REAL_HOME/.config/opencode/commands/ollama.md" << 'CMD'
---
description: Show loaded models and RAM usage
---
!`~/.local/bin/ollama-status`
CMD

chown "$REAL_UID:$REAL_UID" "$REAL_HOME/.config/opencode/commands/"*
ok "OpenCode commands created (/load-small, /load-big, /free, /ollama)"

# ── 9. Pull models ──────────────────────────────────────────────
echo ""
echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${Y}  Downloading models (this takes a while on first run)${NC}"
echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

info "Pulling qwen2.5-coder:7b (~4.7 GB)..."
if sudo -u "$REAL_USER" ollama pull qwen2.5-coder:7b; then
    ok "qwen2.5-coder:7b ready"
else
    warn "Failed to pull qwen2.5-coder:7b — you can retry later with: ollama pull qwen2.5-coder:7b"
fi

info "Pulling qwen3:14b (~9.3 GB)..."
if sudo -u "$REAL_USER" ollama pull qwen3:14b; then
    ok "qwen3:14b ready"
else
    warn "Failed to pull qwen3:14b — you can retry later with: ollama pull qwen3:14b"
fi

# ── 10. Create custom model ─────────────────────────────────────
info "Creating reaper-audio-expert model..."
if sudo -u "$REAL_USER" ollama create reaper-audio-expert -f "$REAL_HOME/.ollama/modelfiles/reaper-audio-expert"; then
    ok "reaper-audio-expert ready"
else
    warn "Failed to create model — retry with: ollama create reaper-audio-expert -f ~/.ollama/modelfiles/reaper-audio-expert"
fi

# ── 11. Verify ──────────────────────────────────────────────────
echo ""
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${G}  Setup complete!${NC}"
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
info "Installed models:"
sudo -u "$REAL_USER" ollama list 2>/dev/null || true
echo ""
echo -e "${B}Quick start:${NC}"
echo "  opencode                          # Launch OpenCode"
echo "  /models                           # Switch models inside OpenCode"
echo "  /load-small                       # Load fast model (3 min TTL)"
echo "  /load-big                         # Load REAPER expert (5 min TTL)"
echo "  /free                             # Unload all, free RAM"
echo "  /ollama                           # Check what's loaded"
echo ""
echo -e "${B}Terminal (outside OpenCode):${NC}"
echo "  ollama-load-small                 # Load fast model"
echo "  ollama-load-big                   # Load REAPER expert"
echo "  ollama-unload                     # Free RAM"
echo "  ollama-status                     # Check status"
echo "  ollama run reaper-audio-expert    # Chat directly"
echo ""
echo -e "${B}Battery tip:${NC} Models auto-unload after idle. To disable"
echo "  Ollama on boot: sudo systemctl disable ollama"
echo ""
