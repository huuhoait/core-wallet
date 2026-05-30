package http

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gin-gonic/gin/binding"
	"github.com/go-playground/validator/v10"
	"go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin"

	"github.com/ewallet-pg/wallet-service/internal/config"
	"github.com/ewallet-pg/wallet-service/internal/http/handler"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
	"github.com/ewallet-pg/wallet-service/internal/usecase"
)

// Server wraps a configured *http.Server with graceful shutdown.
type Server struct {
	cfg    config.HTTP
	server *http.Server
	log    *slog.Logger
}

// New builds the gin engine + applies middleware + mounts routes.
func New(cfg config.HTTP, svc *usecase.WalletService, log *slog.Logger) (*Server, error) {
	if cfg.Mode == "" {
		gin.SetMode(gin.ReleaseMode)
	} else {
		gin.SetMode(cfg.Mode)
	}

	registerCustomValidators()

	r := gin.New()
	r.Use(
		gin.Logger(),                 // simple access log
		middleware.Recovery(),         // panic → 500 envelope
		middleware.RequestID(),
		otelgin.Middleware(cfg.ServiceName),
		middleware.AuditContext(),
	)

	h := handler.New(svc)
	r.GET("/healthz", h.Healthz) // no request timeout — cheap probe

	// Transactional + treasury endpoints carry the hard ctx deadline (HLD §9).
	// Everything below this group inherits middleware.WithTimeout(cfg.RequestTimeout).
	v1 := r.Group("/v1")
	v1.Use(middleware.WithTimeout(cfg.RequestTimeout))
	{
		// ── Finance: money movement + ledger reads ──
		finance := v1.Group("/finance")
		{
			finance.POST("/topup", h.Topup)
			finance.POST("/transfer", h.Transfer)
			finance.POST("/withdraw", h.Withdraw)
			finance.POST("/merchant-withdraw", h.MerchantWithdraw) // settlement withdraw + hot-shard sweep
			finance.POST("/reverse", h.ReverseTransfer)            // in-book transfer reversal (reference in body)
			finance.POST("/topup/reverse", h.ReverseTopup)         // topup reversal (reference in body)
			finance.GET("/transactions", h.ListTransactions)       // account statement: ?acct_no=&limit=&before_seq=
			finance.GET("/transactions/:tfr_key", h.GetTransaction) // all legs of one transaction
			finance.POST("/restraints", h.AddRestraint)             // add a hold/lien
			finance.POST("/restraints/:id/release", h.ReleaseRestraint)
		}

		// ── Accounts: profile + balance reads (Get Balance §9). Read-only. ──
		accounts := v1.Group("/accounts")
		{
			accounts.GET("/:acct_no", h.GetAccount)              // account profile (no client PII)
			accounts.GET("/:acct_no/balance", h.GetBalance)      // realtime + historical (?as_of_date=)
		}
		ops := v1.Group("/ops/accounts")
		{
			ops.GET("/:acct_no/balance", h.GetBalanceOps)
			ops.POST("/balance/batch", h.GetBalanceBatch)
		}

		// ── Treasury: withdrawal disbursement state machine (S2S callbacks) ──
		treasury := v1.Group("/treasury/withdrawals/:ext_payout_ref")
		{
			treasury.POST("/acked", h.MarkAcked)
			treasury.POST("/disbursing", h.MarkDisbursing)
			treasury.POST("/completed", h.MarkCompleted)
			treasury.POST("/reverse", h.Reverse)
		}
	}

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       cfg.ReadTimeout,
		WriteTimeout:      cfg.WriteTimeout,
		IdleTimeout:       cfg.IdleTimeout,
	}
	return &Server{cfg: cfg, server: srv, log: log}, nil
}

// Start blocks until the server stops listening or the context is cancelled.
// Returns nil on graceful shutdown, error on listen failure.
func (s *Server) Start(ctx context.Context) error {
	errCh := make(chan error, 1)
	go func() {
		s.log.Info("HTTP server listening", slog.String("addr", s.cfg.Addr))
		if err := s.server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
			return
		}
		errCh <- nil
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), s.cfg.ShutdownTimeout)
		defer cancel()
		s.log.Info("HTTP server stopping")
		_ = s.server.Shutdown(shutdownCtx)
		return nil
	case err := <-errCh:
		return err
	}
}

// ----- custom validators ----------------------------------------------------

var (
	moneyRE  = regexp.MustCompile(`^\d{1,18}(\.\d{1,2})?$`)
	acctNoRE = regexp.MustCompile(`^[A-Z0-9]{8,20}$`)
)

func registerCustomValidators() {
	v, ok := binding.Validator.Engine().(*validator.Validate)
	if !ok {
		return
	}
	_ = v.RegisterValidation("money", validateMoney)
	_ = v.RegisterValidation("acct_no", validateAcctNo)
}

func validateMoney(fl validator.FieldLevel) bool {
	return moneyRE.MatchString(fl.Field().String())
}
func validateAcctNo(fl validator.FieldLevel) bool {
	return acctNoRE.MatchString(fl.Field().String())
}
