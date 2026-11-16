package profiles

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// DefaultRepoURL is the community repo. It can be replaced with
// $MIXBAY_PROFILES_URL or profiles-set-url, so a fork/mirror works unchanged.
const DefaultRepoURL = "https://raw.githubusercontent.com/kepalegars/mosquito-mixbay-profiles/main"

// IndexCard is one row of index.json. sha256 makes a download verifiable even
// when the index and card come from different requests.
type IndexCard struct {
	ID      string `json:"id"`
	Display string `json:"display"`
	Vendor  string `json:"vendor"`
	Version string `json:"version"`
	Native  bool   `json:"native"`
	Path    string `json:"path"`
	SHA256  string `json:"sha256"`
	// Upstream is the optional direct card URL exported from the card, so a
	// fresh install learns it even before opening the card.
	Upstream string  `json:"upstream,omitempty"`
	Credits  Credits `json:"credits,omitempty"`
}

// Index is the repo entry point.
type Index struct {
	SchemaVersion int                    `json:"schema_version"`
	Name          string                 `json:"name"`
	Revision      string                 `json:"revision"`
	Cards         []IndexCard            `json:"cards"`
	Integrations  map[string]Integration `json:"integrations,omitempty"`
}

// Integration is the profile-owned tooling a card asks for by name
// (spec.setup). Its files are code, so they live outside cards/ and every file
// is pinned by sha256 in the index.
type Integration struct {
	Version string            `json:"version"`
	Path    string            `json:"path"`
	Files   map[string]string `json:"files"` // file name -> sha256
}

func (ix Index) Card(id string) (IndexCard, bool) {
	for _, c := range ix.Cards {
		if c.ID == id {
			return c, true
		}
	}
	return IndexCard{}, false
}

// RepoURL resolves the configured raw base URL.
func RepoURL() string {
	if v := strings.TrimSpace(os.Getenv("MIXBAY_PROFILES_URL")); v != "" {
		return normalizeRepoURL(v)
	}
	data, err := os.ReadFile(filepath.Join(ConfigDir(), "profiles.json"))
	if err == nil {
		var cfg struct {
			URL string `json:"url"`
		}
		if json.Unmarshal(data, &cfg) == nil && strings.TrimSpace(cfg.URL) != "" {
			return normalizeRepoURL(cfg.URL)
		}
	}
	return DefaultRepoURL
}

// RepoPageURL is the browser page matching the configured raw base, so opening
// the community repo also works with a fork or mirror.
func RepoPageURL() string {
	u := RepoURL()
	if rest, ok := strings.CutPrefix(u, "https://raw.githubusercontent.com/"); ok {
		parts := strings.Split(rest, "/")
		if len(parts) >= 3 {
			return "https://github.com/" + parts[0] + "/" + parts[1]
		}
	}
	return u
}

// SetRepoURL persists a mirror/repo URL and returns the normalized value.
func SetRepoURL(url string) (string, error) {
	url = normalizeRepoURL(strings.TrimSpace(url))
	if !strings.HasPrefix(url, "http://") && !strings.HasPrefix(url, "https://") {
		return "", errors.New("profile URL must be http(s)")
	}
	path := filepath.Join(ConfigDir(), "profiles.json")
	data, _ := json.MarshalIndent(struct {
		URL string `json:"url"`
	}{URL: url}, "", "  ")
	if err := writeFileAtomic(path, append(data, '\n')); err != nil {
		return "", err
	}
	return url, nil
}

// normalizeRepoURL turns a GitHub web URL into its raw base so users can paste
// the address they see in a browser.
func normalizeRepoURL(u string) string {
	u = strings.TrimSuffix(strings.TrimSpace(u), "/")
	u = strings.TrimSuffix(u, "/index.json")
	if strings.HasPrefix(u, "https://github.com/") {
		rest := strings.TrimPrefix(u, "https://github.com/")
		parts := strings.Split(rest, "/")
		if len(parts) == 2 {
			return "https://raw.githubusercontent.com/" + rest + "/main"
		}
		if len(parts) >= 4 && parts[2] == "tree" {
			return "https://raw.githubusercontent.com/" + parts[0] + "/" + parts[1] + "/" + strings.Join(parts[3:], "/")
		}
	}
	return u
}

