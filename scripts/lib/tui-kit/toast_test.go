package tuikit

import (
	"testing"
	"time"
)

// TestToastExpireGenerationGuard pins the core of the temporary-toast fix:
// an expiry message only clears the toast whose generation still matches, so
// a newer toast can't be wiped out by an older toast's timer.
func TestToastExpireGenerationGuard(t *testing.T) {
	var toast Toast
	toast, _ = toast.SetOK("first")
	if toast.View() == "" {
		t.Fatal("toast should be visible after SetOK")
	}
	old := toast.Gen()

	toast, _ = toast.SetWarn("second")
	toast = toast.Expire(old)
	if toast.View() == "" {
		t.Fatal("stale expiry cleared a newer toast")
	}

	toast = toast.Expire(toast.Gen())
	if toast.View() != "" {
		t.Fatal("matching expiry should clear the toast")
	}
}

func TestToastExpireCmdCarriesGeneration(t *testing.T) {
	msg := ToastExpireCmd(7, time.Millisecond)()
	expire, ok := msg.(ToastExpireMsg)
	if !ok {
		t.Fatalf("got %T, want ToastExpireMsg", msg)
	}
	if expire.Gen != 7 {
		t.Fatalf("got gen %d, want 7", expire.Gen)
	}
}

func TestToastClearNonCriticalKeepsErrors(t *testing.T) {
	var okToast Toast
	okToast, _ = okToast.SetOK("done")
	if got := okToast.ClearNonCritical(); got.View() != "" {
		t.Fatal("OK toast should not survive ClearNonCritical")
	}

	var errToast Toast
	errToast, _ = errToast.SetErr("boom")
	if got := errToast.ClearNonCritical(); got.View() == "" {
		t.Fatal("error toast should survive ClearNonCritical")
	}
}

func TestToastLifetimes(t *testing.T) {
	if got := toastLifetimeFor(toastOK); got != 10*time.Second {
		t.Errorf("OK lifetime = %v, want 10s", got)
	}
	for _, kind := range []toastKind{toastWarn, toastErr} {
		if got := toastLifetimeFor(kind); got != 10*time.Second {
			t.Errorf("kind %d lifetime = %v, want 10s", kind, got)
		}
	}
}
