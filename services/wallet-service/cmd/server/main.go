// wallet-service/cmd/server is the binary entry point.
//
// It wires dependencies (config → otel → pgxpool → repo → usecase → http),
// then blocks on the HTTP server until SIGINT/SIGTERM.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ewallet-pg/wallet-service/internal/config"
	"github.com/ewallet-pg/wallet-service/internal/db"
	"github.com/ewallet-pg/wallet-service/internal/eod"
	netHTTP "github.com/ewallet-pg/wallet-service/internal/http"
	"github.com/ewallet-pg/wallet-service/internal/repo"
	"github.com/ewallet-pg/wallet-service/internal/telemetry"
	"github.com/ewallet-pg/wallet-service/internal/usecase"
)

// @title			Core Wallet API
// @version		1.0
// @description	Double-entry e-wallet ledger. The Go service is a thin RPC client over PostgreSQL stored functions; all balance validation, double-entry posting, fee/VAT and reversal logic run atomically in plpgsql. Scope is internal synchronous posting (top-up, transfer, withdraw, merchant settlement, fee/VAT, reversal). External rails (NAPAS, card 3DS, MT940) are out of scope.
// @description
// @description	## Error model
// @description	Every error is returned as `application/problem+json` (RFC 7807 / RFC 9457). The body carries a stable `errorCode` (business contract), `errorMessage` (user-safe), `internal_code` (E#### for ops/logs), `iso20022_reason_code` (pain.002 reason), `transaction_status` (pain.002 status), `trace_id` and a `retry` hint. `detail` adds dynamic context; field-level validation failures appear under `errors`.
// @description
// @description	### Business error code catalogue
// @description	| errorCode | internal_code | HTTP | ISO 20022 | Description |
// @description	| --- | --- | --- | --- | --- |
// @description	| INVALID_AMOUNT | E4024 | 400 | AM12 | The transaction amount is invalid or missing |
// @description	| AMOUNT_OUT_OF_RANGE | E4024 | 400 | AM02 | The amount is outside the allowed range for this transaction type |
// @description	| METADATA_TOO_LARGE | E4007 | 400 | - | The metadata payload exceeds the maximum allowed size (1 KB) |
// @description	| METADATA_HAS_P1 | E4008 | 400 | - | The metadata contains forbidden PII keys (phone, email, cccd, passport, full_name, bank_acct_no) |
// @description	| SAME_ACCOUNT | E4002 | 400 | BE01 | Source and destination accounts must be different |
// @description	| TRAN_TYPE_INACTIVE | E4003 | 400 | AG02 | The requested transaction type is inactive or does not exist |
// @description	| INVALID_REQUEST | E4001 | 400 | - | The request body is malformed or missing required fields |
// @description	| INVALID_PHONE_FORMAT | E2001 | 400 | - | Phone number must match Vietnam format 0XXXXXXXXX (10 digits) |
// @description	| INSUFFICIENT_FUNDS | E4022 | 422 | AM04 | The account balance is not sufficient to cover this transaction |
// @description	| TIER_LIMIT_EXCEEDED | E4023 | 422 | AM02 | The transaction exceeds the daily or monthly limit for this account tier |
// @description	| ACCT_ROLE_INVALID | E3008 | 422 | - | Operation only allowed on standalone wallets, not SHARD/SETTLEMENT accounts |
// @description	| INVALID_CLIENT_TYPE | E2010 | 422 | - | Client type must be one of IND, CORP, MER |
// @description	| INVALID_ACCT_TYPE | E3007 | 422 | - | The specified account type does not exist |
// @description	| ACCT_CLOSE_NONZERO_BAL | E3003 | 422 | - | Account closure requires a zero balance |
// @description	| ORG_FIELDS_REQUIRED | E2013 | 422 | - | Corporate/merchant clients must provide business_reg_no and legal_rep in extra_data |
// @description	| INVALID_SHARD_COUNT | E3030 | 422 | - | Shard count must be 4, 8, or 16 |
// @description	| INVALID_GROUP_TYPE | E3032 | 422 | - | Group type must be one of MERCHANT, AGENT, NOSTRO_HOT |
// @description	| INVALID_DATE | E8003 | 422 | DT01 | The as_of_date parameter is invalid or refers to a future date |
// @description	| BATCH_SIZE_EXCEEDED | E8004 | 422 | - | The batch request exceeds the maximum number of items (100) |
// @description	| RESTRAINT_TYPE_INVALID | E3022 | 422 | - | Restraint type must be one of DEBIT, CREDIT, ALL, INFO |
// @description	| RESTRAINT_PURPOSE_INVALID | E3023 | 422 | - | Restraint purpose is not a recognized value |
// @description	| RESTRAINT_TYPE_PURPOSE_CONFLICT | E3024 | 422 | - | The restraint type/purpose combination is not allowed |
// @description	| RESTRAINT_AMT_EXCEEDS_BALANCE | E3025 | 422 | AM04 | The pledged amount cannot exceed the current account balance |
// @description	| RESTRAINT_DATE_INVALID | E3026 | 422 | DT01 | The end_date must be on or after the start_date |
// @description	| COURT_ORDER_REMOVE_REQUIRES_DOC | E3027 | 422 | RR04 | Removing a COURT_ORDER/TAX_LIEN restraint requires a reference_doc |
// @description	| TIER_INSUFFICIENT | E2007 | 403 | RR04 | Your KYC tier does not permit this operation |
// @description	| FORBIDDEN | E1006 | 403 | AG01 | You do not have permission to perform this operation |
// @description	| UNAUTHORIZED | E1001 | 401 | - | Authentication is required or the provided credentials are invalid |
// @description	| DR_RESTRAINT_ACTIVE | E3005 | 423 | AC06 | The account has an active debit restraint (hold/lien) |
// @description	| CR_RESTRAINT_ACTIVE | E3006 | 423 | AC06 | The account has an active credit restraint |
// @description	| ACCT_NOT_FOUND | E3001 | 404 | AC01 | The specified account does not exist |
// @description	| CLIENT_NOT_FOUND | E2011 | 404 | - | No client record found for the specified client number |
// @description	| KYC_NOT_FOUND | E2012 | 404 | - | No KYC record exists for this client |
// @description	| BANK_LINK_NOT_FOUND | E2014 | 404 | - | No linked bank account found with the specified ID |
// @description	| RESTRAINT_NOT_FOUND | E3020 | 404 | - | No restraint exists with the specified ID |
// @description	| WD_NOT_FOUND | E6101 | 404 | - | No withdrawal record found for the given payout reference |
// @description	| ACCT_NOT_ACTIVE | E3004 | 403 | AC04 | The account is blocked or closed and cannot process transactions |
// @description	| VERSION_CONFLICT | E4025 | 409 | - | Another transaction updated this account simultaneously; retryable |
// @description	| DUPLICATE_REFERENCE | E4011 | 409 | AM05 | A transaction with this reference has already been processed |
// @description	| CLIENT_ALREADY_EXISTS | E2009 | 409 | AM05 | A client with this identity document already exists |
// @description	| PHONE_ALREADY_REGISTERED | E2002 | 409 | AM05 | This phone number is already associated with an existing account |
// @description	| MAX_WALLET_PER_CLIENT_EXCEEDED | E3002 | 409 | - | Maximum number of wallets reached (CONSUMER 3 per currency, MERCHANT 10) |
// @description	| GROUP_ALREADY_ACTIVATED | E3031 | 409 | - | This merchant group has already been activated with shards |
// @description	| GROUP_ALREADY_EXISTS | E3033 | 409 | AM05 | A group with this ID already exists |
// @description	| GROUP_NOT_ACTIVATED | E3034 | 409 | - | This group is still cold (0 shards); activate it before rescaling |
// @description	| RESTRAINT_ALREADY_REMOVED | E3021 | 409 | - | This restraint has already been released or expired |
// @description	| WD_ALREADY_COMPLETED | E6102 | 409 | - | This withdrawal has already reached COMPLETED status |
// @description	| WD_INVALID_STATE | E6103 | 409 | - | The withdrawal is in a state that does not permit this transition |
// @description	| WD_ALREADY_REVERSED | E6104 | 409 | - | This withdrawal has already been reversed |
// @description	| PERIOD_CLOSED | E8005 | 409 | DT01 | The target accounting date is sealed; post against the current open period |
// @description	| GONE_ONLINE | E8001 | 410 | - | Historical data beyond the online retention period; request an archive extract |
// @description	| TIMEOUT | E9004 | 504 | - | The request exceeded the allowed processing time; you may retry (503 on lock timeout) |
// @description	| PII_DEK_NOT_SET | E5005 | 500 | - | The server PII data-encryption key (DEK) is not set |
// @description	| BATCH_UNBALANCED | E5003 | 500 | - | Internal double-entry invariant violated (sum of debits != sum of credits) |
// @description	| INTERNAL_ERROR | E9001 | 500 | - | An unexpected error occurred; please retry or contact support |
// @description
// @description		Family fallbacks: any `*_NOT_FOUND` -> 404, `*_NOT_ACTIVE` -> 403, `*_CONFLICT` -> 409 (e.g. GROUP_NOT_FOUND, SETTLEMENT_NOT_FOUND, GROUP_NOT_ACTIVE).
// @termsOfService		https://docs.wallet.example/terms
//
// @contact.name		Core Wallet Team
// @contact.email		hoalh2@hdbank.com.vn
//
// @license.name		Proprietary
//
// @host				localhost:8080
// @BasePath			/
//
// @accept				json
// @produce			json
//
// @tag.name			health
// @tag.description	Liveness/readiness probe
// @tag.name			finance
// @tag.description	Money movement + ledger reads (topup, transfer, withdraw, merchant, reversals, fee/VAT, statement, restraints)
// @tag.name			clients
// @tag.description	Client master CRUD, onboarding, KYC, linked banks
// @tag.name			accounts
// @tag.description	Wallet lifecycle + profile + balance reads
// @tag.name			merchant-groups
// @tag.description	Merchant hot-wallet group lifecycle (provision -> activate -> rescale)
// @tag.name			ops
// @tag.description	Privileged/internal reads (full balance, batch balance, unmasked client PII)
// @tag.name			treasury
// @tag.description	Withdrawal disbursement state machine (S2S callbacks)
//
// @schemes			http https
func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	if err := run(logger); err != nil {
		logger.Error("startup failed", slog.Any("error", err))
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	rootCtx, stop := signal.NotifyContext(context.Background(),
		syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// ---- config ------------------------------------------------------------
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	logger.Info("config loaded",
		slog.String("env", cfg.Env),
		slog.String("http.addr", cfg.HTTP.Addr),
		slog.Bool("otel.enabled", cfg.Otel.Enabled))

	// ---- OpenTelemetry -----------------------------------------------------
	shutdownOtel, err := telemetry.Setup(rootCtx, cfg.Otel, cfg.HTTP.ServiceName, cfg.Env)
	if err != nil {
		return fmt.Errorf("otel setup: %w", err)
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shutdownOtel(ctx)
	}()

	// ---- PostgreSQL pool ---------------------------------------------------
	pool, err := db.NewPool(rootCtx, cfg.DB)
	if err != nil {
		return fmt.Errorf("db pool: %w", err)
	}
	defer pool.Close()
	logger.Info("db pool ready",
		slog.Int("max_conns", int(cfg.DB.MaxConns)),
		slog.Int("min_conns", int(cfg.DB.MinConns)))

	// ---- read pool (replica) for lag-tolerant reads ------------------------
	// Only the account/client-profile + statement-list reads use this (see repo).
	// Empty DB_READ_DSN → reuse the primary pool (no replica; strong consistency).
	readPool := pool
	if cfg.DB.ReadDSN != "" {
		readCfg := cfg.DB
		readCfg.DSN = cfg.DB.ReadDSN
		readPool, err = db.NewPool(rootCtx, readCfg)
		if err != nil {
			return fmt.Errorf("db read pool: %w", err)
		}
		defer readPool.Close()
		logger.Info("db read pool ready (replica)")
	} else {
		logger.Info("db read pool = primary (DB_READ_DSN unset)")
	}

	// ---- PII pool (wallet_pii_ro) for the unmasked client read -------------
	// Only GET /v1/ops/clients/:client_no uses this (see repo/client.go).
	// Empty DB_PII_DSN → reuse the primary pool (dev superuser sees raw PII; in
	// prod set a wallet_pii_ro DSN so wallet_app stays unable to read raw PII).
	piiPool := pool
	if cfg.DB.PIIDSN != "" {
		piiCfg := cfg.DB
		piiCfg.DSN = cfg.DB.PIIDSN
		piiPool, err = db.NewPool(rootCtx, piiCfg)
		if err != nil {
			return fmt.Errorf("db pii pool: %w", err)
		}
		defer piiPool.Close()
		logger.Info("db pii pool ready (wallet_pii_ro)")
	} else {
		logger.Info("db pii pool = primary (DB_PII_DSN unset)")
	}

	// ---- adapter → usecase → http -----------------------------------------
	walletRepo := repo.NewPgWalletRepo(pool, readPool, piiPool, cfg.DB.StatementTimeout, cfg.DB.LockTimeout, cfg.DB.TxMaxRetries)
	walletSvc := usecase.NewWalletService(walletRepo, logger)

	server, err := netHTTP.New(cfg.HTTP, walletSvc, logger)
	if err != nil {
		return fmt.Errorf("http server: %w", err)
	}

	// ---- end-of-day scheduler (opt-in; one replica) ------------------------
	// Runs on a SEPARATE direct pool as wallet_eod (bypassing PgBouncer) with
	// statement_timeout disabled — run_eod is a long, resumable batch that
	// COMMITs between chunks. Deferred in reverse order so the scheduler drains
	// (eodDone) before its pool closes.
	if cfg.EOD.Enabled {
		if cfg.EOD.DSN == "" {
			return fmt.Errorf("EOD_ENABLED=true but EOD_DSN is empty")
		}
		eodCfg := cfg.DB
		eodCfg.DSN = cfg.EOD.DSN
		eodCfg.MaxConns, eodCfg.MinConns = 2, 0
		eodCfg.StatementTimeout = 0 // batch: no OLTP statement cap
		eodCfg.LockTimeout = 0      // wait for locks rather than abort a chunk
		eodPool, err := db.NewPool(rootCtx, eodCfg)
		if err != nil {
			return fmt.Errorf("eod pool: %w", err)
		}
		defer eodPool.Close()

		// Two daily jobs on the same direct pool (modern-core split):
		//   customer EOD — run_eod for the PRIOR calendar day, overnight (RunAt)
		//   GL close     — run_gl_close for TODAY's accounting day, at the cutoff
		custEOD, err := eod.New(eodPool, "customer-eod", "run_eod", eod.PriorDay,
			cfg.EOD.RunAt, cfg.EOD.Timezone, cfg.EOD.RunTimeout, logger)
		if err != nil {
			return fmt.Errorf("eod scheduler: %w", err)
		}
		glClose, err := eod.New(eodPool, "gl-close", "run_gl_close", eod.CurrentDay,
			cfg.EOD.GLCutoff, cfg.EOD.Timezone, cfg.EOD.RunTimeout, logger)
		if err != nil {
			return fmt.Errorf("gl-close scheduler: %w", err)
		}
		eodDone := make(chan struct{})
		go func() { defer close(eodDone); _ = custEOD.Start(rootCtx) }()
		glDone := make(chan struct{})
		go func() { defer close(glDone); _ = glClose.Start(rootCtx) }()
		defer func() { <-eodDone; <-glDone }()
		logger.Info("eod schedulers enabled",
			slog.String("customer_eod_at", cfg.EOD.RunAt),
			slog.String("gl_close_at", cfg.EOD.GLCutoff),
			slog.String("tz", cfg.EOD.Timezone))
	} else {
		logger.Info("eod scheduler disabled (EOD_ENABLED unset)")
	}

	// ---- block until signal -----------------------------------------------
	if err := server.Start(rootCtx); err != nil {
		return fmt.Errorf("http: %w", err)
	}
	logger.Info("server stopped cleanly")
	return nil
}
