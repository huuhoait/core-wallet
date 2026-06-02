# Web Portal Integration Specifications

Tài liệu này mô tả chi tiết đặc tả (specifications) để tích hợp Web Portal với Core Wallet Backend, đồng bộ theo Postman collection mới nhất (`services/wallet-service/postman/wallet-service.postman_collection.json`) và các route thực tế trong `internal/http/server.go`, dựa trên kiến trúc CQRS (Command Query Responsibility Segregation) của hệ thống.

> Phạm vi Core Wallet: chỉ posting nội bộ đồng bộ (top-up, transfer, withdraw, merchant settlement, fee/VAT, reversal) + onboarding/KYC client. Các rail bên ngoài (NAPAS, ngân hàng đối tác, 3DS) thuộc Treasury Service — Core chỉ nhận **callback trạng thái** qua nhóm endpoint `/v1/treasury/*`.

## 1. Nguyên tắc tích hợp chung (Architecture & CQRS)

Web Portal khi gọi xuống Core Wallet Backend cần tuân thủ các nguyên tắc thiết kế sau:

- **Write Path (Commands):** Các thao tác làm thay đổi dữ liệu (tạo ví, topup, transfer, khoá tài khoản, cập nhật client...) được gọi qua các hàm bọc trong `PgWalletRepo.withTx`. Request **bắt buộc** phải có thông tin Audit trên Header (xem 1.1) để trigger ghi log xuống Database.
- **Read Path (Queries):** Các thao tác chỉ đọc (list, xem chi tiết, số dư...) đi thẳng qua `pool.Query/QueryRow`, không bị bọc bởi Transaction (để tối ưu performance). Vẫn nên gửi đủ header audit để truy vết.
- **Idempotency:** Các endpoint xử lý tiền (`/v1/finance/*`) hỗ trợ Idempotency qua trường `reference` trong request body. Web Portal cần sinh một `reference` duy nhất cho mỗi giao dịch và **retry an toàn với đúng `reference` đó** nếu gặp timeout/5xx. Lần gọi trùng `reference` sẽ trả về kết quả của giao dịch gốc (HTTP 200 DUPLICATE) thay vì tạo bút toán mới.

### 1.1. Header chuẩn (Audit & Tracing) — BẮT BUỘC

Tất cả request (cả Write lẫn Read) cần gửi các header sau. Đây là tên header thực tế mà middleware (`internal/http/middleware/middleware.go`) đọc — **không** dùng `x-audit-actor` như tài liệu cũ:

| Header | Bắt buộc | Ý nghĩa | Ghi chú |
|--------|----------|---------|---------|
| `X-Caller-Subject` | ✅ (Write) | Actor thực hiện (user ID / service ID) → GUC `audit.actor` | Thiếu sẽ ghi `anonymous` |
| `X-Channel` | ✅ | Kênh phát sinh → GUC `audit.channel` | Một trong: `MOBILE`, `OPSUI`, `TREASURY`, `PARTNER`, `API`. Web Portal dùng `OPSUI`. |
| `X-Request-Id` | nên có | Request id để idempotency log & truy vết | Nếu trống, server tự sinh UUID và echo lại ở response header |
| `Content-Type` | ✅ (body) | `application/json` | |

> Trace id (`app.trace_id`) được lấy tự động từ OpenTelemetry span (W3C traceparent), không cần Portal tự gửi.

---

## 2. Chi tiết các luồng (Flows) tích hợp

### 2.1. Tạo ví (Open Account)
- **Mục đích:** Mở một tài khoản/ví mới cho khách hàng đã tồn tại (Client).
- **Endpoint:** `POST /v1/accounts`
- **CQRS Path:** Write (Command — `WalletRepository.OpenAccount`)
- **Request Body:**
  ```json
  {
    "client_no": "CLIENT_NUMBER",
    "acct_type": "CONSUMER"
  }
  ```
  `acct_type`: `CONSUMER` | `MERCHANT` | `SYSTEM`.
- **Xử lý trên Portal:** Nhận `acct_no` trả về để map vào hồ sơ người dùng. Số ví mỗi client bị giới hạn (count-limited) ở Backend.

