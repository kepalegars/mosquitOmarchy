// CLI actions — the non-interactive backend of mosquitomixbay.
//
// The TUI calls the drivers in-process; this file exposes the same drivers
// to scripts, live-mode and the dispatcher (`mosquito-mixbay-actions`):
//
//	mosquito-mixbay-actions devices-json
//	mosquito-mixbay-actions status-json [--device evo8]
//	mosquito-mixbay-actions set volume -20 [--device evo8] [--pair 0]
//	mosquito-mixbay-actions set gain 25 -t input1
//	mosquito-mixbay-actions set mute 1 -t output / set phantom 1 -t input1
//	mosquito-mixbay-actions set monitor 50
//	mosquito-mixbay-actions mixer input1 --volume -6 --pan 0 [--bus 0]
//	mosquito-mixbay-actions mixer output1_2 --volume 0 [--bus 0]
//	mosquito-mixbay-actions save | load [--device evo8]
//
// Flag vocabulary mirrors evoctl (vanZaho) so muscle memory transfers.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"mosquitomarchy.local/mosquitomixbay-tui/drivers"
	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
)

func defaultDevice() string {
	if v := os.Getenv("mosquitomixbay_device"); v != "" {
		return v
	}
	// Prefer real hardware: EVO 8, then EVO 4, then anything probed.
	for _, id := range []string{drivers.DevEVO8, drivers.DevEVO4} {
		if d, err := drivers.Open(id); err == nil && d.Probe() {
			return id
		}
	}
	for _, spec := range drivers.Registry() {
		if d, err := drivers.Open(spec.ID); err == nil && d.Probe() {
			return spec.ID
		}
	}
	return drivers.DevEVO8
}

func runCLI(args []string) int {
	if len(args) == 0 {
		return -1 // no args → interactive TUI (handled by main.go)
	}
	switch args[0] {
	case "devices-json":
		return cliDevices()
	case "status-json":
		fs := flag.NewFlagSet("status-json", flag.ContinueOnError)
		dev := fs.String("device", defaultDevice(), "device id")
		live := fs.Bool("live", false, "fail when the hardware is offline")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		return cliStatus(*dev, *live)
	case "set":
		return cliSet(args[1:])
	case "mixer":
		return cliMixer(args[1:])
	case "patchbay-status-json":
		return cliPatchbayStatus()
	case "patchbay-save":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: patchbay-save NAME")
			return 2
		}
		return cliPatchbaySave(args[1])
	case "patchbay-apply":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: patchbay-apply NAME [--replace]")
			return 2
		}
		replace := len(args) > 2 && args[2] == "--replace"
		return cliPatchbayApply(args[1], replace)
	case "save", "load":
		fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
		dev := fs.String("device", defaultDevice(), "device id")
		demo := fs.Bool("demo", false, "allow writing the persistent DEMO state when offline")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		d, err := openWrite(*dev, *demo)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		if args[0] == "save" {
			err = d.Save()
		} else {
			err = d.Load()
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Println("ok")
		return 0
	case "-h", "--help", "help":
		fmt.Print(cliHelp())
		return 0
	}
	fmt.Fprintf(os.Stderr, "unknown command %q\n%s", args[0], cliHelp())
	return 2
}

func cliHelp() string {
	return `mosquito-mixbay-actions — non-interactive backend (scripts, live-mode)

  devices-json                        all supported devices + probe state
  status-json [--device ID] [--live]  full state (JSON; --live fails offline)
  set ... [--demo]                    writes are live-only unless --demo
  save | load [--device ID] [--demo]  snapshot / re-apply (strict by default)
  patchbay-status-json                PipeWire links, interfaces and presets
  patchbay-save NAME                  save current hardware links as a preset
  patchbay-apply NAME [--replace]     apply a preset (explicit, no auto)
  set gain DB -t inputN               input gain in dB
  set mute 0|1 -t TARGET              mute (inputN / output[N])
  set phantom 0|1 -t inputN           48V phantom power (EVO)
  set monitor 0..100                  direct-monitor blend (EVO 4 only)
  mixer inputN --volume DB --pan P [--bus 0] [--demo]
  mixer outputX_Y --volume DB [--bus 0]

Devices: evo8 (default) · evo4 · fireface-ucx2 · ugm192 · quantum-es4
`
}

