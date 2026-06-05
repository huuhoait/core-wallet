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
| `Authorization` | ✅ khi `JWT_ENABLED=true` | Bearer JWT của user/service Portal | Subject trong token override `X-Caller-Subject`; channel có thể đặt qua claim (`ChannelClaim`). |
| `X-Caller-Subject` | ✅ (Write, nếu không có JWT) | Actor thực hiện (user ID / service ID) → GUC `audit.actor` | Thiếu sẽ ghi `anonymous` |
| `X-Channel` | ✅ | Kênh phát sinh → GUC `audit.channel` | Một trong: `MOBILE`, `OPSUI`, `TREASURY`, `PARTNER`, `API`. Web Portal dùng `OPSUI`. |
| `X-Request-Id` | nên có | Request id để idempotency log & truy vết | Nếu trống, server tự sinh UUID và echo lại ở response header |
| `Content-Type` | ✅ (body) | `application/json` | |

> Trace id (`app.trace_id`) được lấy tự động từ OpenTelemetry span (W3C traceparent), không cần Portal tự gửi.

### 1.2. RBAC — Role bắt buộc theo nhóm endpoint (US-9.10)

Khi `JWT_ENABLED=true`, server validate role claim (`RolesClaim`, mặc định `roles` hoặc `realm_access.roles`) và chặn các nhóm endpoint nhạy cảm. Portal Backend phải mint/exchange token với đúng role tuỳ thao tác:

| Role | Áp dụng cho | Mô tả |
|------|-------------|-------|
| `wallet.finance.reverse` | `POST /v1/finance/reverse`, `/topup/reverse`, `/merchant-withdraw/reverse`, `/fee-charge/reverse` | Quyền hoàn giao dịch (ops-only) |
| `wallet.ops.read` | `GET /v1/ops/accounts/*`, `POST /v1/ops/accounts/balance/batch`, `GET /v1/ops/clients/{client_no}` | Đọc số dư full + hồ sơ client UNMASKED |
| `wallet.treasury` | `POST /v1/treasury/withdrawals/*` | Service-to-service callback từ Treasury Service |

Lưu ý quan trọng:
- Người dùng Portal thường (Maker/Checker thông thường) chỉ cần token user account, **không** kèm các role trên.
- Màn hình ops xem PII đầy đủ hoặc reversal phải dùng token chứa role tương ứng (cấp theo người, đi qua duyệt kép, audit qua `X-Caller-Subject`).
- Treasury callback (`/v1/treasury/*`) **không** gọi từ Portal — chỉ Treasury Service S2S mới mang `wallet.treasury`.

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
  3. Số dư tại một mốc thời gian: `GET /v1/accounts/{acct_no}/balance?as_of_date=YYYY-MM-DD` (cùng handler `GetBalance`, route theo query param sang `GetBalanceAsOf` ở repo)
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
- **Xử lý trên Portal:** Lệnh rút tạo bút toán giữ tiền + bản ghi `WLT_WITHDRAW_TRACK` ở trạng thái `SUBMITTED`; trạng thái cuối phụ thuộc callback từ Treasury (xem 2.14). Portal nên hiển thị trạng thái rút theo vòng đời này, không coi là hoàn tất ngay.

### 2.8a. Nạp tiền Merchant (Merchant Deposit — route deposit→shard/settlement)
- **Mục đích:** Nhận tiền vào ví của một merchant group. Backend tự động định tuyến: group **cold** → ghi thẳng vào ví settlement; group **hot** → chọn shard theo lookup-hash để phân tải, scheduler sau đó sweep về settlement.
- **Endpoint:** `POST /v1/finance/merchant-deposit` (`WalletRepository.MerchantDeposit`)
- **CQRS Path:** Write (Command)
- **Request Body:**
  ```json
  {
    "group_id":  "GROUP_ID",
    "amount":    "500000",
    "reference": "UNIQUE_REFERENCE_UUID",
    "narrative": "Khach hang thanh toan merchant"
  }
  ```
