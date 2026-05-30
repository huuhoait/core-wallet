# Web Portal Integration Specifications

Tài liệu này mô tả chi tiết đặc tả (specifications) để tích hợp Web Portal với Core Wallet Backend, dựa trên Postman collection hiện có và kiến trúc CQRS (Command Query Responsibility Segregation) của hệ thống.

## 1. Nguyên tắc tích hợp chung (Architecture & CQRS)

Web Portal khi gọi xuống Core Wallet Backend cần tuân thủ các nguyên tắc thiết kế sau:
- **Write Path (Commands):** Các thao tác làm thay đổi dữ liệu (tạo ví, topup, transfer, khoá tài khoản...) sẽ được gọi qua các hàm bọc trong `PgWalletRepo.withTx`. Request bắt buộc phải có thông tin Audit (Actor, Channel, TraceID) trên Header để trigger ghi log xuống Database.
- **Read Path (Queries):** Các thao tác chỉ đọc (list, xem chi tiết, số dư...) được đi thẳng qua `pool.Query/QueryRow` trên read-replica (nếu có) hoặc master mà không bị bọc bởi Transaction (để tối ưu performance).
- **Idempotency:** Các endpoint xử lý tiền (`/v1/finance/*`) hỗ trợ Idempotency qua trường `reference` trong request body. Web Portal cần sinh UUID hoặc một reference duy nhất cho mỗi giao dịch gửi xuống và retry an toàn với reference đó nếu gặp sự cố timeout.

---

## 2. Chi tiết các luồng (Flows) tích hợp

### 2.1. Tạo ví (Create Wallet)
- **Mục đích:** Mở một tài khoản/ví mới cho khách hàng đã tồn tại (Client).
- **Endpoint:** `POST /v1/accounts`
- **CQRS Path:** Write (Command - `WalletRepository.OpenAccount`)
- **Request Body:**
  ```json
  {
    "client_no": "CLIENT_NUMBER",
    "acct_type": "CONSUMER" // hoặc "MERCHANT", "SYSTEM"
  }
  ```
- **Xử lý trên Portal:** Nhận `acct_no` trả về từ API để map vào hồ sơ người dùng trên Portal.

### 2.2. Cập nhật ví (Update Wallet) & Khóa tài khoản (Lock Account)
- **Mục đích:** Cập nhật trạng thái của ví (vd: Chuyển sang Block hoặc Close).
- **Endpoint:** `PATCH /v1/accounts/{acct_no}`
- **CQRS Path:** Write (Command - `WalletRepository.UpdateAccountStatus`)
- **Request Body (Lock Account):**
  ```json
  {
    "status": "B" // B = Blocked, C = Closed, A = Active
  }
  ```
- **Xử lý trên Portal:** Hiển thị warning/confirm cho admin khi thực hiện lock tài khoản.

### 2.3. Lấy danh sách ví (List Wallets)
> [!WARNING]
> Endpoint này **chưa có** trong cấu hình Postman/Port hiện tại và cần phát triển thêm ở Backend.
- **Mục đích:** Lấy danh sách tất cả các ví của một `client_no`.
- **Endpoint đề xuất:** `GET /v1/clients/{client_no}/accounts`
- **CQRS Path:** Read (Query) - Không bọc Transaction. Cần bổ sung method `ListClientAccounts` vào `usecase.WalletRepository`.
- **Xử lý trên Portal:** Hiển thị danh sách các thẻ ví. Khi user click vào, gọi API 2.4 để lấy chi tiết.

### 2.4. Xem thông tin chi tiết ví (View Wallet Details)
- **Mục đích:** Lấy thông tin profile ví và số dư khả dụng (Balance).
- **Endpoint:** 
  1. Profile: `GET /v1/accounts/{acct_no}`
  2. Số dư: `GET /v1/accounts/{acct_no}/balance`
- **CQRS Path:** Read (Query - `GetAccount`, `GetBalance`)
- **Xử lý trên Portal:** Portal có thể gọi song song 2 API này hoặc backend cung cấp 1 API tổng hợp để render màn hình chi tiết Ví.

### 2.5. Tạo giao dịch Topup (Nạp tiền)
- **Mục đích:** Bơm tiền từ hệ thống (Treasury/Nostro) vào ví của người dùng.
- **Endpoint:** `POST /v1/finance/topup`
- **CQRS Path:** Write (Command - `WalletRepository.Topup`)
- **Request Body:**
  ```json
  {
    "acct_no": "ACCOUNT_NUMBER",
    "amount": "5000000",
    "reference": "UNIQUE_REFERENCE_UUID",
    "narrative": "Ghi chú giao dịch topup",
    "metadata": {
      "channel": "WEB_PORTAL",
      "partner_ref": "REF_123"
    }
  }
  ```
- **Xử lý trên Portal:** Portal cần sinh một unique `reference` cho mỗi giao dịch. Quản lý trạng thái retry nếu gặp lỗi 5xx.

