import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string moduleName: "jamjamjam-plugin"

  property var snapshot: ({
    type: "snapshot",
    recording: false,
    recorderError: "",
    inputSource: "pc",
    paused: false,
    tuiActive: false,
    needsReset: false,
    mic: { available: true, muted: false },
    config: { noteNaming: "flats" },
    analyzer: { key: "", keyConfidence: 0, bpm: 0, currentChord: "", chordNotes: [], noSignal: true, progression: [] },
    midi: { mode: false, state: "off", message: "", ports: [], selectedPort: "", connected: false, currentChord: "", heldNotes: [], deviceCount: 0 },
    synth: { enabled: true, waveform: "sine", volume: 0.4, running: false, error: "" },
    guitar: { root: -1, scaleType: "", strings: [], degrees: {} },
    noteNaming: "flats"
  })
  property string processError: ""
  property string commandError: ""
  property int requestCounter: 0
  property bool expectedStop: false
  property bool backendReady: false

  readonly property bool recording: snapshot.recording === true
  readonly property string captureTarget: String(snapshot.captureTarget || "")
  readonly property string inputSource: String(snapshot.inputSource || "pc")
  readonly property bool paused: snapshot.paused === true
  readonly property bool tuiActive: snapshot.tuiActive === true
  readonly property bool needsReset: snapshot.needsReset === true
  readonly property var mic: snapshot.mic || ({ available: true, muted: false })
  readonly property var config: snapshot.config || ({ noteNaming: "flats" })
  readonly property bool panelVisible: snapshot.visible === true
  readonly property bool hold: snapshot.hold === true
  readonly property var metronome: snapshot.metronome || ({ enabled: false, bpm: 120, beats: 4 })
  readonly property var loop: snapshot.loop || ({ active: false, chords: [], pos: 0 })
  readonly property var song: snapshot.song || ({ available: false, match: null, error: "" })
  readonly property var tuner: snapshot.tuner || ({ active: false, freq: 0, note: "", octave: 0, cents: 0 })
  readonly property string key: snapshot.analyzer ? String(snapshot.analyzer.key || "") : ""
  readonly property real keyConfidence: snapshot.analyzer ? Number(snapshot.analyzer.keyConfidence || 0) : 0
  readonly property real bpm: snapshot.analyzer ? Number(snapshot.analyzer.bpm || 0) : 0
  readonly property string currentChord: snapshot.analyzer ? String(snapshot.analyzer.currentChord || "") : ""
  readonly property var progression: snapshot.analyzer && snapshot.analyzer.progression ? snapshot.analyzer.progression : []
  readonly property bool midiMode: snapshot.midi && snapshot.midi.mode === true
  readonly property bool midiConnected: snapshot.midi && snapshot.midi.connected === true
  readonly property string midiChord: snapshot.midi ? String(snapshot.midi.currentChord || "") : ""
  readonly property var midiPorts: snapshot.midi && snapshot.midi.ports ? snapshot.midi.ports : []
  readonly property string synthWaveform: snapshot.synth ? String(snapshot.synth.waveform || "sine") : "sine"
  readonly property real synthVolume: snapshot.synth ? Number(snapshot.synth.volume || 0.4) : 0.4
  readonly property bool synthEnabled: snapshot.synth ? snapshot.synth.enabled === true : true
  readonly property var guitar: snapshot.guitar || ({ strings: [], degrees: {} })
  readonly property string noteNaming: String(snapshot.noteNaming || "flats")
  readonly property string lastError: commandError || processError || (snapshot.recorderError ? String(snapshot.recorderError) : "")

  readonly property string backendPath: localPath(Qt.resolvedUrl("backend/jamjamjam_backend.py"))

  function localPath(url) {
    var text = String(url || "")
    if (text.indexOf("file://") === 0) text = text.substring(7)
    return decodeURIComponent(text)
  }

  function send(op, fields, callback) {
    if (!backend.running) {
      commandError = "jamjamjam backend is not running"
      if (callback) callback(false, { error: commandError })
      return ""
    }
    requestCounter += 1
    var id = String(requestCounter)
    if (callback) pendingCallbacks[id] = callback
    var payload = { id: id, op: op }
    var values = fields || ({})
    for (var key in values) payload[key] = values[key]
    commandError = ""
    backend.write(JSON.stringify(payload) + "\n")
    return id
  }

  function startRecording() { send("startRecording") }
  function stopRecording() { send("stopRecording") }
  function toggleRecording() { send("toggleRecording") }
  function resetAnalysis() { send("resetAnalysis") }
  function setVisible(value) { send("setVisible", { visible: !!value }) }
  function setHold(value) { send("setHold", { active: !!value }) }
  function setSource(value) { send("setSource", { source: value === "mic" ? "mic" : "pc" }) }
  function setMetronome(value) { send("setMetronome", { enabled: !!value }) }
  function setManualKey(key) { send("setManualKey", { key: String(key || "") }) }
  function setManualBpm(bpm) { send("setManualBpm", { bpm: Number(bpm) || 0 }) }
  function setPaused(value) { send("setPaused", { active: !!value }) }
  function togglePaused() { send("togglePaused") }
  function setConfig(noteNaming) {
    var fields = {}
    if (noteNaming === "flats" || noteNaming === "sharps") fields.noteNaming = String(noteNaming)
    send("setConfig", fields)
  }
  function setConfigBool(key, value) {
    // Generic config toggle: showChordBox, aecEnabled…
    var fields = {}
    fields[String(key)] = !!value
    send("setConfig", fields)
  }
  function setMetronomeVolume(value) {
    send("setConfig", { metronomeVolume: Math.max(0, Math.min(1, Number(value))) })
  }
  function setClickStyle(style) { send("setConfig", { clickStyle: String(style || "classic") }) }
  function setClickCustom(enabled) { send("setConfig", { clickCustom: !!enabled }) }
  function importClick(which) { send("importClick", { which: which === "up" ? "up" : "down" }) }
  function openTui() { send("openTui") }
  function resumeAnalysis() { send("resumeAnalysis") }
  function enableMidi(value) { send("enableMidi", { enabled: !!value }) }
  function toggleMidi() { send("toggleMidi") }
  function refreshPorts() { send("refreshPorts") }
  function selectPort(portId) { send("selectPort", { port: String(portId || "") }) }
  function setSynthEnabled(value) { send("setSynthEnabled", { enabled: !!value }) }
  function toggleSynth() { send("setSynthEnabled", { enabled: !synthEnabled }) }
  function setWaveform(waveform) { send("setWaveform", { waveform: String(waveform || "sine") }) }
  function setVolume(value) { send("setVolume", { volume: Math.max(0, Math.min(1, Number(value))) }) }
  function panicMidi() { send("panicMidi") }
  function setNoteNaming(naming) { send("setNoteNaming", { naming: String(naming || "flats") }) }

  function handleLine(line) {
    var text = String(line || "").trim()
    if (!text) return
    var message
    try {
      message = JSON.parse(text)
    } catch (error) {
      processError = "Backend emitted invalid data"
      console.warn("jamjamjam invalid backend output:", text)
      return
    }
    if (message.type === "snapshot") {
      snapshot = message
      backendReady = true
      processError = ""
    } else if (message.type === "result") {
      var id = String(message.id || "")
      var cb = pendingCallbacks[id]
      if (cb) {
        delete pendingCallbacks[id]
        cb(message.ok === true, message.data || {})
      }
      if (message.ok === false) commandError = String(message.error || "jamjamjam command failed")
    }
  }

  Process {
    id: backend
    command: ["python3", root.backendPath]
    stdinEnabled: true

    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    stderr: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        if (text) console.warn("jamjamjam:", text)
      }
    }

    onStarted: {
      root.backendReady = false
      root.processError = ""
    }

    onExited: function(exitCode) {
      if (root.expectedStop) return
      root.backendReady = false
      root.processError = "jamjamjam backend stopped (" + exitCode + ")"
      restartTimer.restart()
    }
  }

  property var pendingCallbacks: ({})

  Timer {
    id: restartTimer
    interval: 3000
    repeat: false
    onTriggered: if (!root.expectedStop && !backend.running) backend.running = true
  }

  IpcHandler {
    target: root.moduleName

    function status(): string { return JSON.stringify(root.snapshot) }
    function record(): string { root.startRecording(); return "ok" }
    function stop(): string { root.stopRecording(); return "ok" }
    function toggleRecording(): string { root.toggleRecording(); return "ok" }
    function reset(): string { root.resetAnalysis(); return "ok" }
    function resumeAnalysis(): string { root.resumeAnalysis(); return "ok" }
    function openTui(): string { root.openTui(); return "ok" }
    function setSource(source: string): string { root.setSource(source); return "ok" }
    function setHold(active: string): string { root.setHold(active === "true" || active === "1"); return "ok" }
    function setMetronome(enabled: string): string { root.setMetronome(enabled === "true" || enabled === "1"); return "ok" }
    function pause(active: string): string { root.setPaused(active === "true" || active === "1"); return "ok" }
    function setVisible(visible: string): string { root.setVisible(visible === "true" || visible === "1"); return "ok" }
    function midi(): string { root.toggleMidi(); return "ok" }
    function refreshPorts(): string { root.refreshPorts(); return "ok" }
    function selectPort(portId: string): string { root.selectPort(portId); return "ok" }
    function waveform(waveform: string): string { root.setWaveform(waveform); return "ok" }
    function volume(value: string): string { root.setVolume(Number(value)); return "ok" }
    function panic(): string { root.panicMidi(); return "ok" }
  }

  Component.onCompleted: backend.running = true
  Component.onDestruction: {
    expectedStop = true
    backend.running = false
  }
}