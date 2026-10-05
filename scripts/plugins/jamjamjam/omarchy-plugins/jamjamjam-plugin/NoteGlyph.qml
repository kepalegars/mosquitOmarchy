// NoteGlyph.qml — the jamjamjam ♪.
//
// One component, two call sites (the bar widget and the panel's pin button), so
// the two marks are the same mark. It was a Canvas inline in the bar widget and
// a "♪" font glyph in the panel, which meant the two were not the same mark at
// all: the glyph came from whatever font the panel resolved and took its weight
// and slant from there.
//
// Back to the FONT GLYPH — the red ♪ it used to be — with a black outline behind
// it. The outline is what lets the backing disc go away: the bar has no
// background of its own, so the mark sits on the wallpaper, and a bare red note
// against a red patch is close to invisible. Measured on representative red
// swatches (not the real wallpaper, which is not on this machine to sample):
// the red note alone is 1.97:1 on a wallpaper-ish red, and the black edge takes
// it to 2.73:1; on a dark background it is the red that carries it, at 4.24:1.
// The disc was the earlier answer to the same problem — a grey slab behind the
// mark — and it did work, but it is heavier than an edge and it is not what the
// mark looked like before it.
//
// A Text is also what this should have been for a second reason: it needs no GPU.
// The Canvas version drew NOTHING under a software scene graph, so an offscreen
// render of this file came out as empty rectangles — invisible in a test harness
// and in anything else without hardware acceleration.
import QtQuick
import qs.Commons   // Color.urgent — the theme's `red` key

Item {
    id: root

    // Color.urgent is the theme's `red` key (Color.qml maps red -> urgent), so
    // this is the theme's red rather than a hardcoded one — a different theme
    // restyles the mark instead of leaving a foreign colour on the bar.
    property color color: Color.urgent

    // The outline. Black and opaque, and deliberately NOT a tint of the note's
    // own colour: a tint of red over a red background is the exact case this
    // exists to fix.
    property color outlineColor: "#000000"

    // Outline thickness in pixels. OFF (0), which is the better-looking mark.
    //
    // It was tried both ways against a real render and lost: at 1px a 20px note
    // wears a black border two pixels wide and reads as a sticker; at 0.5px the
    // eight copies still leave a grey halo around the red and muddy it. The plain
    // red note is what the mark looked like before any of this, and it is what
    // it looks like now.
    //
    // Kept as a property because the reason it existed is real: the bar is
    // transparent over the wallpaper, and a red note on a red wallpaper is close
    // to invisible. On THIS theme's dark bar that is moot — the red measures
    // 4.24:1 against it — but a light or red-tinted bar would want it back, and
    // raising this to 0.5 is the whole fix.
    property real outline: 0

    // The ink of ♪ is ~0.7 of its em box and sits low in it. Filling the slot
    // completely (1.45) made the note taller than the workspace numbers beside it
    // and it read as too big in the bar; 1.1 fills most of the 20px slot and sits
    // at the same weight as the icons next to it.
    property real pixelScale: 1.1

    implicitWidth: 18
    implicitHeight: 18

    // NO font family is named, on purpose. The panel's ♪ used to come from
    // whatever font the panel resolved, and that is the mark being restored here.
    //
    // Naming one instead was tried and rejected: `font.families: [...]` does not
    // even load on this Qt build (the whole QML document fails to instantiate,
    // silently, with no error), and the singular `font.family` that does work
    // changes the shape — Liberation Sans draws a slender note where the
    // resolved font draws a solid, rounder one. The cost of not naming a family
    // is that a theme whose font lacks U+266A would show a tofu box; every font
    // that has ever actually resolved here carries the glyph.
    //
    // `font.family` (singular) with a comma-separated fallback list IS available
    // if the mark ever has to be pinned to a specific face.

    // The glyph box, inset so the outline is never clipped: without this the outer
    // copies get cut and the outline reads as a smudge on one side only.
    Item {
        id: box
        anchors.fill: parent
        anchors.margins: root.outline + 1

        // The eight compass points, listed rather than derived from an index:
        // arithmetic on `index` is where the "which one is the centre" special case
        // comes from, and a visible hole in the outline is the failure mode.
        Repeater {
            // Empty when the outline is off, rather than eight copies stacked on
            // the same pixel behind an opaque note: dead nodes that render nothing
            // are still eight Text objects measured and laid out on every frame.
            model: root.outline > 0 ? [
                { dx: -1, dy: 0 }, { dx: 1, dy: 0 },
                { dx: 0, dy: -1 }, { dx: 0, dy: 1 },
                { dx: -1, dy: -1 }, { dx: 1, dy: -1 },
                { dx: -1, dy: 1 }, { dx: 1, dy: 1 }
            ] : []
            Text {
                required property var modelData
                font.pixelSize: Math.round(box.height * root.pixelScale)
                text: "♪"
                renderType: Text.QtRendering
                color: root.outlineColor
                x: (box.width - width) / 2 + modelData.dx * root.outline
                y: (box.height - height) / 2 + modelData.dy * root.outline
            }
        }

        // The note itself, last, on top of its own outline.
        Text {
            font.pixelSize: Math.round(box.height * root.pixelScale)
            text: "♪"
            renderType: Text.QtRendering
            color: root.color
            x: (box.width - width) / 2
            y: (box.height - height) / 2
        }
    }
}