func cliDevices() int {
	type row struct {
		drivers.Spec
		Probed bool `json:"probed"`
	}
	var out []row
	for _, spec := range drivers.Registry() {
		d, err := drivers.Open(spec.ID)
		probed := err == nil && d.Probe()
		out = append(out, row{spec, probed})
	}
	return printJSON(out)
}

func cliStatus(dev string, live bool) int {
	d, err := drivers.Open(dev)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var st drivers.Status
	if live {
		lr, ok := d.(drivers.LiveReader)
		if !ok {
			fmt.Fprintf(os.Stderr, "%s has no live reader\n", dev)
			return 1
		}
		st, err = lr.Read()
	} else {
		st, err = d.Status()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return printJSON(st)
}

func printJSON(v any) int {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(string(data))
	return 0
}

// shared flags: --device + -t target. A flag left without its value is an
// error, never a silent empty string.
func deviceAndTarget(args []string) (string, string, []string, error) {
	dev := defaultDevice()
	target := ""
	var rest []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--device":
			i++
			if i >= len(args) {
				return "", "", nil, fmt.Errorf("--device needs a value")
			}
			dev = args[i]
		case "-t", "--target":
			i++
			if i >= len(args) {
				return "", "", nil, fmt.Errorf("-t needs a value")
			}
			target = args[i]
		default:
			rest = append(rest, args[i])
		}
	}
	return dev, target, rest, nil
}

// openWrite uses the strict driver unless --demo explicitly asks for the
// persistent simulation. A write must never reach DEMO by accident.
func openWrite(dev string, demo bool) (drivers.Driver, error) {
	if demo {
		return drivers.Open(dev)
	}
	return drivers.OpenLive(dev)
}

func takeDemo(args []string) (bool, []string) {
	demo := false
	rest := args[:0]
	for _, a := range args {
		if a == "--demo" {
			demo = true
			continue
		}
		rest = append(rest, a)
	}
	return demo, rest
}

func cliSet(args []string) int {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: set volume|gain|mute|phantom|monitor VALUE [-t TARGET] [--device ID]")
		return 2
	}
	kind := args[0]
	demo, args := takeDemo(args[1:])
	dev, target, rest, err := deviceAndTarget(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	d, err := openWrite(dev, demo)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	val := ""
	if len(rest) > 0 {
		val = rest[0]
	}
	num := func() (float64, bool) {
		f, err := strconv.ParseFloat(val, 64)
		return f, err == nil
	}
	flag01 := func() (bool, bool) {
		switch strings.ToLower(val) {
		case "1", "on", "true", "yes":
			return true, true
		case "0", "off", "false", "no":
			return false, true
		}
		return false, false
	}
	switch kind {
	case "volume":
		f, ok := num()
		if !ok {
			fmt.Fprintln(os.Stderr, "volume needs a dB value")
			return 2
		}
		pair := -1
		for i := 0; i < len(rest)-1; i++ {
			if rest[i] == "--pair" {
				pair, _ = strconv.Atoi(rest[i+1])
			}
		}
		if err := d.SetVolume(pair, f); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	case "gain":
		f, ok := num()
		if !ok || target == "" {
			fmt.Fprintln(os.Stderr, "usage: set gain DB -t inputN")
			return 2
		}
		var n int
		if _, err := fmt.Sscanf(target, "input%d", &n); err != nil {
			fmt.Fprintln(os.Stderr, "target must be inputN")
			return 2
		}
		if err := d.SetGain(n, f); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	case "mute":
		b, ok := flag01()
		if !ok || target == "" {
			fmt.Fprintln(os.Stderr, "usage: set mute 0|1 -t inputN|output[N]")
			return 2
		}
		if err := d.SetMute(target, b); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	case "phantom":
		b, ok := flag01()
		if !ok || target == "" {
			fmt.Fprintln(os.Stderr, "usage: set phantom 0|1 -t inputN")
			return 2
		}
		var n int
		if _, err := fmt.Sscanf(target, "input%d", &n); err != nil {
			fmt.Fprintln(os.Stderr, "target must be inputN")
			return 2
		}
		if err := d.SetPhantom(n, b); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	case "monitor":
		f, ok := num()
		if !ok {
			fmt.Fprintln(os.Stderr, "monitor needs 0..100")
			return 2
		}
		if err := d.SetMonitor(int(f)); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown set target %q\n", kind)
		return 2
	}
	fmt.Println("ok")
	return 0
}