// HTTPClient is replaceable in tests.
var HTTPClient = &http.Client{Timeout: 15 * time.Second}

func get(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	return body, nil
}

// ValidateIndex rejects an index with duplicate ids, unsafe paths or bad
// digests before anything touches the local store.
func ValidateIndex(ix Index) error {
	if ix.SchemaVersion != SchemaVersion {
		return fmt.Errorf("index schema_version = %d, want %d", ix.SchemaVersion, SchemaVersion)
	}
	seen := map[string]bool{}
	for _, c := range ix.Cards {
		if !ValidID(c.ID) {
			return fmt.Errorf("index: invalid card id %q", c.ID)
		}
		if seen[c.ID] {
			return fmt.Errorf("index: duplicate card id %q", c.ID)
		}
		seen[c.ID] = true
		if !strings.HasPrefix(c.Path, "cards/") || !strings.HasSuffix(c.Path, "/card.json") ||
			strings.Contains(c.Path, "..") {
			return fmt.Errorf("index: unsafe path %q for %s", c.Path, c.ID)
		}
		if len(c.SHA256) != 64 || strings.Trim(c.SHA256, "0123456789abcdef") != "" {
			return fmt.Errorf("index: invalid sha256 for %s", c.ID)
		}
		if c.Upstream != "" && !ValidUpstreamURL(c.Upstream) {
			return fmt.Errorf("index: unsafe upstream URL for %s", c.ID)
		}
	}
	for name, integ := range ix.Integrations {
		if !ValidID(name) {
			return fmt.Errorf("index: invalid integration name %q", name)
		}
		if integ.Path != "integrations/"+name || strings.Contains(integ.Path, "..") {
			return fmt.Errorf("index: unsafe integration path %q for %s", integ.Path, name)
		}
		if len(integ.Files) == 0 || len(integ.Files) > 32 {
			return fmt.Errorf("index: integration %s needs 1-32 files", name)
		}
		for file, sum := range integ.Files {
			if file == "" || file != filepath.Base(file) || strings.Contains(file, "..") {
				return fmt.Errorf("index: unsafe integration file %q in %s", file, name)
			}
			if len(sum) != 64 || strings.Trim(sum, "0123456789abcdef") != "" {
				return fmt.Errorf("index: invalid sha256 for %s/%s", name, file)
			}
		}
	}
	return nil
}

