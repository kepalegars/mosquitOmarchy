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
//	mosquito-mixbay-actions save / load
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
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		return cliStatus(*dev)
	case "set":
		return cliSet(args[1:])
	case "mixer":
		return cliMixer(args[1:])
	case "save", "load":
		fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
		dev := fs.String("device", defaultDevice(), "device id")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		d, err := drivers.Open(*dev)
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
  status-json [--device ID]           full state (JSON)
  set volume DB [--pair N]            output volume in dB (--pair -1 = all)
  set gain DB -t inputN               input gain in dB
  set mute 0|1 -t TARGET              mute (inputN / output[N])
  set phantom 0|1 -t inputN           48V phantom power (EVO)
  set monitor 0..100                  direct-monitor blend (EVO 4 only)
  mixer inputN --volume DB --pan P [--bus 0]
  mixer outputX_Y --volume DB [--bus 0]
  save | load [--device ID]           snapshot / re-apply device state

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

func cliStatus(dev string) int {
	d, err := drivers.Open(dev)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	st, err := d.Status()
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

// shared flags: --device + -t target.
func deviceAndTarget(args []string) (string, string, []string) {
	dev := defaultDevice()
	target := ""
	rest := args[:0:0]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--device":
			i++
			if i < len(args) {
				dev = args[i]
			}
		case "-t", "--target":
			i++
			if i < len(args) {
				target = args[i]
			}
		default:
			rest = append(rest, args[i])
		}
	}
	return dev, target, rest
}

func cliSet(args []string) int {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: set volume|gain|mute|phantom|monitor VALUE [-t TARGET] [--device ID]")
		return 2
	}
	kind := args[0]
	dev, target, rest := deviceAndTarget(args[1:])
	d, err := drivers.Open(dev)
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
	vol := -128.0
	pan := 0.0
	bus := 0
	hasVol, hasPan := false, false
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--volume":
			i++
			vol, _ = strconv.ParseFloat(args[i], 64)
			hasVol = true
		case "--pan":
			i++
			pan, _ = strconv.ParseFloat(args[i], 64)
			hasPan = true
		case "--bus", "--mix-output":
			i++
			bus, _ = strconv.Atoi(args[i])
		case "--device":
			i++
			dev = args[i]
		}
	}
	if !hasVol {
		fmt.Fprintln(os.Stderr, "mixer needs --volume DB")
		return 2
	}
	d, err := drivers.Open(dev)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var inNum int
	if _, err := fmt.Sscanf(src, "input%d", &inNum); err == nil {
		if !hasPan {
			// Keep the stored pan when only the volume changes.
			if st, err := d.Status(); err == nil {
				if c, ok := st.Mixer[src]; ok {
					pan = c.Pan
				}
			}
		}
		if err := d.SetMixerInput(inNum, vol, pan, bus); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Println("ok")
		return 0
	}
	var l, r int
	if _, err := fmt.Sscanf(src, "output%d_%d", &l, &r); err == nil && r == l+1 && l%2 == 1 {
		if err := d.SetMixerOutput((l-1)/2, vol, -100, 100, bus); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Println("ok")
		return 0
	}
	fmt.Fprintf(os.Stderr, "unknown mixer source %q (want inputN or outputX_Y)\n", src)
	return 2
}