### 2.6. Chuyển khoản (Transfer)
- **Mục đích:** Chuyển tiền từ ví này sang ví khác (In-book Transfer).
- **Endpoint:** `POST /v1/finance/transfer`
- **CQRS Path:** Write (Command - `WalletRepository.Transfer`)
- **Request Body:**
  ```json
  {
    "from_acct_no": "SENDER_ACCT",
    "to_acct_no": "RECEIVER_ACCT",
    "amount": "100000",
    "reference": "UNIQUE_REFERENCE_UUID",
    "tran_type": "TRFOUT", // hoặc TRFOUTF (nếu miễn phí)
    "narrative": "Chuyển khoản thanh toán",
    "metadata": {}
  }
  ```

### 2.7. Thêm Restraint (Hold tiền/Phong toả)
- **Mục đích:** Đóng băng một khoản tiền (hoặc chiều ghi Nợ) với mục đích nghiệp vụ (Ví dụ: Tra soát, Yêu cầu toà án).
- **Endpoint:** `POST /v1/finance/restraints`
- **CQRS Path:** Write (Command - `WalletRepository.AddRestraint`)
- **Request Body:**
  ```json
  {
    "acct_no": "ACCOUNT_NUMBER",
    "restraint_type": "DEBIT", // DEBIT, CREDIT hoặc BOTH
    "restraint_purpose": "DISPUTE_HOLD", // COURT_ORDER, v.v.
    "pledged_amt": "50000", // Bắt buộc nếu là amount hold
    "narrative": "Lý do hold tiền"
  }
  ```

### 2.8. Gỡ Restraint (Remove Restraint)
- **Mục đích:** Mở khoá/Gỡ bỏ một khoản tiền/trạng thái đã bị phong toả trước đó.
- **Endpoint:** `POST /v1/finance/restraints/{restraint_id}/release`
- **CQRS Path:** Write (Command - `WalletRepository.ReleaseRestraint`)
- **Request Body:**
  ```json
  {
    "reason": "Lý do gỡ phong toả"
  }
  ```

### 2.9. Lịch sử giao dịch (List Transactions)
- **Mục đích:** Sao kê giao dịch của ví.
- **Endpoint:** `GET /v1/finance/transactions?acct_no={acct_no}&limit=20&offset=0`
- **CQRS Path:** Read (Query - `WalletRepository.ListTransactions`)
- **Lưu ý DB:** API này query trên bảng `WLT_TRAN_HIST` đã được partition theo `POST_DATE` và hash `INTERNAL_KEY`. Portal **BẮT BUỘC** phải truyền khoảng thời gian (`from_date`, `to_date`) giới hạn để DB sử dụng partition pruning hiệu quả (tránh full scan).

### 2.10. Danh sách & Chi tiết Restraint (List/Get Restraints)
- **Mục đích:** Liệt kê các trạng thái phong toả / giữ tiền hiện tại của một ví, hoặc xem chi tiết một lệnh phong toả cụ thể.
- **Endpoint:** 
  1. Danh sách: `GET /v1/finance/restraints?acct_no={acct_no}&status=ACTIVE`
  2. Chi tiết: `GET /v1/finance/restraints/{restraint_id}`
- **CQRS Path:** Read (Query - Bypass transaction, gọi qua `WalletRepository.ListRestraints` và `GetRestraint`).
- **Xử lý trên Portal:** Hiển thị danh sách restraint đang active để admin có thể chọn xem chi tiết hoặc thực hiện luồng "Gỡ Restraint".

### 2.11. Màn hình Client 360 (Client Details Dashboard)
- **Mục đích:** Khi admin ở màn hình "Danh sách Khách hàng" (List Clients) và click xem một Khách hàng, hệ thống hiển thị góc nhìn toàn diện (360 độ) về khách hàng đó.
- **Các thành phần dữ liệu cần hiển thị (và API tương ứng):**
  1. **Chi tiết thông tin khách hàng (Profile):** Lấy các thông tin định danh (Tên, CCCD, Ngày sinh...). Cần API `GET /v1/clients/{client_no}` (Lưu ý: API này hiện chưa có, cần bổ sung vào hệ thống).
  2. **Ví, Số dư & Số tiền phong toả:** Hiển thị danh sách các ví của khách hàng. Gọi API `GET /v1/clients/{client_no}/accounts` (đề xuất ở 2.3), kết hợp với `GET /v1/accounts/{acct_no}/balance` để biết chính xác số dư hiện tại và phần tiền đang bị phong toả (`pledged_amt`).
  3. **Tài khoản liên kết (Linked Banks):** Hiển thị danh sách các ngân hàng khách hàng đã liên kết. Cần API `GET /v1/clients/{client_no}/banks` (Lưu ý: API này chưa có, Postman hiện chỉ có hàm POST).
  4. **Các loại phong toả (nếu có):** Gọi API ở mục 2.10 (`GET /v1/finance/restraints?acct_no=...`) để liệt kê chi tiết các lệnh phong toả (loại, số tiền, lý do) đang áp dụng trên ví.
  5. **Link tra cứu giao dịch:** Portal cung cấp action button (đường dẫn) điều hướng sang Màn hình **Lịch sử giao dịch** (API 2.9), tự động truyền sẵn tham số `acct_no` để admin dễ dàng tra cứu mà không phải nhập lại.
