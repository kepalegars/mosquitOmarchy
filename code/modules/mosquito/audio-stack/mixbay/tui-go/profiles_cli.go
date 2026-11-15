// CLI surface for the community profile store. Kept next to cli.go so the
// dispatcher keeps one entry point (mosquito-mixbay-actions).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"mosquitomarchy.local/mosquitomixbay-tui/profiles"
)

func profileContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 30*time.Second)
}

func cliProfilesIndex(args []string) int {
	fs := flag.NewFlagSet("profiles-index", flag.ContinueOnError)
	cached := fs.Bool("cached", false, "use the last downloaded index, no network")
	fs.BoolVar(cached, "offline", false, "alias for --cached")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	var ix profiles.Index
	var err error
	if *cached {
		ix, err = profiles.CachedIndex()
	} else {
		ctx, cancel := profileContext()
		defer cancel()
		ix, err = profiles.FetchIndex(ctx)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return printJSON(ix)
}

func cliProfilesImport(args []string) int {
	fs := flag.NewFlagSet("profiles-import", flag.ContinueOnError)
	all := fs.Bool("all", false, "import every card in the index")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	ids := fs.Args()
	ctx, cancel := profileContext()
	defer cancel()
	if *all {
		ix, err := profiles.FetchIndex(ctx)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		ids = nil
		for _, c := range ix.Cards {
			ids = append(ids, c.ID)
		}
	}
	if len(ids) == 0 {
		fmt.Fprintln(os.Stderr, "usage: profiles-import ID... [--all]")
		return 2
	}
	results, err := profiles.Import(ctx, ids)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	code := 0
	for _, r := range results {
		if r.Err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", r.ID, r.Err)
			code = 1
			continue
		}
		verb := "imported"
		if r.Updated {
			verb = "updated"
		}
		fmt.Printf("%s %s (%s)\n", verb, r.ID, r.Version)
	}
	return code
}

func cliProfilesExport(args []string) int {
	// Go's flag package stops at the first positional, but the documented
	// form is `profiles-export ID... --to DIR`. Pull --to out first.
	var ids []string
	to := ""
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--to" && i+1 < len(args):
			to = args[i+1]
			i++
		case strings.HasPrefix(args[i], "--to="):
			to = strings.TrimPrefix(args[i], "--to=")
		default:
			ids = append(ids, args[i])
		}
	}
	dest, err := profiles.Export(ids, to)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(dest)
	return 0
}

func cliProfilesLocal() int {
	type row struct {
		profiles.Meta
		Preset string `json:"preset,omitempty"`
	}
	var out []row
	for _, m := range profiles.Installed() {
		r := row{Meta: m}
		if c, _, err := profiles.Effective(m.ID); err == nil {
			r.Preset = c.Preset()
		}
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return printJSON(out)
}

func cliProfilesValidate(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: profiles-validate FILE|DIR...")
		return 2
	}
	code := 0
	for _, path := range args {
		info, err := os.Stat(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
			code = 1
			continue
		}
		if info.IsDir() {
			path = filepath.Join(path, "card.json")
		}
		data, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
			code = 1
			continue
		}
		card, issues, err := profiles.Parse(data)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
			code = 1
			continue
		}
		if len(issues) == 0 {
			fmt.Printf("%s: ok (%s)\n", path, card.Spec.ID)
			continue
		}
		for _, i := range issues {
			fmt.Fprintf(os.Stderr, "%s: %s\n", path, i)
		}
		if len(profiles.Errors(issues)) > 0 {
			code = 1
		}
	}
	return code
}

func cliProfilesRemove(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: profiles-remove ID...")
		return 2
	}
	code := 0
	for _, id := range args {
		if err := profiles.Remove(id); err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", id, err)
			code = 1
			continue
		}
		fmt.Printf("removed %s\n", id)
	}
	return code
}

func cliProfilesIntegration(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: profiles-integration NAME")
		return 2
	}
	ctx, cancel := profileContext()
	defer cancel()
	dir, err := profiles.EnsureIntegration(ctx, args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(dir)
	return 0
}

func cliProfilesSetURL(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: profiles-set-url URL")
		return 2
	}
	url, err := profiles.SetRepoURL(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(url)
	return 0
}

func cliProfilesOffer(_ []string) int {
	// Prints the connection-time offers as JSON; the TUI uses the package
	// directly, this is for scripts and debugging.
	var conns []profiles.ConnEntry
	if out, err := execConnections(); err == nil {
		conns = out
	}
	ctx, cancel := profileContext()
	defer cancel()
	offers, err := profiles.CheckUpdates(ctx, conns)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return printJSON(profiles.SortedOffers(offers))
}

func execConnections() ([]profiles.ConnEntry, error) {
	data, err := os.ReadFile(filepath.Join(profiles.ConfigDir(), "connected-interfaces.json"))
	if err != nil {
		return nil, err
	}
	var out []profiles.ConnEntry
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	return out, nil
}
