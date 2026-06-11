package domain

import "time"

// Suspense/clearing GL framework (US-6.2). Read model for the suspense aging
// report (fn_suspense_aging) — per 109.x GL/ccy, the net open balance bucketed
// by age. Decimal amounts are decimal strings (scanned ::text) to avoid float.

// SuspenseAgingRow is one (GL, ccy) line of the suspense aging report.
type SuspenseAgingRow struct {
	GLCode         string
	GLDesc         string
	Ccy            string
	NetBalance     string // ΣCR − ΣDR (CR-positive)
	Bucket0_30     string
	Bucket31_60    string
	Bucket61_90    string
	Bucket90Plus   string
	OldestPostDate time.Time
}
