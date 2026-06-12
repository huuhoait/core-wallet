package handler

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
)

// SuspenseAging godoc
//
//	@Summary		Suspense/clearing aging report
//	@Description	Per 109.x clearing/suspense GL + currency, the net open balance (ΣCR−ΣDR) bucketed by post-date age (0-30 / 31-60 / 61-90 / 90+). Optional ?as_of=YYYY-MM-DD (default today).
//	@Tags			accounting
//	@Produce		json
//	@Param			as_of	query		string	false	"Report date YYYY-MM-DD (default today)"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.SuspenseAgingResponse}	"OK"
//	@Failure		400		{object}	dto.ProblemDetails	"Invalid as_of"
//	@Failure		500		{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/ops/gl/suspense/aging [get]
func (h *Wallet) SuspenseAging(c *gin.Context) {
	asOf := time.Now().UTC()
	asOfStr := asOf.Format("2006-01-02")
	if v := c.Query("as_of"); v != "" {
		t, err := time.Parse("2006-01-02", v)
		if err != nil {
			renderError(c, domain.InvalidRequest("invalid as_of (expected YYYY-MM-DD)", nil))
			return
		}
		asOf, asOfStr = t, v
	}
	rows, err := h.svc.SuspenseAging(c.Request.Context(), asOf)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.SuspenseAgingRespFrom(asOfStr, rows))
}