### 2.2. Cập nhật trạng thái ví (Block / Close / Re-activate)
- **Mục đích:** Đổi trạng thái ví (Block để khoá, Close để đóng, Active để mở lại).
- **Endpoint:** `PATCH /v1/accounts/{acct_no}`
- **CQRS Path:** Write (Command — `WalletRepository.UpdateAccountStatus`)
- **Request Body:**
  ```json
  { "status": "B" }
  ```
  `status`: `A` = Active, `B` = Blocked, `C` = Closed.
- **Xử lý trên Portal:** Hiển thị warning/confirm cho admin khi block/close tài khoản.

### 2.3. Lấy danh sách ví của khách hàng (List Wallets)
> [!WARNING]
> Endpoint này **chưa có** trong Postman/Backend hiện tại — cần phát triển thêm.
- **Mục đích:** Lấy danh sách tất cả các ví của một `client_no`.
- **Endpoint đề xuất:** `GET /v1/clients/{client_no}/accounts`
- **CQRS Path:** Read (Query) — không bọc Transaction. Cần bổ sung method `ListClientAccounts` vào `usecase.WalletRepository`.
- **Xử lý trên Portal:** Hiển thị danh sách thẻ ví; click vào gọi API 2.4 lấy chi tiết.

### 2.4. Xem thông tin chi tiết ví (View Wallet Details)
- **Mục đích:** Lấy profile ví và số dư khả dụng.
- **Endpoint:**
  1. Profile: `GET /v1/accounts/{acct_no}` (`GetAccount` — không trả PII của client)
  2. Số dư realtime: `GET /v1/accounts/{acct_no}/balance` (`GetBalance`)
  3. Số dư tại một mốc thời gian: `GET /v1/accounts/{acct_no}/balance?as_of_date=YYYY-MM-DD` (`GetBalanceAsOf`)
- **CQRS Path:** Read (Query)
- **Xử lý trên Portal:** Có thể gọi song song profile + balance, hoặc dùng API ops/360 tổng hợp.

### 2.5. Số dư cho Ops (full) & truy vấn theo lô
- **Mục đích:** Màn hình vận hành cần số dư đầy đủ (gồm các thành phần như pledged/restraint) hoặc lấy số dư nhiều ví một lần.
- **Endpoint:**
  1. Full balance (privileged): `GET /v1/ops/accounts/{acct_no}/balance` (`GetBalanceOps`)
  2. Batch: `POST /v1/ops/accounts/balance/batch` (`GetBalanceBatch`)
     ```json
     { "acct_nos": ["ACCT_1", "ACCT_2", "ACCT_3"] }
     ```
- **CQRS Path:** Read (Query). Theo `BAL-05`, các API đọc số dư **không** ghi audit row.

### 2.6. Tạo giao dịch Topup (Nạp tiền)
- **Mục đích:** Bơm tiền từ hệ thống (Treasury/Nostro) vào ví người dùng.
- **Endpoint:** `POST /v1/finance/topup`
- **CQRS Path:** Write (Command — `WalletRepository.Topup`)
- **Header:** thực tế nguồn nạp đến từ Treasury (`X-Caller-Subject: treasury_svc`, `X-Channel: TREASURY`). Nếu Portal thao tác thủ công, dùng `X-Channel: OPSUI`.
- **Request Body:**
  ```json
  {
    "acct_no":   "ACCOUNT_NUMBER",
    "amount":    "5000000",
    "reference": "UNIQUE_REFERENCE_UUID",
    "narrative": "Nap tien tu Treasury",
    "metadata":  { "channel": "TREASURY", "partner_ref": "BANK-INGRESS-123" }
  }
  ```
  `amount` truyền dạng **chuỗi** (string) để tránh sai số floating point.
- **Xử lý trên Portal:** Sinh `reference` duy nhất cho mỗi giao dịch; retry với cùng `reference` khi gặp 5xx/timeout.