- **Xử lý trên Portal:** Portal hiếm khi tự gọi (deposit thường đến từ kênh thanh toán). Khi cần điều chỉnh thủ công bởi ops, dùng `X-Channel: OPSUI` và sinh `reference` duy nhất.

### 2.8b. Thu phí độc lập (Fee Charge / Reverse Fee — US-2.8)
- **Mục đích:** Ghi nợ một khoản phí + VAT độc lập (không gắn liền với một transfer/withdraw cụ thể). Dùng cho phí dịch vụ, phí định kỳ, hoặc chỉnh sửa thủ công.
- **Endpoint:**
  1. Thu phí: `POST /v1/finance/fee-charge` (`WalletRepository.FeeCharge`)
     ```json
     {
       "acct_no":   "ACCOUNT_NUMBER",
       "amount":    "10000",
       "fee_code":  "FEETRF",
       "reference": "UNIQUE_REFERENCE_UUID",
       "narrative": "Service fee charge"
     }
     ```
     `fee_code`: mã phí định nghĩa trong `WLT_TRAN_DEF` (vd `FEETRF`, `FEEMTH`...). VAT tự tính theo cấu hình.
  2. Hoàn phí: `POST /v1/finance/fee-charge/reverse` (`WalletRepository.ReverseFeeCharge`, role `wallet.finance.reverse`)
     ```json
     { "reference": "REFERENCE_CUA_LENH_FEE_GOC", "reason": "Fee reversal - customer goodwill", "initiator": "OPS_MANUAL" }
     ```
- **CQRS Path:** Write (Command)

### 2.9. Hoàn giao dịch (Reversals — RBAC: `wallet.finance.reverse`)
- **Mục đích:** Hoàn (reversal) một giao dịch đã thực hiện. **Toàn bộ nhóm reversal là ops-only** — JWT phải mang role `wallet.finance.reverse`.
- **Endpoint:**
  1. Hoàn transfer (in-book): `POST /v1/finance/reverse` (`WalletRepository.ReverseTransfer`)
  2. Hoàn topup: `POST /v1/finance/topup/reverse` (`WalletRepository.ReverseTopup`)
  3. Hoàn merchant-withdraw (credit-back principal + fee/VAT về settlement): `POST /v1/finance/merchant-withdraw/reverse` (`WalletRepository.ReverseMerchantWithdraw`)
  4. Hoàn fee-charge: `POST /v1/finance/fee-charge/reverse` (`WalletRepository.ReverseFeeCharge`)
- **CQRS Path:** Write (Command)
- **Request Body (chuẩn cho mọi reverse):**
  ```json
  {
    "reference": "REFERENCE_CUA_GIAO_DICH_GOC",
    "reason":    "Ly do hoan",
    "initiator": "OPS_MANUAL"
  }
  ```
  Riêng `merchant-withdraw/reverse` chấp nhận thêm `fail_code`, `fail_reason` (để gắn lý do Treasury failure):
  ```json
  {
    "reference":   "REFERENCE_CUA_MERCHANT_WITHDRAW_GOC",
    "fail_code":   "NAPAS_TIMEOUT",
    "fail_reason": "Disbursement timed out at NAPAS gateway",
    "initiator":   "OPS_MANUAL"
  }
  ```
  `reference` = `reference` của **giao dịch gốc** cần hoàn. `initiator`: ví dụ `OPS_MANUAL` (admin hoàn thủ công), `TREASURY_FAILED` (hoàn tự động khi Treasury thất bại — thường do Treasury Service gọi `/v1/treasury/withdrawals/{ext_payout_ref}/reverse` thay vì Portal).

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
- **Xử lý trên Portal:** Dùng để nâng tier KYC; thay đổi được audit qua trigger trên `FM_CLIENT_KYC`.

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

### 3.6a. Quy trình onboarding từng bước — Tạo Client → Mở Ví → KYC

