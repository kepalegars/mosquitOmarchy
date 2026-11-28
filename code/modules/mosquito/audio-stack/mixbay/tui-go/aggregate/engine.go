package aggregate

import (
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"

	"mosquitomarchy.local/mosquitomixbay-tui/patchbay"
)

// runCommand is a variable so tests exercise the engine without a live
// PipeWire daemon.
var runCommand = func(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).Output()
}

// Available reports whether the two PipeWire CLI tools the engine needs exist.
func Available() bool {
	_, cli := exec.LookPath("pw-cli")
	_, dump := exec.LookPath("pw-dump")
	return cli == nil && dump == nil
}

// Info is the one payload the TUI, the CLI, pipewire-settings and live mode
// read. No surface keeps its own copy of the state.
type Info struct {
	Available bool     `json:"available"`
	Active    string   `json:"active,omitempty"`
	Locked    bool     `json:"locked"`
	Unlocked  bool     `json:"unlocked"`
	State     string   `json:"state"`
	Rate      int      `json:"rate,omitempty"`
	Members   []Member `json:"members,omitempty"`
	Missing   []string `json:"missing,omitempty"`
	LinksOK   bool     `json:"links_ok"`
	Reason    string   `json:"reason,omitempty"`
}

func quote(s string) string { return strconv.Quote(s) }

func positions(m Member) string {
	ch := m.Channels
	if len(ch) == 0 {
		ch = []string{"FL", "FR"}
	}
	var parts []string
	for _, c := range ch {
		parts = append(parts, c)
	}
	return "[ " + strings.Join(parts, " ") + " ]"
}

// matches builds the multi-key selector for one member. node.name is kept as
// the last key: on a profile/UCM change the other keys still identify the interface.
func matches(m Member) string {
	var keys []string
	if m.Device != "" {
		keys = append(keys, "device.name = "+quote(m.Device))
	}
	if m.Card != "" {
		keys = append(keys, "api.alsa.card = "+quote(m.Card))
	}
	if m.Profile != "" {
		keys = append(keys, "device.profile.name = "+quote(m.Profile))
	}
	keys = append(keys, "node.name = "+quote(m.Node))
	return strings.Join(keys, " ")
}

func streamRule(m Member, rate int) string {
	props := []string{"audio.position = " + positions(m)}
	// A member with a shared hardware clock must not be resampled; the default
	// is PipeWire's adaptive resampler, which is what drift correction means.
	if m.Drift {
		q := m.Quality
		if q <= 0 {
			q = 4
		}
		props = append(props, fmt.Sprintf("resample.quality = %d", q))
	} else {
		props = append(props, "resample.disable = true")
	}
	if m.Latency > 0 && rate > 0 {
		props = append(props, fmt.Sprintf("node.latency = %d/%d", m.Latency, rate))
	}
	return fmt.Sprintf(`{ matches = [ { %s } ]
        actions = { create-stream = { %s } } }`, matches(m), strings.Join(props, " "))
}

// moduleArgs renders one combine-stream block's args. mode is sink or source.
func moduleArgs(p Preset, name, description, mode string, members []Member, rate int) string {
	var rules []string
	for _, m := range members {
		rules = append(rules, streamRule(m, rate))
	}
	class := "Audio/Sink"
	if mode == "source" {
		class = "Audio/Source"
	}
	return fmt.Sprintf(`{
      combine.mode = %s
      node.name = %s
      node.description = %s
      combine.latency-compensate = false
      combine.props = { media.class = %s audio.position = [ FL FR ] }
      stream.props = { stream.dont-remix = true }
      stream.rules = [ %s ]
    }`, mode, quote(name), quote(description), quote(class), strings.Join(rules, " "))
}

func graphRate() int {
	out, err := runCommand("pw-metadata", "-n", "settings", "0")
	if err != nil {
		return 0
	}
	re := regexp.MustCompile(`key:'clock.rate'\s+value:'(\d+)'`)
	m := re.FindSubmatch(out)
	if len(m) < 2 {
		return 0
	}
	n, _ := strconv.Atoi(string(m[1]))
	return n
}

var objectID = regexp.MustCompile(`Object:\s*(\d+)`)

func loadModule(args string) (int, error) {
	out, err := runCommand("pw-cli", "load-module", "libpipewire-module-combine-stream", args)
	if err != nil {
		return 0, fmt.Errorf("pw-cli load-module: %w", err)
	}
	m := objectID.FindSubmatch(out)
	if len(m) < 2 {
		return 0, fmt.Errorf("pw-cli did not report a module id: %s", strings.TrimSpace(string(out)))
	}
	id, err := strconv.Atoi(string(m[1]))
	if err != nil {
		return 0, err
	}
	return id, nil
}

func unloadModule(id int) error {
	_, err := runCommand("pw-cli", "unload-module", strconv.Itoa(id))
	return err
}

