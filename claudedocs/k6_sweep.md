# k6 Load-Test Sweep — kết quả so sánh theo PEAK

- Generated: 2026-05-30 09:06:48
- Endpoint: `http://localhost:8099`  | Mỗi đợt: ramp 90s (10→50→PEAK giữ→0), VU 150/600
- Mix: topup 18% / transfer 18% / withdraw 12% / balance 10% / merchant-withdraw 12% / +reversal (transfer 12% · topup 10% · withdraw 8%)

| Metric | PEAK=100 | PEAK=200 | PEAK=300 | PEAK=400 | PEAK=500 | PEAK=600 | PEAK=700 |
|:--|--:|--:|--:|--:|--:|--:|--:|
| Throughput đạt (req/s) | 78 | 135 | 193 | 249 | 308 | 366 | 425 |
| Iterations/s | 59 | 104 | 148 | 193 | 237 | 282 | 326 |
| Latency p95 (ms) | 10.08 | 12.55 | 7.02 | 6.18 | 6.32 | 8.23 | 23.14 |
| Latency p90 (ms) | 7.34 | 7.49 | 4.78 | 4.33 | 4.09 | 4.36 | 7.52 |
| Latency max (ms) | 97.2 | 503.68 | 199.57 | 168.21 | 202.03 | 312.31 | 241.67 |
| Checks pass (%) | 99.99 | 100 | 100 | 100 | 99.99 | 99.99 | 100 |
| HTTP failed (%) | 0.01 | 0 | 0 | 0 | 0.01 | 0.01 | 0 |
| Dropped iterations | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| VUs max allocated | 150 | 150 | 150 | 150 | 150 | 150 | 150 |
| SUCCESS | 4841 | 8407 | 12090 | 15616 | 19259 | 22862 | 26320 |
| REVERSED | 1637 | 2801 | 4039 | 5049 | 6333 | 7614 | 8890 |
| BALANCE_OK | 507 | 942 | 1259 | 1734 | 2088 | 2483 | 3029 |
| VERSION_CONFLICT (409) | 0 | 0 | 0 | 0 | 1 | 1 | 0 |
| VERSION_CONFLICT_FROM (500) | 0 | 0 | 0 | 0 | 1 | 0 | 0 |
| VERSION_CONFLICT_TO (500) | 1 | 0 | 0 | 0 | 1 | 3 | 0 |
| WLT_TRAN_HIST rows phát sinh | 13032 | 22767 | 32574 | 41966 | 51836 | 62336 | 71723 |

> Ghi chú: `req/s` là trung bình toàn ramp 90s (PEAK chỉ giữ ~50s), nên < PEAK là bình thường.
> `dropped` > 0 hoặc `p95` tăng vọt ⇒ điểm bắt đầu bão hoà. `*_FROM/_TO` (HTTP 500) là xung đột phiên bản chưa map về 409.
