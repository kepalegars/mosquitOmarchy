package tuikit

import "testing"

func pickerTestItems(n int) []PickerItem {
	items := make([]PickerItem, n)
	for i := 0; i < n; i++ {
		items[i] = PickerItem{Display: "option", Value: "v" + string(rune('a'+i%26)) + string(rune('0'+(i/26)%10))}
	}
	items[n-1] = PickerItem{Display: "Close", Value: "quit"}
	return items
}

// TestSetSizeDeterministic pins the fix for the "Close row flickers in then
// out" bug: bubbles' updatePagination() derives the new PerPage from the
// PREVIOUS pagination-view height, which left two self-consistent layouts
// for the same (w,h) depending on the picker's history. A fresh build at a
// size and a build first laid out tall then resized must now agree.
func TestSetSizeDeterministic(t *testing.T) {
	items := pickerTestItems(15)
	fresh := NewPicker("", items).SetSize(80, 10)
	tall := NewPicker("", items).SetSize(80, 30).SetSize(80, 10)

	if fresh.list.Paginator.PerPage != tall.list.Paginator.PerPage ||
		fresh.list.Paginator.TotalPages != tall.list.Paginator.TotalPages ||
		fresh.list.Index() != tall.list.Index() {
		t.Fatalf("nondeterministic layout: fresh(per=%d total=%d idx=%d) tall(per=%d total=%d idx=%d)",
			fresh.list.Paginator.PerPage, fresh.list.Paginator.TotalPages, fresh.list.Index(),
			tall.list.Paginator.PerPage, tall.list.Paginator.TotalPages, tall.list.Index())
	}
}

// TestSetSizePreservesSelection makes sure the repeated SetSize passes that
// reach a stable pagination never move the cursor (updatePagination rebuilds
// page/cursor from the absolute index each pass).
func TestSetSizePreservesSelection(t *testing.T) {
	items := pickerTestItems(30)
	items[25].Value = "needle"
	p := NewPicker("", items).SetSize(80, 10)
	p = p.SelectIndex(25)
	if got := p.SelectedValue(); got != "needle" {
		t.Fatalf("selected before resize = %q, want needle", got)
	}
	p = p.SetSize(80, 5).SetSize(80, 20)
	if got := p.SelectedValue(); got != "needle" {
		t.Fatalf("selected after resize = %q, want needle", got)
	}
}
