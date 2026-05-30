# Báo cáo đối chiếu cột & thứ tự cột giữa 2 file DDL

> **✅ ĐÃ CHỐT (2026-05-30):** Giữ `db/ddl/wallet_schema.sql` làm source of truth duy nhất; `db/ddl/wallet_ddl.sql` đã **bị xoá** (không port lại bảng/cột nào). Tài liệu dưới đây giữ lại làm hồ sơ lý do quyết định — file `wallet_ddl.sql` không còn tồn tại.

**Ngày:** 2026-05-30
**Phạm vi:** `db/ddl/wallet_ddl.sql` (1525 dòng) vs `db/ddl/wallet_schema.sql` (1209 dòng)
**Nguồn thứ 3:** khối ERD mermaid trong comment đầu `wallet_ddl.sql` (dòng 72–391)
**Mục đích:** Phục vụ quyết định "sắp xếp số thứ tự cột cho chuẩn" + đồng bộ 2 file.

---

## 0. TL;DR

- Hai file **KHÔNG phải hai bản cùng schema lệch thứ tự cột** — chúng là **2 thế hệ schema khác nhau**, lệch cả về tập bảng, tập cột, kiểu dữ liệu, constraint và thiết kế PII.
- `wallet_schema.sql` là bản **thực sự chạy** (docker auto-load + test/loadtest chạy trên nó) → nên coi là **source of truth** khi giá trị mâu thuẫn.
- `wallet_ddl.sql` (được CLAUDE.md gọi "full DDL/ERD DDL") đã **drift**: vừa thừa (3 bảng + vài cột), vừa thiếu/sai (PII plaintext, `VARCHAR(6)` cho tran type, thiếu `NARRATIVE`...).
- **13/25 bảng chung có khác biệt**; **3 bảng chỉ có ở `wallet_ddl.sql`**; **12 bảng khớp cột hoàn toàn**.
- Khác biệt **thứ tự cột thuần túy** rất ít — phần lớn là khác **nội dung**. Vì vậy yêu cầu gốc ("kẻ lại số thứ tự cột") chỉ chạm bề mặt; phần nặng là quyết định thiết kế.

---

## 1. Khác biệt tập bảng

| Bảng | wallet_ddl.sql | wallet_schema.sql |
|---|:---:|:---:|
| `WLT_RECON_BREAK` | ✅ (1016) | ❌ thiếu |
| `WLT_API_TRACE` | ✅ (1060) | ❌ thiếu |
| `WLT_STMT_DETAIL` | ✅ (1168) | ❌ thiếu |

→ 3 bảng này trong `wallet_ddl.sql` được chú thích *"Referenced in ERD; DDL added here for completeness"* → nhiều khả năng là bảng **tài liệu, chưa triển khai runtime**.

---

## 2. Bảng KHỚP cột hoàn toàn (12 bảng — chỉ cần xét thứ tự, không đụng nội dung)

`FM_CLIENT_INDVL`, `FM_CLIENT_IDENTIFIERS`, `WLT_ACCT_TYPE`, `WLT_ACCT_GROUP`, `WLT_GL_BATCH`, `WLT_RESTRAINTS`, `WLT_SWEEP_LOG`, `WLT_GL_MAP`, `WLT_NOSTRO_LINK`, `WLT_API_MESSAGE`, `WLT_OUTBOX`, `WLT_WITHDRAW_TRACK`, `WLT_CLIENT_AUDIT_LOG`.

*(Lưu ý: một số bảng trên ở `wallet_schema.sql` có thêm CHECK constraint — vd `chk_gl_batch_status`, `chk_api_status` — nhưng tập cột & thứ tự cột trùng khớp.)*

---

## 3. Bảng KHÁC biệt cột (13 bảng)

Ký hiệu: `[ddl]` = chỉ có trong wallet_ddl.sql · `[sch]` = chỉ có trong wallet_schema.sql · `⚠️` = nhạy cảm/đáng chú ý.

