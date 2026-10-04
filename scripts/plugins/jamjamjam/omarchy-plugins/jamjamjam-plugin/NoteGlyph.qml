// NoteGlyph.qml — the jamjamjam ♪, drawn.
//
// One component, two call sites (the bar widget and the panel's pin button).
// It was a Canvas inline in the bar widget and a "♪" FONT GLYPH in the panel,
// which meant the two marks were not the same drawing at all: the glyph came
// from whatever font the panel resolved and inherited its weight and slant from
// there. Sharing the drawing is the only way they stay the same mark.
//
// Fills, not strokes, because at bar size a stroke is one or two pixels wide:
// its joins either vanish (leaving three disconnected marks) or bloom (leaving
// a lump). A fill has no width to lose.
import QtQuick
import qs.Commons   // Color.urgent — the theme's `red` key

Item {
    id: root

    // Color.urgent is the theme's `red` key (Color.qml maps red -> urgent), so
    // this is the theme's red rather than a hardcoded one — a different theme
    // restyles the mark instead of leaving a foreign colour on the bar.
    property color color: Color.urgent

    implicitWidth: 18
    implicitHeight: 18

    // On the ROOT, not on the Canvas: `color` is declared here, and a handler
    // named after a property that belongs to a DIFFERENT object silently does
    // not resolve. The glyph would then have kept whatever colour it was first
    // painted with and ignored every later theme change.
    onColorChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent

        // Repainted on size change AND on colour change: the path is built from
        // fractions of the slot, so a new size is a new drawing, and Canvas does
        // not re-run onPaint for a bound property it merely reads.
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            const unit = Math.min(width, height);
            if (unit <= 0)
                return ;

            ctx.fillStyle = root.color;

            // Centred on its own extent rather than trusted to be symmetric:
            // `unit` is the smaller of the two dimensions, and the glyph is not
            // centred on the origin, so a fixed offset drifts as the slot
            // changes shape.
            const boxMinX = -0.153, boxMaxX = 0.38;
            const boxMinY = -0.68, boxMaxY = 0.135;
            ctx.translate(unit * (0.5 - (boxMinX + boxMaxX) / 2),
                         unit * (0.5 - (boxMinY + boxMaxY) / 2));
            ctx.scale(unit, unit);

            // Head: an ellipse laid over on its side and tilted, which is what
            // makes a notehead read as a notehead instead of a bead.
            ctx.save();
            ctx.rotate(-0.20);
            ctx.scale(0.155, 0.105);
            ctx.arc(0, 0, 1, 0, Math.PI * 2);
            ctx.restore();
            ctx.fill();

            // Stem: thin. A stem as wide as a third of the head is what made an
            // earlier version look like a bead on a stick.
            ctx.fillRect(0.095, -0.66, 0.06, 0.68);

            // Flag: one closed hook off the top of the stem — outer edge out to
            // the right and down, then back along the inner edge to the stem, so
            // it is a single silhouette with no seam at the join.
            ctx.beginPath();
            ctx.moveTo(0.095, -0.66);
            ctx.bezierCurveTo(0.34, -0.61, 0.37, -0.45, 0.29, -0.33);
            ctx.lineTo(0.145, -0.43);
            ctx.bezierCurveTo(0.27, -0.55, 0.135, -0.59, 0.095, -0.605);
            ctx.closePath();
            ctx.fill();
        }

        // A Canvas paints nothing until it is told to.
        Component.onCompleted: requestPaint()
    }
}