> Khác với one-step `POST /v1/onboard` (§3.6) gói cả 3 trong **một transaction nguyên tử**, luồng từng bước dưới đây là **3 lệnh Write độc lập** (3 TX riêng). Dùng khi cần tách trách nhiệm (vd KYC do bộ phận khác duyệt sau), hoặc khi client đã tồn tại và chỉ mở thêm ví. Đánh đổi: **không nguyên tử** — phải xử lý lỗi từng phần (xem cuối mục).

**Tiền đề:** cả 3 bước là Write → gửi đủ header audit §1.1 (`X-Caller-Subject`, `X-Channel: OPSUI`, `X-Request-Id`). Đều thuộc nhóm cần duyệt kép §5 (Maker/Checker). Token user thường là đủ — **không** cần role đặc biệt.

#### Bước 1 — Tạo Client (`POST /v1/clients`, Write `CreateClient`)
Tạo hồ sơ khách hàng (`FM_CLIENT`) + bản ghi KYC khởi tạo (`FM_CLIENT_KYC`, tier `0`).
- Request (cá nhân IND):
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
  `client_type`: `IND` | `CORP` | `MER` (sai → **422** `INVALID_CLIENT_TYPE`). `sex`: `M|F|O`. `birth_date`: `YYYY-MM-DD`.
- Response → **giữ lại `client_no`** cho bước 2 & 3:
  ```json
  { "client_no": "C00000123", "status": "A", "timestamp": "2026-06-05T10:00:00Z" }
  ```

#### Bước 2 — Mở Ví (`POST /v1/accounts`, Write `OpenAccount`)
Mở ví đầu tiên cho client vừa tạo (số ví/client bị count-limited ở Backend).
- Request:
  ```json
  { "client_no": "C00000123", "acct_type": "CONSUMER", "ccy": "VND" }
  ```
  `acct_type`: `CONSUMER` | `MERCHANT` | `SYSTEM`. `ccy` mặc định `VND` nếu bỏ trống.
- Response → **giữ lại `acct_no`**:
  ```json
  { "acct_no": "0900000123", "client_no": "C00000123", "acct_type": "CONSUMER", "ccy": "VND", "acct_status": "A" }
  ```

#### Bước 3 — KYC (`POST /v1/clients/{client_no}/kyc`, Write `UpdateKYC`)
Nâng tier & gắn kết quả eKYC. Đạt `kyc_tier >= 2` sẽ đóng dấu `verified_at`. Thay đổi được audit qua trigger trên `FM_CLIENT_KYC`.
- Request:
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
  `kyc_tier`: `0|1|2|3`; `status`: `A|B|C|P`; `face_match_score`: `0..1`.
- Response:
  ```json
  { "client_no": "C00000123", "kyc_tier": "2", "status": "A", "risk_level": "L", "verified_at": "2026-06-05T10:01:00Z" }
  ```

#### Tóm tắt thứ tự & dữ liệu mang theo

| Bước | Endpoint | Mang vào | Trả ra (giữ lại) | Bảng DB |
|------|----------|----------|------------------|---------|
| 1 | `POST /v1/clients` | hồ sơ định danh | `client_no` | `FM_CLIENT` (+ `FM_CLIENT_KYC` tier 0) |
| 2 | `POST /v1/accounts` | `client_no` | `acct_no` | `WLT_ACCT` (+ `WLT_ACCT_BAL`) |
| 3 | `POST /v1/clients/{client_no}/kyc` | `client_no` | `kyc_tier`, `verified_at` | `FM_CLIENT_KYC` |

