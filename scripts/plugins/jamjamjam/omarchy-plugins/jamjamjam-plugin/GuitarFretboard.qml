import QtQuick
import qs.Commons

// Guitar neck showing the detected key's scale with numbered degrees.
// 1 = root, 2 = 2nd, 3 = 3rd, ... 7 = 7th of the scale.
Item {
  id: root

  property var dots: []
  property var stringsData: []
  property string keyLabel: ""
  property color textColor: Color.popups.text
  property color accentColor: Color.accent
  property color mutedColor: Color.muted
  property color rootColor: Color.urgent
  property int fretCount: 12
  readonly property real stringCount: 6

  function compute() {
    canvas.requestPaint()
  }

  onDotsChanged: compute()
  onStringsDataChanged: compute()
  onKeyLabelChanged: compute()
  width: 320
  height: 140

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    readonly property real stringSpacing: height / 6
    readonly property real fretWidth: width / (fretCount + 1)

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width
      var h = height
      var sp = canvas.stringSpacing
      var fw = canvas.fretWidth
      if (w <= 0 || h <= 0 || sp <= 0 || fw <= 0) return

      // Neck background built from the theme's neutrals.
      var bg = ctx.createLinearGradient(0, 0, 0, h)
      bg.addColorStop(0, Qt.lighter(Color.background, 1.28))
      bg.addColorStop(0.5, Qt.darker(Color.background, 1.12))
      bg.addColorStop(1, Qt.lighter(Color.background, 1.28))
      ctx.fillStyle = bg
      ctx.fillRect(0, 0, w, h)

      // Fret lines (grey)
      ctx.strokeStyle = Util.alpha(Color.muted, 0.55)
      ctx.lineWidth = 1.2
      for (var i = 0; i <= fretCount; i++) {
        var fx = i * fw + fw * 0.5
        ctx.beginPath()
        ctx.moveTo(fx, 1)
        ctx.lineTo(fx, h - 1)
        ctx.stroke()
      }
      // Nut
      ctx.strokeStyle = Util.alpha(Color.foreground, 0.6)
      ctx.lineWidth = 3
      ctx.beginPath()
      ctx.moveTo(fw * 0.5, 1)
      ctx.lineTo(fw * 0.5, h - 1)
      ctx.stroke()

      // Strings (light, horizontal)
      for (var s = 0; s < 6; s++) {
        ctx.strokeStyle = Util.alpha(Color.foreground, 0.7)
        ctx.lineWidth = 0.7 + (5 - s) * 0.17
        var sy = (s + 0.5) * sp
        ctx.beginPath()
        ctx.moveTo(fw * 0.5, sy)
        ctx.lineTo(w, sy)
        ctx.stroke()
      }

      // String labels (low E to high E on the left)
      var stringNames = root.stringsData
      for (var sn = 0; sn < stringNames.length && sn < 6; sn++) {
        ctx.fillStyle = Util.alpha(Color.foreground, 0.5)
        ctx.font = "bold " + Math.round(sp * 0.55) + "px sans-serif"
        ctx.textAlign = "center"
        ctx.textBaseline = "middle"
        var sy2 = (sn + 0.5) * sp
        ctx.fillText(stringNames[sn], fw * 0.28, sy2)
      }

      // Fret markers (grey dots). The 12th fret gets the double-dot octave
      // marker plus an explicit "12" so the octave is unmistakable.
      var markers = [3, 5, 7, 9, 12]
      ctx.fillStyle = Util.alpha(Color.muted, 0.45)
      for (var m = 0; m < markers.length; m++) {
        var dotX = markers[m] * fw + fw * 0.5
        if (markers[m] === 12) {
          ctx.beginPath()
          ctx.arc(dotX, h * 0.30, sp * 0.35, 0, Math.PI * 2)
          ctx.fill()
          ctx.beginPath()
          ctx.arc(dotX, h * 0.80, sp * 0.35, 0, Math.PI * 2)
          ctx.fill()
          ctx.fillStyle = Util.alpha(Color.foreground, 0.85)
          ctx.font = "bold " + Math.round(sp * 0.42) + "px sans-serif"
          ctx.textAlign = "center"
          ctx.textBaseline = "middle"
          ctx.fillText("12", dotX, h * 0.5)
          ctx.fillStyle = Util.alpha(Color.muted, 0.45)
        } else {
          ctx.beginPath()
          ctx.arc(dotX, h * 0.5, sp * 0.35, 0, Math.PI * 2)
          ctx.fill()
        }
      }

      // Degree dots
      for (var d = 0; d < root.dots.length; d++) {
        var dot = root.dots[d]
        if (dot.fret < 0 || dot.fret > fretCount) continue
        var dx = dot.fret * fw + fw * 0.5
        var dy = (dot.string + 0.5) * sp
        var radius = sp * 0.4

        var color = root.rootColor
        if (dot.degree === 3 || dot.degree === 6) {
          color = root.accentColor
        } else if (dot.degree === 5) {
          color = Util.alpha(Color.foreground, 0.9)
        } else if (dot.degree !== 1) {
          color = root.accentColor
        }
        ctx.fillStyle = color
        ctx.beginPath()
        ctx.arc(dx, dy, radius, 0, Math.PI * 2)
        ctx.fill()
        ctx.strokeStyle = Util.alpha(Color.foreground, 0.65)
        ctx.lineWidth = 1
        ctx.stroke()

        // Degree number (lightened from the dot's own color)
        ctx.fillStyle = Qt.lighter(color, 2.6)
        ctx.font = "bold " + Math.round(radius * 1.1) + "px sans-serif"
        ctx.textAlign = "center"
        ctx.textBaseline = "middle"
        ctx.fillText(String(dot.degree), dx, dy + 0.5)
      }
    }
  }
}