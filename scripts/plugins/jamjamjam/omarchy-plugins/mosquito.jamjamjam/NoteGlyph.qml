// NoteGlyph.qml — the jamjamjam mark in the bar and in the panel.
//
// It was a "♪" font glyph, then a Canvas drawing of a note, and it is now the
// TUNING FORK from the Pitchfork plugin (io.github.kemezz.pitchfork), in red.
//
// Not a music note: a tuning fork, because that is the mark the user recognised.
// The fork is drawn rather than borrowed from a font for the same reason
// Pitchfork draws it — a Nerd Font revision may or may not carry a suitable
// glyph, and the drawing is identical at any bar size.
//
// The geometry below is Pitchfork's, unchanged, so the two plugins show the same
// fork and only the colour differs. Every dimension is a fraction of the icon
// slot, which is what makes it scale.
//
// One component, two call sites (the bar widget and the panel's pin button), so
// the two marks are the same mark. It used to be a Canvas inline in the bar
// widget and a font glyph in the panel, which meant the two were not the same
// mark at all.
//
// Red is the theme's red (Color.urgent is the `red` key), not a hardcoded one, so
// a different theme restyles the mark instead of leaving a foreign colour on the
// bar.
import QtQuick
import qs.Commons   // Color.urgent — the theme's `red` key

Item {
    id: root

    property color color: Color.urgent

    implicitWidth: 18
    implicitHeight: 18

    // Pitchfork's drawing, verbatim. `unit` is the smaller side so the fork keeps
    // its proportions in a non-square slot.
    readonly property real unit: Math.min(width, height)
    readonly property real prong: Math.max(1, root.unit * 0.115)
    readonly property real spread: root.unit * 0.175
    // The prongs stop exactly where the bridge starts. Letting them overshoot it
    // reads as a plug rather than a fork.
    readonly property real bridgeTop: root.height / 2 + root.unit * 0.06
    readonly property real crownTop: root.height / 2 - root.unit * 0.4

    Rectangle {
        x: root.width / 2 - root.spread - root.prong / 2
        y: root.crownTop
        width: root.prong
        height: root.bridgeTop + root.prong - root.crownTop
        radius: root.prong / 2
        color: root.color
    }

    Rectangle {
        x: root.width / 2 + root.spread - root.prong / 2
        y: root.crownTop
        width: root.prong
        height: root.bridgeTop + root.prong - root.crownTop
        radius: root.prong / 2
        color: root.color
    }

    // Bridges the prongs into the stem, so the three bars read as one fork
    // instead of three strokes.
    Rectangle {
        x: root.width / 2 - root.spread - root.prong / 2
        y: root.bridgeTop
        width: root.spread * 2 + root.prong
        height: root.prong
        radius: root.prong / 2
        color: root.color
    }

    Rectangle {
        x: root.width / 2 - root.prong / 2
        y: root.bridgeTop
        width: root.prong
        height: root.height / 2 + root.unit * 0.4 - root.bridgeTop
        radius: root.prong / 2
        color: root.color
    }
}