#### Xử lý lỗi từng phần (vì KHÔNG nguyên tử)
3 bước là 3 TX độc lập → có thể rơi vào "client đã tạo nhưng mở ví lỗi", hoặc "ví xong nhưng KYC lỗi". Portal Backend cần:
- **Bước 1 lỗi** (`422` `client_type` sai / trùng `global_id`) → dừng, báo Maker; chưa tạo gì ở bước 2–3.
- **Bước 2 lỗi** sau khi bước 1 OK → `client_no` đã tồn tại; **retry riêng bước 2** với cùng `client_no` (không tạo lại client). Vượt giới hạn số ví → báo lỗi nghiệp vụ, không retry.
- **Bước 3 lỗi** sau khi 1+2 OK → client + ví đã sống nhưng tier vẫn `0`; **retry riêng bước 3**. Client tier-0 thường bị giới hạn hạn mức tới khi KYC đạt tier ≥ 2.
- Không có rollback xuyên bước → **lưu state máy ở Portal** (giống Maker/Checker §5) để biết đã tới bước nào và retry đúng bước dang dở. Chỉ retry lỗi tạm thời (`5xx`/timeout); lỗi nghiệp vụ (`400/404/422`) thì chuyển `FAILED` (xem §5.3).
- **Khi nào dùng one-step §3.6 thay thế:** cần "tất-cả-hoặc-không" (đăng ký nhanh, không tách KYC) → gọi `POST /v1/onboard` để Core làm cả 3 trong 1 TX, tránh hẳn trạng thái dở dang.

### 3.7. Vòng đời Merchant Group (Provision → Activate → Rescale)
Merchant group có 3 mốc lifecycle, mỗi mốc là một endpoint riêng:

1. **Provision (cold)** — tạo group + ví settlement, vẫn cold (chưa shard):
   - `POST /v1/merchant-groups` (`ProvisionAcctGroup`, US-1.10)
   - Body:
     ```json
     {
       "group_id":   "MG-TEST-001",
       "client_no":  "CLIENT_NUMBER",
       "group_type": "MERCHANT",
       "acct_type":  "MERCHANT"
     }
     ```
2. **Activate (cold → hot)** — promote cold group sang hot với 4|8|16 shard ví:
   - `POST /v1/merchant-groups/{group_id}/activate` (`ActivateHotWallet`, US-1.9)
   - Body: `{ "shard_count": 4 }`
3. **Rescale (hot tier expansion)** — mở rộng số shard (4→8 hoặc 8→16) + rebalance:
   - `POST /v1/merchant-groups/{group_id}/rescale` (`RescaleHotWallet`, US-1.12)
   - Body: `{ "new_shard_count": 8 }`

- **CQRS Path:** Write (Command) cho cả 3
- **Xử lý trên Portal:** Provision là thao tác setup ban đầu (ops/onboarding). Activate/Rescale ảnh hưởng đến routing deposit/withdraw merchant — bắt buộc qua duyệt kép (xem mục 5).

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
| Finance | POST | `/v1/finance/merchant-deposit` | `MerchantDeposit` | Write |
| Finance | POST | `/v1/finance/merchant-withdraw` | `MerchantWithdraw` | Write |
| Finance | POST | `/v1/finance/fee-charge` | `FeeCharge` | Write |
| Finance | POST | `/v1/finance/reverse` *(role `wallet.finance.reverse`)* | `ReverseTransfer` | Write |
| Finance | POST | `/v1/finance/topup/reverse` *(role `wallet.finance.reverse`)* | `ReverseTopup` | Write |
| Finance | POST | `/v1/finance/merchant-withdraw/reverse` *(role `wallet.finance.reverse`)* | `ReverseMerchantWithdraw` | Write |
| Finance | POST | `/v1/finance/fee-charge/reverse` *(role `wallet.finance.reverse`)* | `ReverseFeeCharge` | Write |
| Finance | GET | `/v1/finance/transactions` | `ListTransactions` | Read |
| Finance | GET | `/v1/finance/transactions/{tran_key}` | `GetTransaction` | Read |
| Finance | POST | `/v1/finance/restraints` | `AddRestraint` | Write |
| Finance | GET | `/v1/finance/restraints` | `ListRestraints` | Read |
| Finance | GET | `/v1/finance/restraints/{id}` | `GetRestraint` | Read |
| Finance | POST | `/v1/finance/restraints/{id}/release` | `ReleaseRestraint` | Write |
| Accounts | POST | `/v1/accounts` | `OpenAccount` | Write |
| Accounts | PATCH | `/v1/accounts/{acct_no}` | `UpdateAccountStatus` | Write |
| Accounts | GET | `/v1/accounts/{acct_no}` | `GetAccount` | Read |
| Accounts | GET | `/v1/accounts/{acct_no}/balance` | `GetBalance` (+ `?as_of_date=` → `GetBalanceAsOf`) | Read |
| Ops | GET | `/v1/ops/accounts/{acct_no}/balance` *(role `wallet.ops.read`)* | `GetBalanceOps` | Read |
| Ops | POST | `/v1/ops/accounts/balance/batch` *(role `wallet.ops.read`)* | `GetBalanceBatch` | Read |
| Merchant Groups | POST | `/v1/merchant-groups` | `ProvisionAcctGroup` | Write |
| Merchant Groups | POST | `/v1/merchant-groups/{group_id}/activate` | `ActivateHotWallet` | Write |
| Merchant Groups | POST | `/v1/merchant-groups/{group_id}/rescale` | `RescaleHotWallet` | Write |
| Treasury | POST | `/v1/treasury/withdrawals/{ext_payout_ref}/acked` *(role `wallet.treasury`)* | `MarkAcked` | Write |
| Treasury | POST | `/v1/treasury/withdrawals/{ext_payout_ref}/disbursing` *(role `wallet.treasury`)* | `MarkDisbursing` | Write |
| Treasury | POST | `/v1/treasury/withdrawals/{ext_payout_ref}/completed` *(role `wallet.treasury`)* | `MarkCompleted` | Write |
| Treasury | POST | `/v1/treasury/withdrawals/{ext_payout_ref}/reverse` *(role `wallet.treasury`)* | `Reverse` | Write |