### 2.7. Chuyển khoản (Transfer)
- **Mục đích:** Chuyển tiền giữa hai ví (In-book Transfer).
- **Endpoint:** `POST /v1/finance/transfer`
- **CQRS Path:** Write (Command — `WalletRepository.Transfer`)
- **Request Body:**
  ```json
  {
    "from_acct_no": "SENDER_ACCT",
    "to_acct_no":   "RECEIVER_ACCT",
    "amount":       "100000",
    "reference":    "UNIQUE_REFERENCE_UUID",
    "tran_type":    "TRFOUT",
    "narrative":    "Chuyen tien dich vu",
    "metadata":     { "app_ver": "1.0.0", "device_fp_hash": "abc123", "geo_country": "VN" }
  }
  ```
  `tran_type`: `TRFOUT` (có phí) | `TRFOUTF` (miễn phí).

### 2.8. Rút tiền (Withdraw) & Rút tiền Merchant (Settlement)
- **Mục đích:** Rút tiền từ ví về tài khoản ngân hàng (qua Treasury), hoặc settlement/sweep cho merchant group.
- **Endpoint:**
  1. Rút thường: `POST /v1/finance/withdraw` (`WalletRepository.Withdraw`)
     ```json
     {
       "acct_no":          "ACCOUNT_NUMBER",
       "amount":           "200000",
       "reference":        "UNIQUE_REFERENCE_UUID",
       "ext_payout_ref":   "EXT_PAYOUT_REF",
       "narrative":        "Rut tien ve ngan hang",
       "beneficiary_bank": "BIDV",
       "beneficiary_acct": "12345678901234",
       "metadata":         { "app_ver": "1.0.0" }
     }
     ```
  2. Rút Merchant (settlement + hot-shard sweep): `POST /v1/finance/merchant-withdraw` (`WalletRepository.MerchantWithdraw`)
     ```json
     { "group_id": "GROUP_ID", "amount": "1000000", "reference": "UNIQUE_REFERENCE_UUID", "auto_sweep": true }
     ```
- **CQRS Path:** Write (Command)
- **Xử lý trên Portal:** Lệnh rút tạo bút toán giữ tiền + bản ghi `WLT_WITHDRAW_TRACK` ở trạng thái `SUBMITTED`; trạng thái cuối phụ thuộc callback từ Treasury (xem 2.13). Portal nên hiển thị trạng thái rút theo vòng đời này, không coi là hoàn tất ngay.

### 2.9. Hoàn giao dịch (Reverse Transfer / Reverse Topup)
- **Mục đích:** Hoàn (reversal) một giao dịch chuyển khoản hoặc một giao dịch topup đã thực hiện.
- **Endpoint:**
  1. Hoàn transfer: `POST /v1/finance/reverse` (`WalletRepository.ReverseTransfer`)
  2. Hoàn topup: `POST /v1/finance/topup/reverse` (`WalletRepository.ReverseTopup`)
- **CQRS Path:** Write (Command)
- **Request Body (cả hai):**
  ```json
  {
    "reference": "REFERENCE_CUA_GIAO_DICH_GOC",
    "reason":    "Ly do hoan",
    "initiator": "OPS_MANUAL"
  }
  ```
  `reference` = `reference` của **giao dịch gốc** cần hoàn. `initiator`: ví dụ `OPS_MANUAL` (admin hoàn thủ công), `TREASURY_FAILED` (hoàn tự động khi Treasury thất bại).

### 2.10. Thêm Restraint (Hold tiền / Phong toả)
- **Mục đích:** Đóng băng một khoản tiền (hoặc chiều ghi Nợ/Có) với mục đích nghiệp vụ.
- **Endpoint:** `POST /v1/finance/restraints`
- **CQRS Path:** Write (Command — `WalletRepository.AddRestraint`)
- **Request Body:**
  ```json
  {
    "acct_no":           "ACCOUNT_NUMBER",
    "restraint_type":    "DEBIT",
    "restraint_purpose": "DISPUTE_HOLD",
    "pledged_amt":       "50000",
    "narrative":         "Ly do hold tien"
  }
  ```
  - `restraint_type`: `DEBIT` | `CREDIT` | `BOTH`.
  - `restraint_purpose`: ví dụ `DISPUTE_HOLD`, `COURT_ORDER`.
  - `pledged_amt`: bắt buộc khi là hold theo số tiền.
- **Lưu ý ràng buộc:** một số tổ hợp `restraint_type`/`restraint_purpose` không hợp lệ và trả về **422** (ví dụ `COURT_ORDER` + `DEBIT`). Portal nên validate trước khi gửi.

