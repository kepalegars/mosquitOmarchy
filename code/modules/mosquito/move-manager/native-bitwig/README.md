# Native Bitwig route

`AbletonMove.control.js` is Pikub's single-script Move controller, vendored so
the Move Manager can install it without a network round trip.

- Source: https://github.com/PikubLab/move-for-bitwig
- Version: 5.11 (see the header of the script)
- License: MIT (per the upstream repository)

The Move Manager copies it to
`~/Bitwig Studio/Controller Scripts/Ableton Move/AbletonMove.control.js`.
Bitwig loads every `*.control.js` under `Controller Scripts`, so this route and
the Schwung route (under `Ableton/Move/`) must never be installed together;
installing one removes the other.