### 3.1 `FM_CURRENCY`  (ddl 420 · sch 68)
- `[sch]` **STATUS** VARCHAR(4) NOT NULL DEFAULT 'A'
- `[sch]` thêm NOT NULL cho `CCY_DESC`, `DECI_PLACES`, `DAY_BASIS`.
- Thứ tự cột chung: **khớp**.

### 3.2 `FM_GL_MAST`  (ddl 432 · sch 79)
- `GL_TYPE`: `VARCHAR(4)` [ddl] vs `VARCHAR(12)` [sch]. → seed COA dùng 'NOSTRO'/'CASH' (≤6) nên **(12) đúng**.
- Cột & thứ tự: khớp. `[sch]` thêm `idx_fm_gl_type`.

### 3.3 `FM_CLIENT`  (ddl 447 · sch 93)
- `[ddl]` **MAJOR_CATEGORY** (462), **OWNERSHIP** (463)
- `[sch]` **CREATED_AT**, **UPDATED_AT** (111–112)
- Thứ tự cột chung: khớp (trừ 2 cột thừa mỗi bên).

### 3.4 `FM_CLIENT_CONTACT`  (ddl 508 · sch 146) — ⚠️ THIẾT KẾ KHÁC HẲN
| wallet_ddl.sql | wallet_schema.sql |
|---|---|
| PK `CONTACT_ID` (identity) | PK kép `(CLIENT_NO, CONTACT_TYPE)` |
| `CLIENT_NO, CONTACT_TYPE, CONTACT_VALUE, IS_PRIMARY, IS_VERIFIED, VERIFIED_AT, STATUS, CREATED_AT, UPDATED_AT` | `ADDR_LINE1, ADDR_LINE2, CITY, COUNTRY, PHONE_NO_ENC (BYTEA), EMAIL_ENC (BYTEA)` |
| Mục đích: danh sách liên hệ generic | Mục đích: địa chỉ + liên hệ mã hóa |
→ ✅ **CHỐT: giữ bản `wallet_schema.sql`** (địa chỉ + liên hệ mã hóa). PK `(CLIENT_NO, CONTACT_TYPE)`; cột `ADDR_LINE1, ADDR_LINE2, CITY, COUNTRY, PHONE_NO_ENC, EMAIL_ENC`. `wallet_ddl.sql` sửa lại theo bản này.

### 3.5 `FM_CLIENT_BANKS`  (ddl 530 · sch 160) — ⚠️ THIẾT KẾ KHÁC
| wallet_ddl.sql | wallet_schema.sql |
|---|---|
| PK `LINK_ID` (identity) | PK kép `(CLIENT_NO, SEQ_NO)` |
| `BANK_NAME, ACCT_HOLDER_NAME, IS_DEFAULT, CREATED_AT, UPDATED_AT` | `ACCT_NAME` (gộp), không có IS_DEFAULT |
| `ACCT_NO_ENC BYTEA` (cả 2 đều mã hóa) | `ACCT_NO_ENC BYTEA` |
→ ✅ **CHỐT: giữ bản `wallet_ddl.sql`** (surrogate `LINK_ID`), ý nghĩa "tài khoản ngân hàng liên kết", giữ `ACCT_NO_ENC` mã hóa.
**Cột canonical (thứ tự đã áp convention):**
```
LINK_ID (PK identity)
CLIENT_NO (FK), BANK_CODE
BANK_NAME, ACCT_NO_ENC, ACCT_HOLDER_NAME
IS_DEFAULT, STATUS
VERIFIED_AT, CREATED_AT, UPDATED_AT
```
→ `wallet_schema.sql` (đang là PK kép `(CLIENT_NO, SEQ_NO)` + `ACCT_NAME`) **đổi sang** thiết kế này; bổ sung `BANK_NAME`, `ACCT_HOLDER_NAME`, `IS_DEFAULT`, `CREATED_AT`, `UPDATED_AT`.

