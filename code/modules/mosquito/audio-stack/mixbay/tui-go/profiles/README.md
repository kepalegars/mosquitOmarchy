# Embedded bootstrap profiles

`cards/*.json` are build-time snapshots of the five cards Mixbay ships, taken
from the **mosquito mixbay profiles** repo. Mixbay must start offline, so it
embeds them; the repo stays the source of truth.

On first read, they are copied into `~/.config/mosquitomixbay/cards/<id>/` as
normal cards. From then on they are uninstallable and updatable like any
downloaded profile; a `.removed` marker keeps an uninstalled snapshot from
being seeded back. Keeping the embedded copy only avoids a blank app on a
fresh, offline machine.

When a shipped card changes upstream, copy it over and rebuild (note the RME
cards live under `cards/rme/` in the repo):

```bash
cp <profiles-repo>/cards/{evo8,evo4,ugm192,ssl12}/card.json \
   code/modules/mosquito/audio-stack/mixbay/tui-go/profiles/cards/
cp <profiles-repo>/cards/rme/fireface-ucx2/card.json \
   code/modules/mosquito/audio-stack/mixbay/tui-go/profiles/cards/
make -C code/modules/mosquito/audio-stack/mixbay/tui-go test
```

Only the five shipped cards belong here. Other community cards are downloaded
into the store and never embedded.