**Endpoint còn thiếu (cần phát triển cho Portal):** `GET /v1/clients/{client_no}/accounts` (list ví), `GET /v1/clients/{client_no}/banks` (list bank), và BFF `GET /v1/portal/clients/{client_no}/360-view` (tuỳ chọn).

---

## 5. Luồng Duyệt Kép (Maker & Checker / 4-Eyes Principle)

Các thao tác nhạy cảm trên Web Portal (đặc biệt thay đổi số dư hoặc trạng thái ví/hồ sơ) bắt buộc qua duyệt kép để đảm bảo an toàn & tuân thủ. Core Wallet Backend là **Execution Engine** — không quản lý trạng thái pending của Maker/Checker; luồng này xử lý ở tầng Portal Backend (hoặc BFF).

### 5.1. Các luồng cần Approval

**Nhóm 1 — Tài chính & Trạng thái (rủi ro cao):**
- Topup: `POST /v1/finance/topup`
- Transfer & Reversal: `POST /v1/finance/transfer`, `POST /v1/finance/reverse`, `POST /v1/finance/topup/reverse`
- Withdraw & Merchant settlement: `POST /v1/finance/withdraw`, `POST /v1/finance/merchant-withdraw`, `POST /v1/finance/merchant-withdraw/reverse`
- Merchant deposit (thủ công bởi ops): `POST /v1/finance/merchant-deposit`
- Fee charge & reverse: `POST /v1/finance/fee-charge`, `POST /v1/finance/fee-charge/reverse`
- Restraint: `POST /v1/finance/restraints`, `POST /v1/finance/restraints/{id}/release`
- Trạng thái ví: `PATCH /v1/accounts/{acct_no}` (Block/Close)

**Nhóm 2 — Hồ sơ Khách hàng (nhạy cảm):**
- Update client: `PATCH /v1/clients/{client_no}`
- KYC: `POST /v1/clients/{client_no}/kyc`
- Bank links: `POST /v1/clients/{client_no}/banks`, `PUT /.../default`
- Mở ví / Onboard: `POST /v1/accounts`, `POST /v1/onboard`
- Merchant group lifecycle: `POST /v1/merchant-groups`, `POST /v1/merchant-groups/{group_id}/activate`, `POST /v1/merchant-groups/{group_id}/rescale`

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
