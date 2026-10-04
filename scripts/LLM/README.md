# Local AI (Ollama + OpenCode) — Omarchy module

Installs Ollama (systemd service), creates the `reaper-audio-expert` model (based on `qwen3:14b`) for audio/REAPER workflows, helpers (`ollama-load-small/big`, `ollama-unload`, `ollama-status`), configures OpenCode (`/load-small`, `/load-big`, `/free`, `/ollama`). Downloads ~14 GB of models.

> **Where the coding happened.** mosquitOmarchy's own source is written with
> [opencode](https://opencode.ai) driving **BigPickle DeepSeek 4.1 Flash** and **Space Bunny
> Free**. This module is about the opencode *you* run on your machine for your own work —
> a different thing.

## Usage

```bash
sudo bash scripts/LLM/setup-ollama-audio-expert.sh
opencode                        # then /load-big
ollama-unload                   # free RAM
```

Battery tip: `sudo systemctl disable ollama`.