// IntegrationDir is where a profile-owned integration is unpacked, one folder
// per setup name (oscmix, evo-raw). Nothing here ships with Mixbay.
func IntegrationDir(name string) string {
	dir := os.Getenv("XDG_DATA_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(dir, "mosquitomixbay", "integrations", name)
}

// EnsureIntegration downloads the files a setup name needs, verifying each
// sha256 from the index. A matching local copy is reused without a download.
func EnsureIntegration(ctx context.Context, name string) (string, error) {
	if !ValidID(name) {
		return "", fmt.Errorf("invalid integration name %q", name)
	}
	dir := IntegrationDir(name)
	ix, err := FetchIndex(ctx)
	if err != nil {
		cached, cerr := CachedIndex()
		if cerr != nil {
			return "", err
		}
		ix = cached
	}
	integ, ok := ix.Integrations[name]
	if !ok {
		return "", fmt.Errorf("%w: integration %s", ErrNotFound, name)
	}
	if integrationReady(dir, integ) {
		return dir, nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	base := strings.TrimSuffix(RepoURL(), "/") + "/" + integ.Path
	for file, want := range integ.Files {
		body, err := get(ctx, base+"/"+file)
		if err != nil {
			return "", err
		}
		sum := sha256.Sum256(body)
		if got := hex.EncodeToString(sum[:]); got != want {
			return "", fmt.Errorf("%s/%s: sha256 mismatch (index %s, download %s)", name, file, want, got)
		}
		path := filepath.Join(dir, file)
		if err := writeFileAtomic(path, body); err != nil {
			return "", err
		}
		mode := os.FileMode(0o644)
		if strings.HasSuffix(file, ".sh") || strings.HasSuffix(file, ".py") || strings.HasPrefix(file, "launch-") {
			mode = 0o755
		}
		if err := os.Chmod(path, mode); err != nil {
			return "", err
		}
	}
	marker, _ := json.MarshalIndent(integ, "", "  ")
	if err := writeFileAtomic(filepath.Join(dir, ".manifest.json"), append(marker, '\n')); err != nil {
		return "", err
	}
	return dir, nil
}

func integrationReady(dir string, integ Integration) bool {
	data, err := os.ReadFile(filepath.Join(dir, ".manifest.json"))
	if err != nil {
		return false
	}
	var got Integration
	if json.Unmarshal(data, &got) != nil || got.Version != integ.Version || len(got.Files) != len(integ.Files) {
		return false
	}
	for file, sum := range integ.Files {
		if got.Files[file] != sum {
			return false
		}
		if _, err := os.Stat(filepath.Join(dir, file)); err != nil {
			return false
		}
	}
	return true
}

// FetchUpstreamCard downloads a card from the direct URL it declares. The URL
// must belong to the official profiles repo, and the card is validated like
// any import before it can replace anything.
func FetchUpstreamCard(ctx context.Context, id, url string) (Card, error) {
	if !ValidUpstreamURL(url) {
		return Card{}, fmt.Errorf("%s: refusing upstream URL %q", id, url)
	}
	body, err := get(ctx, url)
	if err != nil {
		return Card{}, err
	}
	c, issues, err := Parse(body)
	if err != nil {
		return Card{}, err
	}
	if errs := Errors(issues); len(errs) > 0 {
		return Card{}, fmt.Errorf("%s: %s", id, errs[0])
	}
	if c.Spec.ID != id {
		return Card{}, fmt.Errorf("%s: upstream card declares id %q", id, c.Spec.ID)
	}
	return c, nil
}

// CheckUpstreams fetches the direct URL of every installed card that declares
// one. A failure is not an error: offline is normal and the published index
// stays the fallback.
func CheckUpstreams(ctx context.Context) map[string]Card {
	out := map[string]Card{}
	ix, _ := FetchIndex(ctx)
	if ix.SchemaVersion == 0 {
		ix, _ = CachedIndex()
	}
	for _, m := range Installed() {
		card, _, err := Effective(m.ID)
		if err != nil {
			continue
		}
		url := card.Spec.Upstream
		if url == "" {
			if ic, ok := ix.Card(m.ID); ok {
				url = ic.Upstream
			}
		}
		if url == "" {
			continue
		}
		up, err := FetchUpstreamCard(ctx, m.ID, url)
		if err != nil {
			continue
		}
		out[m.ID] = up
	}
	return out
}

// DeployCard installs a card that was already fetched and validated (the
// direct-upstream update path). It follows the same rules as an import.
func DeployCard(c Card) error {
	if errs := Errors(Validate(c)); len(errs) > 0 {
		return fmt.Errorf("%s: %s", c.Spec.ID, errs[0])
	}
	sum := sha256.Sum256(Encode(c))
	return deployCard(c, IndexCard{ID: c.Spec.ID, SHA256: hex.EncodeToString(sum[:])}, "upstream")
}

// FetchIndex downloads and validates index.json.
func FetchIndex(ctx context.Context) (Index, error) {
	return FetchIndexAt(ctx, RepoURL())
}

func FetchIndexAt(ctx context.Context, base string) (Index, error) {
	body, err := get(ctx, strings.TrimSuffix(base, "/")+"/index.json")
	if err != nil {
		return Index{}, err
	}
	var ix Index
	if err := json.Unmarshal(body, &ix); err != nil {
		return Index{}, fmt.Errorf("index.json: %w", err)
	}
	if err := ValidateIndex(ix); err != nil {
		return Index{}, err
	}
	_ = saveIndexCache(body)
	return ix, nil
}

func indexCacheFile() string {
	dir := os.Getenv("XDG_CACHE_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".cache")
	}
	return filepath.Join(dir, "mosquitomixbay", "profiles-index.json")
}

func saveIndexCache(data []byte) error {
	return writeFileAtomic(indexCacheFile(), data)
}

// CachedIndex returns the last successfully fetched index, so the library
// screen still lists known cards offline.
func CachedIndex() (Index, error) {
	data, err := os.ReadFile(indexCacheFile())
	if err != nil {
		return Index{}, err
	}
	var ix Index
	if err := json.Unmarshal(data, &ix); err != nil {
		return Index{}, err
	}
	return ix, ValidateIndex(ix)
}

func fetchCard(ctx context.Context, base string, ic IndexCard) (Card, error) {
	body, err := get(ctx, strings.TrimSuffix(base, "/")+"/"+ic.Path)
	if err != nil {
		return Card{}, err
	}
	sum := sha256.Sum256(body)
	if got := hex.EncodeToString(sum[:]); got != ic.SHA256 {
		return Card{}, fmt.Errorf("%s: sha256 mismatch (index %s, download %s)", ic.ID, ic.SHA256, got)
	}
	c, issues, err := Parse(body)
	if err != nil {
		return Card{}, err
	}
	if errs := Errors(issues); len(errs) > 0 {
		return Card{}, fmt.Errorf("%s: %s", ic.ID, errs[0])
	}
	if c.Spec.ID != ic.ID {
		return Card{}, fmt.Errorf("%s: card declares id %q", ic.ID, c.Spec.ID)
	}
	return c, nil
}

// ImportResult reports one card of a bulk import.
type ImportResult struct {
	ID      string `json:"id"`
	Display string `json:"display"`
	Version string `json:"version"`
	Updated bool   `json:"updated"`
	// Setup is the card's named integration to run after the download
	// ("oscmix", "douze"), empty when it needs none.
	Setup string `json:"setup,omitempty"`
	Err   error  `json:"-"`
}

// Import downloads the selected profiles from the repo and deploys them.
// Only the card JSON is fetched; captures and raw sessions stay remote.
//
// shortcut: card.json only; add opt-in capture download when a screen uses it
// (TODO-PROFILES.md §7).
func Import(ctx context.Context, ids []string) ([]ImportResult, error) {
	ix, err := FetchIndex(ctx)
	if err != nil {
		return nil, err
	}
	base := RepoURL()
	var out []ImportResult
	for _, id := range ids {
		res := ImportResult{ID: id}
		ic, ok := ix.Card(id)
		if !ok {
			res.Err = fmt.Errorf("%w: %s", ErrNotFound, id)
			out = append(out, res)
			continue
		}
		res.Display, res.Version = ic.Display, ic.Version
		card, err := fetchCard(ctx, base, ic)
		if err != nil {
			res.Err = err
			out = append(out, res)
			continue
		}
		res.Setup = card.Spec.Setup
		_, statErr := os.Stat(upstreamFile(id))
		res.Updated = statErr == nil
		if err := deployCard(card, ic, ix.Revision); err != nil {
			res.Err = err
			out = append(out, res)
			continue
		}
		out = append(out, res)
	}
	return out, nil
}

// deployCard writes one card atomically, preserving the user override folder.
func deployCard(c Card, ic IndexCard, revision string) error {
	id := c.Spec.ID
	if err := os.MkdirAll(filepath.Dir(upstreamFile(id)), 0o755); err != nil {
		return err
	}
	if err := writeFileAtomic(upstreamFile(id), Encode(c)); err != nil {
		return err
	}
	best := readMeta(id)
	if best.InstalledAt.IsZero() {
		best.InstalledAt = time.Now().UTC()
	}
	best.ID, best.Display, best.Vendor = id, c.Spec.Display, c.Spec.Vendor
	best.Version, best.Native = c.Spec.Version, false
	best.Source, best.Revision, best.SHA256 = "repo", revision, ic.SHA256
	_ = os.Remove(removedFile(id))
	return writeMeta(id, best)
}

// Offer is the connection-time suggestion: install a missing profile or update
// a stale one.
type Offer struct {
	ID      string    `json:"id"`
	Display string    `json:"display"`
	Version string    `json:"version"`
	Kind    string    `json:"kind"` // install | update
	Index   IndexCard `json:"-"`
}

// CheckUpdates compares connected interface ids/names with the repo index.
// Network failures are swallowed (offline is normal); the caller keeps the
// local profiles it already has.
func CheckUpdates(ctx context.Context, entries []ConnEntry) ([]Offer, error) {
	ix, err := FetchIndex(ctx)
	if err != nil {
		cached, cerr := CachedIndex()
		if cerr != nil {
			return nil, err
		}
		ix = cached
	}
	var out []Offer
	for _, e := range entries {
		ic, ok := matchEntry(ix, e)
		if !ok {
			continue
		}
		if inst, _, err := Effective(ic.ID); err == nil {
			if inst.Spec.Version == ic.Version || versionLess(ic.Version, inst.Spec.Version) {
				continue
			}
			out = append(out, Offer{ID: ic.ID, Display: ic.Display, Version: ic.Version, Kind: "update", Index: ic})
			continue
		}
		out = append(out, Offer{ID: ic.ID, Display: ic.Display, Version: ic.Version, Kind: "install", Index: ic})
	}
	return out, nil
}

// ConnEntry is the subset of the connection log this package needs.
type ConnEntry struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Match string `json:"match"`
}

// MatchEntry resolves a connected interface against the repo index with the
// same longest-display rule the hotplug prompt uses.
func MatchEntry(ix Index, e ConnEntry) (IndexCard, bool) { return matchEntry(ix, e) }

func matchEntry(ix Index, e ConnEntry) (IndexCard, bool) {
	if ic, ok := ix.Card(e.ID); ok {
		return ic, true
	}
	name := strings.ToLower(strings.TrimSpace(e.Name + " " + e.Match))
	entryName := strings.ToLower(strings.TrimSpace(e.Name))
	if name == "" {
		return IndexCard{}, false
	}
	// Exact display first: "RME Fireface UFX" must never resolve to "…UFX II".
	for _, ic := range ix.Cards {
		d := strings.ToLower(ic.Display)
		if d != "" && (d == name || d == entryName) {
			return ic, true
		}
	}
	// Then the LONGEST display contained in the entry: the RME names nest, so
	// "RME Fireface UFX III" has to beat "RME Fireface UFX II" and "…UFX".
	best, bestLen := IndexCard{}, 0
	for _, ic := range ix.Cards {
		d := strings.ToLower(ic.Display)
		if d != "" && strings.Contains(name, d) && len(d) > bestLen {
			best, bestLen = ic, len(d)
		}
	}
	if bestLen > 0 {
		return best, true
	}
	// Finally a short entry name inside a display, and only when exactly one
	// card matches: an ambiguous family must not offer the wrong mixer.
	var only IndexCard
	matches := 0
	for _, ic := range ix.Cards {
		d := strings.ToLower(ic.Display)
		if entryName != "" && strings.Contains(d, entryName) {
			only, matches = ic, matches+1
		}
	}
	if matches == 1 {
		return only, true
	}
	return IndexCard{}, false
}

// VersionLess compares dotted numeric versions ("1.2.0" < "1.10.0").
func VersionLess(a, b string) bool { return versionLess(a, b) }

// versionLess compares dotted numeric versions ("1.2.0" < "1.10.0"). Missing
// or non-numeric parts compare as 0, which is fine for card metadata.
func versionLess(a, b string) bool {
	as, bs := strings.Split(strings.TrimPrefix(a, "v"), "."), strings.Split(strings.TrimPrefix(b, "v"), ".")
	for i := 0; i < len(as) || i < len(bs); i++ {
		var av, bv int
		if i < len(as) {
			av, _ = strconv.Atoi(as[i])
		}
		if i < len(bs) {
			bv, _ = strconv.Atoi(bs[i])
		}
		if av != bv {
			return av < bv
		}
	}
	return false
}

// SortedOffers is a small helper for stable UI messages.
func SortedOffers(in []Offer) []Offer {
	out := append([]Offer(nil), in...)
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}