func cliMixer(args []string) int {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: mixer inputN|outputX_Y --volume DB [--pan P] [--bus 0] [--device ID]")
		return 2
	}
	src := args[0]
	dev := defaultDevice()
	demo := false
	vol := -128.0
	pan := 0.0
	bus := 0
	hasVol, hasPan := false, false
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--volume":
			i++
			if i >= len(args) {
				fmt.Fprintln(os.Stderr, "mixer --volume needs a value")
				return 2
			}
			vol, _ = strconv.ParseFloat(args[i], 64)
			hasVol = true
		case "--pan":
			i++
			if i >= len(args) {
				fmt.Fprintln(os.Stderr, "mixer --pan needs a value")
				return 2
			}
			pan, _ = strconv.ParseFloat(args[i], 64)
			hasPan = true
		case "--bus", "--mix-output":
			i++
			if i >= len(args) {
				fmt.Fprintln(os.Stderr, "mixer --bus needs a value")
				return 2
			}
			bus, _ = strconv.Atoi(args[i])
		case "--device":
			i++
			if i >= len(args) {
				fmt.Fprintln(os.Stderr, "mixer --device needs a value")
				return 2
			}
			dev = args[i]
		case "--demo":
			demo = true
		}
	}
	if !hasVol {
		fmt.Fprintln(os.Stderr, "mixer needs --volume DB")
		return 2
	}
	d, err := openWrite(dev, demo)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	// Without an explicit --pan, keep the stored pan (volume-only change).
	if !hasPan {
		if st, err := d.Status(); err == nil {
			if c, ok := st.Mixer[drivers.MixerKey(src, bus)]; ok {
				pan = c.Pan
			}
		}
	}
	var inNum int
	if _, err := fmt.Sscanf(src, "input%d", &inNum); err == nil {
		if err := d.SetMixerInput(inNum, vol, pan, bus); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Println("ok")
		return 0
	}
	var l, r int
	if _, err := fmt.Sscanf(src, "output%d_%d", &l, &r); err == nil && r == l+1 && l%2 == 1 {
		if err := d.SetMixerOutput((l-1)/2, vol, pan, pan, bus); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Println("ok")
		return 0
	}
	fmt.Fprintf(os.Stderr, "unknown mixer source %q (want inputN or outputX_Y)\n", src)
	return 2
}

type patchbayStatus struct {
	Available bool             `json:"available"`
	Error     string           `json:"error,omitempty"`
	Hardware  []patchbay.Node  `json:"hardware,omitempty"`
	Links     []patchbay.Link  `json:"links,omitempty"`
	Presets   []patchbay.State `json:"presets"`
}

func cliPatchbayStatus() int {
	g, err := patchbay.Snapshot()
	st := patchbayStatus{Available: err == nil}
	if err != nil {
		st.Error = err.Error()
	} else {
		st.Hardware = g.Hardware()
		st.Links = g.Links
		states, serr := patchbay.States(g)
		if serr != nil {
			st.Error = serr.Error()
		}
		st.Presets = states
	}
	code := printJSON(st)
	if err != nil || st.Error != "" {
		return 1
	}
	return code
}

func cliPatchbaySave(name string) int {
	g, err := patchbay.Snapshot()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err := patchbay.SavePreset(name, g); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println("ok")
	return 0
}

func cliPatchbayApply(name string, replace bool) int {
	g, err := patchbay.Snapshot()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	p, err := patchbay.LoadPreset(name)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	res, err := patchbay.Apply(p, g, replace)
	printJSON(res)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if len(res.Missing) > 0 {
		fmt.Fprintf(os.Stderr, "%d link(s) skipped: endpoints missing\n", len(res.Missing))
		return 1
	}
	return 0
}