### 3.6 `FM_NOS_VOS`  (ddl 551 · sch 173)
- `[sch]` **STATUS** VARCHAR(4) NOT NULL DEFAULT 'A' (cuối bảng); thêm NOT NULL cho `ACCT_TYPE`, `CCY`.
- Thứ tự cột chung: khớp.

### 3.7 `WLT_CLIENT_KYC`  (ddl 574 · sch 193) — ⚠️ BẢO MẬT (PII)
| wallet_ddl.sql | wallet_schema.sql |
|---|---|
| `PHONE_NO VARCHAR(20) NOT NULL UNIQUE` (plaintext) | `PHONE_NO_ENC BYTEA` + `PHONE_NO_HASH BYTEA` (mã hóa + HMAC) |
| `EMAIL VARCHAR(120)` (plaintext) | `EMAIL_ENC BYTEA` |
| (không có UPDATED_AT) | `[sch]` **UPDATED_AT** |
→ Bản chạy dùng **mã hóa-at-rest**. Nếu lấy `wallet_ddl.sql` làm chuẩn sẽ **hạ cấp bảo mật** → KHÔNG nên. Chuẩn đúng = `wallet_schema.sql`.

### 3.8 `WLT_ACCT`  (ddl 643 · sch 253) — ⚠️ cột tài chính
- `[ddl]` **LEDGER_BAL** NUMERIC(18,2) (sau `ACTUAL_BAL`, dòng 651)
- `[ddl]` **BRANCH** VARCHAR(20) (664)
- `[sch]` constraint `chk_acct_status` (279) — ddl không có.
- Cột chung còn lại: thứ tự khớp.
- ❓ Câu hỏi nghiệp vụ: ledger này có dùng `LEDGER_BAL` tách khỏi `ACTUAL_BAL` không? Bản chạy hiện **không có** → cần xác nhận có phải bỏ hẳn hay thiếu sót.

### 3.9 `WLT_ACCT_BAL`  (ddl 695 · sch 466) — ⚠️ liên đới 3.8
- `[ddl]` **LEDGER_BAL** (699), **PREV_LEDGER_BAL** (702)
- `[sch]`: chỉ `ACTUAL_BAL, CALC_BAL, PREV_ACTUAL_BAL, PREV_CALC_BAL`.
- Quyết định phải đồng bộ với 3.8 (`WLT_ACCT.LEDGER_BAL`).

### 3.10 `WLT_TRAN_DEF`  (ddl 726 · sch 304) — độ dài kiểu
| Cột | ddl | sch |
|---|---|---|
| `TRAN_TYPE` | VARCHAR(6) | VARCHAR(10) |
| `CR_DR_MAINT_IND` | VARCHAR(2) | VARCHAR(4) |
| `REVERSAL_TRAN_TYPE` | VARCHAR(6) | VARCHAR(10) |
| `FEE_TRAN_TYPE` | VARCHAR(6) | VARCHAR(10) |
→ Tran type seed như `'MERCHWD'`,`'PAYMENT'` dài 7 ký tự ⇒ **VARCHAR(6) là LỖI**, (10) đúng. Cột/thứ tự khớp.

### 3.11 `WLT_TRAN_HIST`  (ddl 759 · sch 369)
- `[sch]` **NARRATIVE** VARCHAR(250) (389, sau `TRAN_DESC`) — ddl không có.
- `TRAN_TYPE` VARCHAR(6)[ddl] vs (10)[sch] (như 3.10).
- `[sch]` constraint `chk_hist_crdr`.
- Thứ tự cột chung: khớp.

### 3.12 `WLT_NOSTRO_BAL`  (ddl 1001 · sch 493)
- `[sch]` **CREATED_AT** (500) + constraint `chk_nb_st`.
- Cột/thứ tự còn lại khớp.

