# Embedded native profiles

`cards/*.json` are build-time snapshots of the five native cards from the
**mosquito mixbay profiles** repo. Mixbay must start offline, so it embeds them;
the repo stays the source of truth.

When a native card changes upstream, copy it over and rebuild:

```bash
cp <profiles-repo>/cards/{evo8,evo4,ugm192,fireface-ucx2,ssl12}/card.json \
   code/modules/mosquito/audio-stack/mixbay/tui-go/profiles/cards/
make -C code/modules/mosquito/audio-stack/mixbay/tui-go test
```

Only the native five belong here. Community cards are downloaded into
`~/.config/mosquitomixbay/cards/<id>/` and are never embedded.