- **Kiến trúc đề xuất (BFF Pattern):** Để Web Portal không phải gọi quá nhiều API rời rạc cho 1 màn hình, Backend nên cân nhắc phát triển một API tổng hợp (ví dụ: `GET /v1/portal/clients/{client_no}/360-view`). API này sẽ thực hiện Read Query từ các bảng (WLT_CLIENT, WLT_ACCOUNT, WLT_ACCT_BAL, WLT_CLIENT_BANK...) và trả về payload thống nhất.

---

## 3. Luồng Duyệt Kép (Maker & Checker / 4-Eyes Principle)

Các thao tác nhạy cảm trên Web Portal (đặc biệt là thay đổi số dư hoặc trạng thái ví) bắt buộc phải trải qua luồng duyệt kép để đảm bảo an toàn và tuân thủ (Compliance). Do hệ thống Core Wallet Backend (các API hiện tại) là hệ thống thực thi (Execution Engine) không trực tiếp quản lý trạng thái pending của Maker/Checker, luồng này sẽ được xử lý ở tầng Portal Backend (hoặc BFF).

### 3.1. Các luồng thay đổi dữ liệu cần Approval (Maker & Checker)

Để đảm bảo kiểm soát rủi ro, mọi thao tác Write Path (thay đổi dữ liệu) xuất phát từ Web Portal đều nên được cấu hình luồng duyệt. Cụ thể phân thành 2 nhóm:

**Nhóm 1: Thay đổi dữ liệu Tài chính & Trạng thái (Rủi ro cao)**
- **Nạp tiền (Topup):** Bơm tiền từ hệ thống vào ví người dùng (`POST /v1/finance/topup`).
- **Phong toả / Gỡ phong toả (Restraints):** Đóng băng/mở khoá số tiền trên ví (`POST /v1/finance/restraints`).
- **Giao dịch / Hoàn tiền thủ công (Transfer/Reverse):** Chuyển tiền, hoàn tiền thủ công bởi Admin (`POST /v1/finance/transfer`, `POST /v1/finance/reverse`).
- **Thay đổi trạng thái ví:** Khoá (Block) hoặc Đóng (Close) ví (`PATCH /v1/accounts/{acct_no}`).

**Nhóm 2: Thay đổi dữ liệu Hồ sơ Khách hàng (Nhạy cảm)**
- **Cập nhật thông tin định danh (Update Client):** Đổi Tên, CCCD/CMND, Ngày sinh, v.v. (`PATCH /v1/clients/{client_no}`).
- **Quản lý Tài khoản ngân hàng liên kết (Bank Links):** Thêm ngân hàng mới hoặc set tài khoản ngân hàng mặc định để rút tiền (`POST /v1/clients/{client_no}/banks`, `PUT /.../default`).
- **Mở ví mới (Open Account):** Cấp phát tài khoản ví mới cho khách hàng (`POST /v1/accounts`).

### 3.2. Thiết kế luồng xử lý (Workflow)
1. **Khởi tạo (Maker):**
   - User (Maker) nhập thông tin giao dịch trên Web Portal.
   - Portal Backend lưu giao dịch vào database riêng của Portal với trạng thái `PENDING_APPROVAL`. **Chưa** gọi API xuống Core Wallet Backend.
2. **Kiểm duyệt (Checker):**
   - User khác (Checker, có quyền cao hơn hoặc cùng cấp nhưng khác user ID) vào màn hình "Duyệt giao dịch".
   - Xem lại các thông tin của Maker.
   - Nếu **Từ chối (Reject):** Portal Backend chuyển trạng thái giao dịch thành `REJECTED`, kết thúc luồng.
   - Nếu **Phê duyệt (Approve):** Portal Backend sẽ tiến hành gọi API thực thi xuống Core Wallet (ví dụ: `POST /v1/finance/topup`).
3. **Thực thi & Audit (Execution):**
   - Khi Portal Backend gọi xuống Core Wallet, bắt buộc phải truyền thông tin Audit qua Header.
   - `x-audit-actor`: Nên để là User ID của **Checker** (người quyết định cuối cùng) hoặc ghép cả `Maker_ID/Checker_ID` tuỳ quy định.
   - Giao dịch thực thi thành công, Core Wallet trả về `reference` hoặc `tfr_key`. Portal Backend cập nhật giao dịch thành `COMPLETED`.

### 3.3. Xử lý Idempotency và Lỗi (Resilience)
- Nếu giao dịch được Checker duyệt, Portal Backend gọi xuống Core Wallet nhưng bị timeout, Portal Backend phải có cơ chế retry tự động với đúng tham số `reference` đã sinh ra từ trước (tính Idempotency của Core).
- Không bao giờ được phép retry giao dịch đã bị Core Wallet trả về lỗi nghiệp vụ (400, 422 - ví dụ như Insufficient funds) mà phải cập nhật trạng thái trên Portal thành `FAILED`.