### 3.13 `WLT_NOSTRO_LINK`  (ddl 988 · sch 347) — chỉ khác constraint, **không khác cột**
- `PURPOSE`: ddl nullable DEFAULT 'TKDBTT' vs sch NOT NULL DEFAULT 'TKDBTT'. Cột/thứ tự khớp. *(Liệt kê để đầy đủ.)*

---

## 4. Convention thứ tự cột đề xuất (để "sắp xếp cho chuẩn")

Áp dụng nhất quán mọi bảng:

1. **Khóa chính** — surrogate identity (`*_ID`, `INTERNAL_KEY`) hoặc khóa tự nhiên; các cột của PK kép đứng liền nhau, đầu bảng.
2. **Khóa ngoại & định danh** — `CLIENT_NO`, `ACCT_TYPE`, `CCY`, `GL_CODE`, `GROUP_ID`, `REFERENCE`...
3. **Cột nghiệp vụ / số tiền / dữ liệu** — số dư, amount, mô tả, payload.
4. **Cột sinh (GENERATED)** — đặt **ngay sau** cột nguồn (vd `CALC_BAL` sau `ACTUAL_BAL`/`TOTAL_RESTRAINED_AMT`).
5. **Cờ & trạng thái** — `*_IND`, `*_BLOCKED`, `STATUS`, `VERSION`.
6. **Audit/thời gian (cuối bảng)** — `VERIFIED_AT`, `*_AT`, `CREATED_AT`, `UPDATED_AT`, `TIME_STAMP`.

**Lưu ý kỹ thuật khi reorder:**
- Đổi thứ tự *định nghĩa cột* KHÔNG đổi PK/partition key (PK liệt kê tên cột riêng) → an toàn về logic.
- Cột `GENERATED ... STORED` (vd `CALC_BAL`, `DIFF_AMT`) tham chiếu cột khác — PostgreSQL không bắt buộc thứ tự, nhưng vẫn nên đặt sau nguồn cho dễ đọc.
- ⚠️ Với bảng **đã có dữ liệu/production**, đổi thứ tự cột = phải `DROP/CREATE` hoặc dựng bảng mới + copy (Postgres không cho di chuyển ordinal_position tại chỗ). Trong repo này hai file là DDL khởi tạo nên chỉ là sửa text, **nhưng nếu DB đã chạy thật thì cần migration** — xem `db/migration/`.

---

## 5. Hiện trạng so với khối ERD mermaid (nguồn thứ 3)

Khối ERD (wallet_ddl.sql 72–391) chỉ liệt kê **tập cột rút gọn, minh họa**, thứ tự & số lượng cột **không khớp** cả hai bản DDL (vd `FM_CLIENT` ERD liệt kê 13 cột, DDL thật 17–19 cột; `WLT_CLIENT_KYC` ERD ghi `PHONE_NO` plaintext giống bản ddl, sai so với bản chạy mã hóa). → ERD cần cập nhật **sau khi** chốt schema chuẩn, không nên đồng bộ ngược.

---

## 6. Khuyến nghị (đánh giá kỹ thuật, không phải lệnh)

1. **Chọn `wallet_schema.sql` làm source of truth** — vì nó đang chạy, được test, và giữ thiết kế mã hóa PII đúng chuẩn ngân hàng.
2. **Sửa các lỗi rõ ràng ở `wallet_ddl.sql`** bất kể hướng nào: `VARCHAR(6)→(10)` cho tran type (mục 3.10/3.11).
3. **Cần bạn quyết (quyết định thiết kế, không tự suy ra được):**
   - (a) `LEDGER_BAL`/`PREV_LEDGER_BAL` (3.8/3.9): giữ hay bỏ? Ledger có cần tách ledger-balance khỏi actual-balance không?
   - (b) ✅ ĐÃ CHỐT — `FM_CLIENT_CONTACT` = bản schema (địa chỉ + mã hóa); `FM_CLIENT_BANKS` = bản ddl (`LINK_ID` + `BANK_NAME`/`ACCT_HOLDER_NAME` + `IS_DEFAULT`), giữ mã hóa.
   - (c) 3 bảng `WLT_RECON_BREAK`/`WLT_API_TRACE`/`WLT_STMT_DETAIL`: đưa vào runtime (thêm vào schema) hay coi là tài liệu (bỏ khỏi ddl)?
   - (d) `MAJOR_CATEGORY`/`OWNERSHIP` ở `FM_CLIENT` (3.3): giữ hay bỏ?