// Activate loads the combine-stream modules for one preset. Everything is
// unloaded again if any half of the load fails: a partial aggregate is worse
// than none.
func Activate(p Preset, bypassLock bool) error {
	if !bypassLock {
		if err := EnsureWritable(); err != nil {
			return err
		}
	}
	if err := p.Validate(); err != nil {
		return err
	}
	if !p.Applies() {
		return fmt.Errorf("interfaces changed — reload the preset before activating it")
	}
	rate := p.Rate
	if rate == 0 {
		rate = graphRate()
	}
	if rate == 0 {
		rate = 48000
	}
	rt, _ := readRuntime()
	if len(rt.Modules) > 0 {
		return fmt.Errorf("an aggregate is already active: %s (deactivate it first)", rt.Name)
	}
	var loaded []int
	rollback := func() {
		for i := len(loaded) - 1; i >= 0; i-- {
			_ = unloadModule(loaded[i])
		}
	}
	if len(p.Outputs) > 0 {
		display := p.DisplayName
		if display == "" {
			display = p.Name
		}
		id, err := loadModule(moduleArgs(p, p.SinkName(), display, "sink", p.Outputs, rate))
		if err != nil {
			rollback()
			return err
		}
		loaded = append(loaded, id)
	}
	if len(p.Inputs) > 0 {
		display := p.DisplayName
		if display == "" {
			display = p.Name
		}
		id, err := loadModule(moduleArgs(p, p.SourceName(), display+" (inputs)", "source", p.Inputs, rate))
		if err != nil {
			rollback()
			return err
		}
		loaded = append(loaded, id)
	}
	rt = runtimeState{Name: p.Name, Modules: loaded}
	_ = writeRuntime(rt)
	if err := SetActive(p.Name); err != nil {
		rollback()
		_ = clearRuntime()
		return err
	}
	// Remember the links the module created. Repair uses this snapshot instead
	// of guessing combine-stream's port names.
	if g2, err := patchbay.Snapshot(); err == nil {
		var links []patchbay.Link
		for _, l := range g2.Links {
			if l.OutNode == p.SinkName() || l.InNode == p.SourceName() {
				links = append(links, l)
			}
		}
		rt.Links = links
		_ = writeRuntime(rt)
	}
	return nil
}

// Deactivate unloads exactly what Activate loaded. Module IDs are per-boot and
// therefore live in the runtime dir, never in the persistent preset.
func Deactivate(bypassLock bool) error {
	if !bypassLock {
		if err := EnsureWritable(); err != nil {
			return err
		}
	}
	rt, err := readRuntime()
	if err != nil {
		return err
	}
	var errs []string
	for i := len(rt.Modules) - 1; i >= 0; i-- {
		if err := unloadModule(rt.Modules[i]); err != nil {
			errs = append(errs, err.Error())
		}
	}
	_ = clearRuntime()
	if err := ClearActive(); err != nil {
		errs = append(errs, err.Error())
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

// Restore is what the user service calls at login. It never consults the live
// lock: the lock protects interactive changes, not session startup.
func Restore() error {
	name, err := ActiveName()
	if err != nil || name == "" {
		return err
	}
	p, err := Load(name)
	if err != nil {
		return err
	}
	rt, _ := readRuntime()
	if len(rt.Modules) > 0 {
		return nil
	}
	return Activate(p, true)
}

// Repair re-adds links that an external graph editor removed. It never
// disconnects anything, so it cannot fight the user beyond restoring the
// aggregate the user explicitly activated.
func Repair() (int, error) {
	rt, err := readRuntime()
	if err != nil || len(rt.Links) == 0 {
		return 0, err
	}
	g, err := patchbay.Snapshot()
	if err != nil {
		return 0, err
	}
	added := 0
	for _, l := range rt.Links {
		if g.HasLink(l) {
			continue
		}
		if err := patchbay.AddLink(l); err != nil {
			return added, err
		}
		added++
	}
	return added, nil
}

// Status reports the one view of the aggregate used by every surface.
func Status() (Info, error) {
	st := Info{
		Available: Available(),
		Locked:    Locked(),
		Unlocked:  Unlocked(),
		State:     "inactive",
		LinksOK:   true,
		Rate:      graphRate(),
	}
	name, err := ActiveName()
	if err != nil {
		return st, err
	}
	if name == "" {
		st.Reason = "no aggregate active"
		return st, nil
	}
	st.Active = name
	p, err := Load(name)
	if err != nil {
		return st, err
	}
	st.Members = append(st.Members, p.Outputs...)
	st.Members = append(st.Members, p.Inputs...)
	rt, err := readRuntime()
	if err != nil {
		return st, err
	}
	if len(rt.Modules) == 0 {
		st.State = "degraded"
		st.Reason = "no module loaded"
		return st, nil
	}
	g, err := patchbay.Snapshot()
	if err != nil {
		st.State = "degraded"
		st.Reason = err.Error()
		return st, nil
	}
	for _, node := range []string{p.SinkName(), p.SourceName()} {
		if node == p.SinkName() && len(p.Outputs) == 0 {
			continue
		}
		if node == p.SourceName() && len(p.Inputs) == 0 {
			continue
		}
		found := false
		for _, n := range g.Nodes {
			if n.Name == node {
				found = true
				break
			}
		}
		if !found {
			st.Missing = append(st.Missing, node)
		}
	}
	for _, l := range rt.Links {
		if !g.HasLink(l) {
			st.LinksOK = false
			break
		}
	}
	st.State = "active"
	if len(st.Missing) > 0 {
		st.State = "degraded"
		st.Reason = "virtual node missing"
	} else if !st.LinksOK {
		st.State = "degraded"
		st.Reason = "a link was removed"
	}
	return st, nil
}