### 2.11. Gỡ Restraint (Release Restraint)
- **Mục đích:** Mở khoá/gỡ một lệnh phong toả đã có.
- **Endpoint:** `POST /v1/finance/restraints/{restraint_id}/release`
- **CQRS Path:** Write (Command — `WalletRepository.ReleaseRestraint`)
- **Request Body:**
  ```json
  { "reason": "Ly do go phong toa" }
  ```

### 2.12. Danh sách & Chi tiết Restraint (List / Get Restraints)
- **Mục đích:** Liệt kê phong toả của một ví, hoặc xem chi tiết một lệnh phong toả.
- **Endpoint:**
  1. Danh sách: `GET /v1/finance/restraints?acct_no={acct_no}&limit=20` (hỗ trợ phân trang `before_seq`)
  2. Chi tiết: `GET /v1/finance/restraints/{restraint_id}`
- **CQRS Path:** Read (Query — `ListRestraints`, `GetRestraint`)
- **Xử lý trên Portal:** Hiển thị restraint đang active để admin xem chi tiết hoặc thực hiện luồng "Gỡ Restraint" (2.11).

### 2.13. Lịch sử & Chi tiết giao dịch (List / Get Transactions)
- **Mục đích:** Sao kê giao dịch của ví và xem chi tiết tất cả bút toán (legs) của một giao dịch.
- **Endpoint:**
  1. Danh sách (statement): `GET /v1/finance/transactions?acct_no={acct_no}&limit=20` (phân trang bằng `before_seq`)
  2. Chi tiết: `GET /v1/finance/transactions/{tran_key}` — trả về tất cả các leg (Nợ/Có/Phí/VAT) của một giao dịch.
- **CQRS Path:** Read (Query — `ListTransactions`, `GetTransaction`)
- **Lưu ý DB:** API danh sách query trên `WLT_TRAN_HIST` đã partition theo `POST_DATE` và hash theo `INTERNAL_KEY`. Để tận dụng partition pruning, nên giới hạn khoảng thời gian/phân trang; tránh kéo toàn bộ lịch sử (full scan).

### 2.14. Treasury Callbacks (vòng đời lệnh rút)
> Nhóm này do **Treasury Service** gọi vào Core (`X-Caller-Subject: treasury_svc`, `X-Channel: TREASURY`), **không** phải Web Portal gọi. Liệt kê ở đây để Portal hiểu trạng thái rút khi hiển thị.
- **Endpoint (theo `ext_payout_ref`):**
  1. `POST /v1/treasury/withdrawals/{ext_payout_ref}/acked` — `SUBMITTED → ACKED`, body `{ "treasury_batch_id": "..." }`
  2. `POST /v1/treasury/withdrawals/{ext_payout_ref}/disbursing` — `ACKED → DISBURSING`
  3. `POST /v1/treasury/withdrawals/{ext_payout_ref}/completed` — `{ACKED,DISBURSING} → COMPLETED`, body `{ "napas_ref": "..." }`
  4. `POST /v1/treasury/withdrawals/{ext_payout_ref}/reverse` — credit-back tự động khi Treasury thất bại/quá SLA, body `{ "fail_code": "...", "fail_reason": "...", "initiator": "TREASURY_FAILED" }`
- **Xử lý trên Portal:** Map trạng thái `WLT_WITHDRAW_TRACK` (`SUBMITTED`/`ACKED`/`DISBURSING`/`COMPLETED`/reversed) để hiển thị tiến trình rút cho admin.

---

## 3. Quản lý Khách hàng (Client) & Onboarding

### 3.1. Tạo client (Create Client)
- **Endpoint:** `POST /v1/clients`
- **CQRS Path:** Write (`CreateClient`)
- **Request Body (cá nhân — IND):**
  ```json
  {
    "client_name":    "Tran Thi B",
    "client_type":    "IND",
    "global_id":      "079xxxxxxxxx",
    "global_id_type": "CCCD",
    "surname":        "Tran",
    "given_name":     "Thi B",
    "birth_date":     "1992-03-04",
    "sex":            "F"
  }
  ```
  `client_type`: `IND` (cá nhân) | `MER` (merchant). Giá trị sai (vd `PERSON`) trả về **422**.