4. Sau khi chốt → áp convention mục 4 cho file chuẩn, regenerate file còn lại cho khớp 100%, rồi cập nhật khối ERD.

---

## 7. Cách kiểm chứng (gold-standard) sau khi sửa

Nạp mỗi file vào 1 database riêng rồi so `ordinal_position`:

```sql
-- so sánh thứ tự + kiểu cột giữa 2 DB
SELECT table_name, ordinal_position, column_name, data_type, character_maximum_length
FROM information_schema.columns
WHERE table_schema = 'public'
ORDER BY table_name, ordinal_position;
```

Diff hai kết quả phải rỗng cho các bảng cần đồng bộ.

---

## 8. Đề xuất thứ tự cột hợp lý theo từng bảng

Áp convention mục 4 (PK → FK/định danh → nghiệp vụ/số tiền → cột sinh → cờ/trạng thái → audit/thời gian).
Đánh giá dựa trên cột của bản chạy `wallet_schema.sql`.

**Kết luận tổng quát: phần lớn bảng đã được sắp xếp hợp lý sẵn** — chỉ `WLT_ACCT` thực sự đáng sắp lại; số còn lại chỉ là tinh chỉnh tùy chọn. Không nên xáo trộn các bảng đã tốt (gây nhiễu diff + rủi ro migration).

### 8.1 Bảng ĐÃ hợp lý — giữ nguyên (19 bảng)

`FM_CURRENCY`, `FM_GL_MAST`, `FM_CLIENT`, `FM_CLIENT_INDVL`, `FM_NOS_VOS`, `WLT_CLIENT_KYC`, `WLT_ACCT_TYPE`, `WLT_ACCT_GROUP`, `WLT_ACCT_BAL`, `WLT_GL_BATCH`, `WLT_RESTRAINTS`, `WLT_SWEEP_LOG`, `WLT_GL_MAP`, `WLT_NOSTRO_BAL`, `WLT_API_MESSAGE`, `WLT_WITHDRAW_TRACK`, `WLT_CLIENT_AUDIT_LOG`, + 3 bảng ddl-only (`WLT_RECON_BREAK`, `WLT_API_TRACE`, `WLT_STMT_DETAIL`).

→ PK đầu bảng, audit/timestamp cuối bảng, các khối nghiệp vụ gom hợp lý theo tính năng (vd state-machine của `WLT_WITHDRAW_TRACK`, khối WHO/WHAT/WHERE của `WLT_CLIENT_AUDIT_LOG`, khối relay-state của `WLT_OUTBOX`).

### 8.2 Bảng NÊN sắp lại — `WLT_ACCT` (đáng làm)

Vấn đề hiện tại: `ACCT_STATUS` (cờ) nằm ngay sau định danh; khối số dư / cờ / thời gian xen kẽ nhau; nhóm sharding (`GROUP_ID/SHARD_INDEX/ACCT_ROLE`) bị tách rời ở cuối.

**Hiện tại** (sch, 18 cột):
```
INTERNAL_KEY, ACCT_NO, CLIENT_NO, ACCT_TYPE, CCY, ACCT_STATUS,
ACTUAL_BAL, TOTAL_RESTRAINED_AMT, CALC_BAL, PREV_DAY_ACTUAL_BAL,
ACCT_OPEN_DATE, LAST_TRAN_DATE, RESTRAINT_PRESENT, CR_BLOCKED, VERSION,
GROUP_ID, SHARD_INDEX, ACCT_ROLE
```

