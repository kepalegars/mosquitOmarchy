# Local AI (Ollama + OpenCode) — Omarchy module

Installs Ollama (systemd service), creates the `reaper-audio-expert` model (based on `qwen3:14b`) for audio/REAPER workflows, helpers (`ollama-load-small/big`, `ollama-unload`, `ollama-status`), configures OpenCode (`/load-small`, `/load-big`, `/free`, `/ollama`). Downloads ~14 GB of models.

## Usage

```bash
sudo bash setup-ollama-audio-expert.sh
opencode                        # then /load-big
ollama-unload                   # free RAM
```

Battery tip: `sudo systemctl disable ollama`.