### 3.2. Cập nhật client (Update Client)
- **Endpoint:** `PATCH /v1/clients/{client_no}`
- **CQRS Path:** Write (`UpdateClient`)
- **Request Body:** chỉ gửi các field cần đổi, ví dụ:
  ```json
  { "client_name": "Tran Thi Bich", "given_name": "Thi Bich" }
  ```
- **Audit:** thay đổi hồ sơ định danh được ghi diff OLD→NEW vào client audit log (compliance US-8.x). Bắt buộc đi qua `withTx` (đủ header audit).

### 3.3. Xem hồ sơ client (Masked vs Unmasked)
- **Profile (PII masked):** `GET /v1/clients/{client_no}` (`GetClient`) — dùng cho UI thông thường.
- **Profile đầy đủ (UNMASKED, privileged):** `GET /v1/ops/clients/{client_no}` (`GetClientFull`) — yêu cầu quyền `wallet_pii_ro`; chỉ dùng cho màn hình ops được cấp quyền.
- **CQRS Path:** Read (Query)
- **Xử lý trên Portal:** Mặc định gọi bản masked; chỉ gọi bản unmasked khi user có quyền PII và có lý do nghiệp vụ (audit theo `X-Caller-Subject`).

### 3.4. eKYC (Submit / Update KYC)
- **Endpoint:** `POST /v1/clients/{client_no}/kyc` (`UpdateKYC`)
- **CQRS Path:** Write
- **Request Body:**
  ```json
  {
    "kyc_tier":         "2",
    "status":           "A",
    "risk_level":       "L",
    "ekyc_provider":    "VNPAY-eKYC",
    "ekyc_ref":         "EKYC-123",
    "face_match_score": 0.97,
    "liveness_result":  "PASS"
  }
  ```
- **Xử lý trên Portal:** Dùng để nâng tier KYC; thay đổi được audit qua trigger trên `WLT_CLIENT_KYC`.

### 3.5. Tài khoản ngân hàng liên kết (Link / Set Default Bank)
- **Liên kết bank:** `POST /v1/clients/{client_no}/banks` (`LinkClientBank`)
  ```json
  {
    "bank_code":        "970418",
    "acct_no":          "1903xxxxxxxx",
    "bank_name":        "BIDV",
    "acct_holder_name": "Tran Thi B",
    "is_default":       true
  }
  ```
- **Đặt mặc định:** `PUT /v1/clients/{client_no}/banks/{bank_link_id}/default` (`SetDefaultClientBank`, không body)
- **CQRS Path:** Write
> [!WARNING]
> Endpoint **liệt kê** bank của client (`GET /v1/clients/{client_no}/banks`) **chưa có** trong Postman/Backend — cần phát triển thêm để màn hình Client 360 (4.x) hiển thị danh sách bank.

### 3.6. Onboarding một bước (Onboard)
- **Mục đích:** Tạo client + mở ví trong một lệnh (luồng đăng ký nhanh).
- **Endpoint:** `POST /v1/onboard` (`Onboard`)
- **CQRS Path:** Write
- **Request Body (IND consumer):**
  ```json
  {
    "client_name": "Le Van C", "client_type": "IND", "phone": "09xxxxxxxx",
    "global_id": "079xxxxxxxxx", "global_id_type": "CCCD", "email": "c@demo.local",
    "acct_type": "CONSUMER", "ccy": "VND", "birthdate": "1990-01-15", "sex": "M"
  }
  ```
- **Request Body (MER merchant):**
  ```json
  {
    "client_name": "Coffee Shop LLC", "client_type": "MER", "phone": "09xxxxxxxx",
    "global_id": "031xxxxxxxxx", "global_id_type": "MST", "acct_type": "MERCHANT", "ccy": "VND",
    "extra_data": { "business_reg_no": "0312345678", "legal_rep": "Nguyen Van D" }
  }
  ```

### 3.7. Kích hoạt Hot Wallet cho Merchant Group
- **Endpoint:** `POST /v1/merchant-groups/{group_id}/activate` (`ActivateHotWallet`)
- **CQRS Path:** Write
- **Request Body:** `{ "shard_count": 4 }` — promote cold group → 4|8|16 shards.

