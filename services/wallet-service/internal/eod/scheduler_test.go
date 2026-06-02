package eod

import (
	"testing"
	"time"
)

func TestParseClock(t *testing.T) {
	cases := []struct {
		in            string
		h, m, s       int
		wantErr       bool
	}{
		{"23:59:59", 23, 59, 59, false},
		{"00:05", 0, 5, 0, false},
		{"9:30:00", 9, 30, 0, false},
		{"24:00:00", 0, 0, 0, true}, // hour out of range
		{"12:60", 0, 0, 0, true},    // minute out of range
		{"12", 0, 0, 0, true},       // too few parts
		{"a:b:c", 0, 0, 0, true},    // non-numeric
	}
	for _, tc := range cases {
		h, m, s, err := parseClock(tc.in)
		if tc.wantErr {
			if err == nil {
				t.Errorf("parseClock(%q): expected error, got %d:%d:%d", tc.in, h, m, s)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseClock(%q): unexpected error %v", tc.in, err)
			continue
		}
		if h != tc.h || m != tc.m || s != tc.s {
			t.Errorf("parseClock(%q) = %d:%d:%d, want %d:%d:%d", tc.in, h, m, s, tc.h, tc.m, tc.s)
		}
	}
}

func TestNextFire(t *testing.T) {
	loc, err := time.LoadLocation("Asia/Ho_Chi_Minh")
	if err != nil {
		t.Fatalf("load tz: %v", err)
	}
	s := &Scheduler{loc: loc, h: 23, m: 59, s: 59}

	// Before today's fire time → fires today.
	now := time.Date(2026, 5, 30, 10, 0, 0, 0, loc)
	got := s.nextFire(now)
	want := time.Date(2026, 5, 30, 23, 59, 59, 0, loc)
	if !got.Equal(want) {
		t.Errorf("before time: got %v, want %v", got, want)
	}

	// After today's fire time → fires tomorrow.
	now = time.Date(2026, 5, 30, 23, 59, 59, 1, loc) // 1ns past
	got = s.nextFire(now)
	want = time.Date(2026, 5, 31, 23, 59, 59, 0, loc)
	if !got.Equal(want) {
		t.Errorf("after time: got %v, want %v", got, want)
	}

	// Exactly at fire time → strictly-after rule pushes to tomorrow (no double-fire).
	now = time.Date(2026, 5, 30, 23, 59, 59, 0, loc)
	got = s.nextFire(now)
	want = time.Date(2026, 5, 31, 23, 59, 59, 0, loc)
	if !got.Equal(want) {
		t.Errorf("at time: got %v, want %v", got, want)
	}
}

func TestPriorDay(t *testing.T) {
	loc, err := time.LoadLocation("Asia/Ho_Chi_Minh")
	if err != nil {
		t.Fatalf("load tz: %v", err)
	}
	cases := []struct {
		name string
		now  time.Time
		want string
	}{
		// Firing just after midnight closes the day that just ended.
		{"after midnight", time.Date(2026, 5, 30, 0, 30, 0, 0, loc), "2026-05-29"},
		// Month boundary: rolls back into the prior month.
		{"month start", time.Date(2026, 6, 1, 0, 30, 0, 0, loc), "2026-05-31"},
		// Year boundary.
		{"year start", time.Date(2026, 1, 1, 0, 5, 0, 0, loc), "2025-12-31"},
		// Leap-day boundary (2028 is a leap year).
		{"leap day", time.Date(2028, 3, 1, 0, 30, 0, 0, loc), "2028-02-29"},
	}
	for _, tc := range cases {
		if got := PriorDay(tc.now); got != tc.want {
			t.Errorf("%s: PriorDay(%v) = %q, want %q", tc.name, tc.now, got, tc.want)
		}
	}
}

func TestCurrentDay(t *testing.T) {
	loc, err := time.LoadLocation("Asia/Ho_Chi_Minh")
	if err != nil {
		t.Fatalf("load tz: %v", err)
	}
	// GL close seals TODAY's accounting day at the cutoff (post-cutoff postings
	// carry the next accounting date), so the date passed is the fire-day itself.
	now := time.Date(2026, 5, 30, 18, 0, 0, 0, loc)
	if got := CurrentDay(now); got != "2026-05-30" {
		t.Errorf("CurrentDay(%v) = %q, want %q", now, got, "2026-05-30")
	}
}