**Đề xuất** (gom theo convention; `[LEDGER_BAL]`/`[BRANCH]` tùy quyết định 6a/6.x):
```
-- PK
INTERNAL_KEY
-- Định danh / FK
ACCT_NO, CLIENT_NO, ACCT_TYPE, CCY, [BRANCH]
-- Sharding (gom 1 khối)
GROUP_ID, SHARD_INDEX, ACCT_ROLE
-- Số dư (cột sinh CALC_BAL ngay sau nguồn)
ACTUAL_BAL, [LEDGER_BAL], TOTAL_RESTRAINED_AMT, CALC_BAL, PREV_DAY_ACTUAL_BAL
-- Cờ / trạng thái
ACCT_STATUS, RESTRAINT_PRESENT, CR_BLOCKED, VERSION
-- Thời gian
ACCT_OPEN_DATE, LAST_TRAN_DATE
```
Lợi ích: 3 nhóm rõ ràng (định danh → số dư → cờ → thời gian), `CALC_BAL` đứng cạnh nguồn, sharding gom 1 chỗ.
Đánh đổi: đẩy `GROUP_ID/SHARD_INDEX/ACCT_ROLE` lên trên sẽ bỏ comment-block "sharding ở cuối" mà tác giả cố ý đặt — nếu thích giữ nhóm tính năng cuối bảng thì để nguyên 3 cột đó ở cuối, vẫn chấp nhận được.

### 8.3 Bảng tinh chỉnh tùy chọn (lợi ích nhỏ — chỉ làm nếu muốn tuyệt đối nhất quán)

| Bảng | Hiện tại | Gợi ý nhỏ |
|---|---|---|
| `FM_CLIENT_IDENTIFIERS` | `IS_CURRENT` (cờ) đứng trước `NATIONALITY` | đưa `IS_CURRENT` xuống sau `NATIONALITY` |
| `WLT_TRAN_HIST` | `CCY` nằm khá xa khối định danh đầu | đưa `CCY` lên gần `TRAN_TYPE` |
| `WLT_NOSTRO_LINK` | `STATUS` đứng trước `LAST_RECON_DATE/BAL` | đưa `STATUS` xuống ngay trước/sau khối recon |
| `WLT_TRAN_DEF` | `STATUS` nằm giữa, trước khối `FEE_*` | giữ nguyên (khối FEE là cấu hình liền mạch — đổi gây rối hơn) |

### 8.4 `FM_CLIENT_CONTACT` & `FM_CLIENT_BANKS` — ✅ đã chốt thiết kế (mục 3.4/3.5)

**FM_CLIENT_CONTACT** (canonical = bản schema):
```
CLIENT_NO, CONTACT_TYPE (PK kép)
ADDR_LINE1, ADDR_LINE2, CITY, COUNTRY
PHONE_NO_ENC, EMAIL_ENC
```

**FM_CLIENT_BANKS** (canonical = bản ddl + IS_DEFAULT):
```
LINK_ID (PK)
CLIENT_NO, BANK_CODE
BANK_NAME, ACCT_NO_ENC, ACCT_HOLDER_NAME
IS_DEFAULT, STATUS
VERIFIED_AT, CREATED_AT, UPDATED_AT
```

### 8.5 Lưu ý thực thi

- Đây là DDL khởi tạo → sắp lại chỉ là sửa text trong `CREATE TABLE`, an toàn về logic (PK/partition key liệt kê tên cột riêng, không phụ thuộc ordinal).
- ⚠️ Nếu DB đã chạy production, PostgreSQL **không** đổi `ordinal_position` tại chỗ → phải qua migration (bảng mới + copy, hoặc chấp nhận thứ tự cũ). Xem `db/migration/`. Với nhu cầu "đẹp file DDL" thì không cần động vào DB đang chạy.