### 3.8. Màn hình Client 360 (Client Details Dashboard)
- **Mục đích:** Khi admin click một Khách hàng từ "Danh sách Khách hàng", hiển thị góc nhìn 360 độ.
- **Các thành phần dữ liệu & API tương ứng:**
  1. **Profile:** `GET /v1/clients/{client_no}` (masked) hoặc `GET /v1/ops/clients/{client_no}` (unmasked, nếu có quyền). *(Đã có — tài liệu cũ ghi "chưa có" là không còn đúng.)*
  2. **Ví, Số dư & tiền phong toả:** danh sách ví qua `GET /v1/clients/{client_no}/accounts` (đề xuất ở 2.3 — **chưa có**), kết hợp `GET /v1/accounts/{acct_no}/balance` (hoặc ops full balance 2.5) để biết số dư + phần đang phong toả.
  3. **Bank liên kết:** `GET /v1/clients/{client_no}/banks` (**chưa có** — chỉ có POST/PUT).
  4. **Phong toả đang áp dụng:** `GET /v1/finance/restraints?acct_no=...` (2.12).
  5. **Link tra cứu giao dịch:** action button điều hướng sang màn Lịch sử giao dịch (2.13), truyền sẵn `acct_no`.
- **Kiến trúc đề xuất (BFF):** cân nhắc một API tổng hợp `GET /v1/portal/clients/{client_no}/360-view` (Read Query gộp nhiều bảng) để giảm số lần gọi API rời rạc.

---

## 4. Bảng tổng hợp Endpoint (theo Postman hiện tại)

| Nhóm | Method | Path | Repo method | CQRS |
|------|--------|------|-------------|------|
| Health | GET | `/healthz` | — | — |
| Clients | POST | `/v1/clients` | `CreateClient` | Write |
| Clients | PATCH | `/v1/clients/{client_no}` | `UpdateClient` | Write |
| Clients | GET | `/v1/clients/{client_no}` | `GetClient` (masked) | Read |
| Clients | POST | `/v1/clients/{client_no}/kyc` | `UpdateKYC` | Write |
| Clients | POST | `/v1/clients/{client_no}/banks` | `LinkClientBank` | Write |
| Clients | PUT | `/v1/clients/{client_no}/banks/{link_id}/default` | `SetDefaultClientBank` | Write |
| Ops | GET | `/v1/ops/clients/{client_no}` | `GetClientFull` (unmasked) | Read |
| Onboarding | POST | `/v1/onboard` | `Onboard` | Write |
| Finance | POST | `/v1/finance/topup` | `Topup` | Write |
| Finance | POST | `/v1/finance/transfer` | `Transfer` | Write |
| Finance | POST | `/v1/finance/withdraw` | `Withdraw` | Write |
| Finance | POST | `/v1/finance/merchant-withdraw` | `MerchantWithdraw` | Write |
| Finance | POST | `/v1/finance/reverse` | `ReverseTransfer` | Write |
| Finance | POST | `/v1/finance/topup/reverse` | `ReverseTopup` | Write |
| Finance | GET | `/v1/finance/transactions` | `ListTransactions` | Read |
| Finance | GET | `/v1/finance/transactions/{tran_key}` | `GetTransaction` | Read |
| Finance | POST | `/v1/finance/restraints` | `AddRestraint` | Write |
| Finance | GET | `/v1/finance/restraints` | `ListRestraints` | Read |
| Finance | GET | `/v1/finance/restraints/{id}` | `GetRestraint` | Read |
| Finance | POST | `/v1/finance/restraints/{id}/release` | `ReleaseRestraint` | Write |
| Accounts | POST | `/v1/accounts` | `OpenAccount` | Write |
| Accounts | PATCH | `/v1/accounts/{acct_no}` | `UpdateAccountStatus` | Write |
| Accounts | GET | `/v1/accounts/{acct_no}` | `GetAccount` | Read |
| Accounts | GET | `/v1/accounts/{acct_no}/balance` | `GetBalance` / `GetBalanceAsOf` | Read |
| Ops | GET | `/v1/ops/accounts/{acct_no}/balance` | `GetBalanceOps` | Read |
| Ops | POST | `/v1/ops/accounts/balance/batch` | `GetBalanceBatch` | Read |
| Merchant Groups | POST | `/v1/merchant-groups/{group_id}/activate` | `ActivateHotWallet` | Write |
| Treasury | POST | `/v1/treasury/withdrawals/{ext_payout_ref}/acked` | `MarkAcked` | Write |
| Treasury | POST | `/v1/treasury/withdrawals/{ext_payout_ref}/disbursing` | `MarkDisbursing` | Write |
| Treasury | POST | `/v1/treasury/withdrawals/{ext_payout_ref}/completed` | `MarkCompleted` | Write |
| Treasury | POST | `/v1/treasury/withdrawals/{ext_payout_ref}/reverse` | `Reverse` | Write |

**Endpoint còn thiếu (cần phát triển cho Portal):** `GET /v1/clients/{client_no}/accounts` (list ví), `GET /v1/clients/{client_no}/banks` (list bank), và BFF `GET /v1/portal/clients/{client_no}/360-view` (tuỳ chọn).

---

## 5. Luồng Duyệt Kép (Maker & Checker / 4-Eyes Principle)

Các thao tác nhạy cảm trên Web Portal (đặc biệt thay đổi số dư hoặc trạng thái ví/hồ sơ) bắt buộc qua duyệt kép để đảm bảo an toàn & tuân thủ. Core Wallet Backend là **Execution Engine** — không quản lý trạng thái pending của Maker/Checker; luồng này xử lý ở tầng Portal Backend (hoặc BFF).

### 5.1. Các luồng cần Approval

**Nhóm 1 — Tài chính & Trạng thái (rủi ro cao):**
- Topup: `POST /v1/finance/topup`
- Transfer / Reverse: `POST /v1/finance/transfer`, `POST /v1/finance/reverse`, `POST /v1/finance/topup/reverse`
- Withdraw / Merchant settlement: `POST /v1/finance/withdraw`, `POST /v1/finance/merchant-withdraw`
- Restraint: `POST /v1/finance/restraints`, `POST /v1/finance/restraints/{id}/release`
- Trạng thái ví: `PATCH /v1/accounts/{acct_no}` (Block/Close)

**Nhóm 2 — Hồ sơ Khách hàng (nhạy cảm):**
- Update client: `PATCH /v1/clients/{client_no}`
- KYC: `POST /v1/clients/{client_no}/kyc`
- Bank links: `POST /v1/clients/{client_no}/banks`, `PUT /.../default`
- Mở ví / Onboard: `POST /v1/accounts`, `POST /v1/onboard`
- Activate hot wallet: `POST /v1/merchant-groups/{group_id}/activate`

### 5.2. Workflow
1. **Khởi tạo (Maker):** Maker nhập thông tin trên Portal; Portal Backend lưu DB riêng với trạng thái `PENDING_APPROVAL`, **chưa** gọi Core Wallet.
2. **Kiểm duyệt (Checker):** User khác (khác user ID) xem lại và:
   - **Reject:** chuyển `REJECTED`, kết thúc.
   - **Approve:** Portal Backend gọi API thực thi xuống Core Wallet.
3. **Thực thi & Audit:** Khi gọi xuống Core, bắt buộc gửi header audit (mục 1.1):
   - `X-Caller-Subject`: User ID của **Checker** (người quyết định cuối) — hoặc ghép `Maker_ID/Checker_ID` tuỳ quy định.
   - `X-Channel: OPSUI`, `X-Request-Id`: id giao dịch trên Portal (phục vụ idempotency & truy vết).
   - Thành công → Core trả về `reference`/`tran_key`; Portal cập nhật `COMPLETED`.

### 5.3. Idempotency & Resilience
- Sau khi Checker duyệt, nếu gọi Core bị timeout, Portal phải retry **đúng `reference`** đã sinh trước đó (Core trả lại kết quả giao dịch gốc, không tạo bút toán mới).
- **Không** retry các lỗi nghiệp vụ (`400` validate, `404` không tìm thấy, `422` insufficient funds/conflict) — cập nhật trạng thái Portal thành `FAILED`. Chỉ retry lỗi tạm thời (`5xx`, timeout).
