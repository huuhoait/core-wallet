-- =============================================================================
-- seed.sql — reference / master data (data-only, --disable-triggers)
-- GL master (fm_gl_mast), COA map (wlt_gl_map), tran types (wlt_tran_def),
-- currency (fm_currency), account types (wlt_acct_type). Restore AFTER schema.sql.
-- =============================================================================
--
-- PostgreSQL database dump
--

\restrict PJoagrWLTmBkBwHK5cj4fwWn2WI9xTrvsXqKvxpoRUOsMmlv3F1X1znZZbbYtXj

-- Dumped from database version 17.10
-- Dumped by pg_dump version 17.10

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: fm_currency; Type: TABLE DATA; Schema: public; Owner: -
--

SET SESSION AUTHORIZATION DEFAULT;

ALTER TABLE public.fm_currency DISABLE TRIGGER ALL;

COPY public.fm_currency (ccy, ccy_desc, deci_places, day_basis, round_trunc, ccy_group, status, channel, created_at, created_by, updated_at, updated_by) FROM stdin;
VND	Vietnam Dong	0	365	\N	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
\.


ALTER TABLE public.fm_currency ENABLE TRIGGER ALL;

--
-- Data for Name: fm_gl_mast; Type: TABLE DATA; Schema: public; Owner: -
--

ALTER TABLE public.fm_gl_mast DISABLE TRIGGER ALL;

COPY public.fm_gl_mast (gl_code, gl_code_desc, gl_code_type, control_gl_code, bspl_type, gl_type, tfr_ind, status, channel, created_at, created_by, updated_at, updated_by) FROM stdin;
101	Cash & equivalents (parent)	A	\N	B	CASH	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
201	Customer liabilities (parent)	L	\N	B	LIAB	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
203	Tax payable (parent)	L	\N	B	TAX	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
401	Fee revenue (parent)	I	\N	P	REV	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
102	Receivables (parent)	A	\N	B	RECV	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
103	Prepaid & advances (parent)	A	\N	B	PREPAID	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
109	Clearing & suspense (parent)	A	\N	B	CLEAR	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
202	Settlement payables (parent)	L	\N	B	SETTLE	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
101.02	Nostro accounts (parent)	A	101	B	CASH	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:31.378303+07	postgres
101.01	Settlement accounts — TKĐBTT (parent)	A	101	B	CASH	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.378387+07	postgres
101.03	Operating bank accounts (parent)	A	101	B	CASH	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.378392+07	postgres
101.01.001	TKĐBTT — Partner Bank A (escrow)	A	101.01	B	TKDBTT	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.378536+07	postgres
101.01.002	TKĐBTT — Partner Bank B (escrow)	A	101.01	B	TKDBTT	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.37854+07	postgres
101.02.001	Nostro @ Partner Bank — TKĐBTT	A	101.02	B	NOSTRO	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:31.378621+07	postgres
101.03.001	Operating account — Bank A	A	101.03	B	OPER	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.378672+07	postgres
102.01	Cash-in receivable (parent)	A	102	B	RECV	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.378782+07	postgres
102.02	Partner / biller receivable (parent)	A	102	B	RECV	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.37879+07	postgres
204	Dormant / unclaimed balances (parent)	L	\N	B	LIAB	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
205	Provisions (parent)	L	\N	B	PROV	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
402	Financial income (parent)	I	\N	P	INTINC	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
501	Channel & processing cost (parent)	E	\N	P	EXP	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
502	Marketing & partner cost (parent)	E	\N	P	EXP	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
102.01.001	Cash-in receivable — NAPAS / IBFT	A	102.01	B	RECV	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.378887+07	postgres
102.01.002	Cash-in receivable — Card (Visa/MC/JCB)	A	102.01	B	RECV	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.378895+07	postgres
102.01.003	Cash-in receivable — Bank-linked account	A	102.01	B	RECV	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.378901+07	postgres
102.02.001	Receivable — biller settlement	A	102.02	B	RECV	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.378978+07	postgres
103.01	Prepaid float (parent)	A	103	B	PREPAID	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379037+07	postgres
103.01.001	Prepaid float to biller / partner	A	103.01	B	PREPAID	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379094+07	postgres
109.01	Cash-in clearing (parent)	A	109	B	CLEAR	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379163+07	postgres
109.02	Cash-out clearing (parent)	A	109	B	CLEAR	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379168+07	postgres
109.03	Payment clearing (parent)	A	109	B	CLEAR	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379172+07	postgres
109.04	Suspense (parent)	A	109	B	SUSP	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379176+07	postgres
109.01.001	Cash-in clearing	A	109.01	B	CLEAR	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379249+07	postgres
109.02.001	Cash-out / disbursement clearing	A	109.02	B	CLEAR	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379304+07	postgres
109.03.001	Payment & settlement clearing	A	109.03	B	CLEAR	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379358+07	postgres
109.04.001	Reversal / failed-txn suspense	A	109.04	B	SUSP	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379417+07	postgres
109.04.002	Unidentified receipts	A	109.04	B	SUSP	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379422+07	postgres
109.04.009	Reconciliation difference	A	109.04	B	SUSP	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379426+07	postgres
201.01	Customer wallets (parent)	L	201	B	LIAB	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:31.379505+07	postgres
201.02	Merchant wallets (parent)	L	201	B	LIAB	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:31.37951+07	postgres
201.03	Promotional balance (parent, NOT escrow-backed)	L	201	B	PROMO	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379514+07	postgres
201.01.001	Customer Wallet — Consumer	L	201.01	B	LIAB	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:31.379569+07	postgres
201.02.001	Merchant Wallet	L	201.02	B	LIAB	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:31.379624+07	postgres
201.03.001	Promotional / bonus wallet balance	L	201.03	B	PROMO	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379672+07	postgres
202.01	Merchant settlement payable (parent)	L	202	B	SETTLE	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379732+07	postgres
202.02	Biller / partner payable (parent)	L	202	B	SETTLE	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379736+07	postgres
202.01.001	Payable to merchant — settlement	L	202.01	B	SETTLE	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379796+07	postgres
202.02.001	Payable to biller / service partner	L	202.02	B	SETTLE	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379849+07	postgres
203.01	VAT output payable	L	203	B	TAX	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:31.379902+07	postgres
204.01	Dormant balances (parent)	L	204	B	LIAB	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.379948+07	postgres
204.01.001	Dormant wallet liability	L	204.01	B	LIAB	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.38+07	postgres
205.01	Promotion provision (parent)	L	205	B	PROV	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.380053+07	postgres
205.01.001	Cashback / promotion payable reserve	L	205.01	B	PROV	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.380106+07	postgres
401.01	Transfer/withdraw fee revenue	I	401	P	REV	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:31.380166+07	postgres
401.02	Merchant withdraw fee revenue	I	401	P	REV	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:31.380172+07	postgres
401.03	Merchant discount rate (MDR)	I	401	P	REV	\N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:31.380176+07	postgres
401.04	Bill-payment / top-up commission income	I	401	P	COMM	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.38018+07	postgres
402.01	Float interest income on TKĐBTT	I	402	P	INTINC	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.380233+07	postgres
501.01	Bank / channel fee (cash-in & cash-out)	E	501	P	EXP	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.380289+07	postgres
501.02	Card scheme / switching fee (NAPAS/Visa/MC)	E	501	P	EXP	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.380292+07	postgres
502.01	Cashback / promotion expense	E	502	P	EXP	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.380353+07	postgres
502.02	Partner commission expense	E	502	P	EXP	\N	A	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.380366+07	postgres
\.


ALTER TABLE public.fm_gl_mast ENABLE TRIGGER ALL;

--
-- Data for Name: wlt_acct_type; Type: TABLE DATA; Schema: public; Owner: -
--

ALTER TABLE public.wlt_acct_type DISABLE TRIGGER ALL;

COPY public.wlt_acct_type (acct_type, acct_type_desc, gl_code_liab, prod_id, daily_limit, monthly_limit, int_bearing, status, channel, created_at, created_by, updated_at, updated_by) FROM stdin;
CONSUMER	Consumer wallet	201.01.001	WLT-CONS	20000000.00	100000000.00	N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
MERCHANT	Merchant wallet	201.02.001	WLT-MERCH	500000000.00	5000000000.00	N	A	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
\.


ALTER TABLE public.wlt_acct_type ENABLE TRIGGER ALL;

--
-- Data for Name: wlt_gl_map; Type: TABLE DATA; Schema: public; Owner: -
--

ALTER TABLE public.wlt_gl_map DISABLE TRIGGER ALL;

COPY public.wlt_gl_map (acct_type, event_type, gl_code, gl_desc, channel, created_at, created_by, updated_at, updated_by) FROM stdin;
CONSUMER	LIABILITY	201.01.001	Customer Wallet — Consumer	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
CONSUMER	TOPUP_DR	101.02.001	Nostro @ Bank	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
CONSUMER	WITHDRAW_CR	101.02.001	Nostro @ Bank	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
CONSUMER	FEE_CR	401.01	Transfer/withdraw fee revenue	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
CONSUMER	VAT_CR	203.01	VAT output payable	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
MERCHANT	LIABILITY	201.02.001	Merchant Wallet	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
MERCHANT	WITHDRAW_CR	101.02.001	Nostro @ Bank	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
MERCHANT	MDR_CR	401.03	Merchant discount rate	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
MERCHANT	FEE_CR	401.02	Merchant withdraw fee revenue	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
MERCHANT	VAT_CR	203.01	VAT output payable	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
CONSUMER	PROMO_CR	201.03.001	Promotional balance credit	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
CONSUMER	PROMO_EXP_DR	502.01	Cashback / promotion expense	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
CONSUMER	PAY_CLR	109.03.001	Payment & settlement clearing	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
CONSUMER	CASHIN_CLR	109.01.001	Cash-in clearing	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
CONSUMER	CASHOUT_CLR	109.02.001	Cash-out clearing	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
CONSUMER	DORMANT_CR	204.01.001	Dormant wallet liability	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
MERCHANT	SETTLE_CR	202.01.001	Payable to merchant — settlement	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
MERCHANT	PAY_CLR	109.03.001	Payment & settlement clearing	SYSTEM	2026-05-31 11:23:31.375705+07	postgres	2026-05-31 11:23:31.375705+07	postgres
CONSUMER	BILLER_CLR	109.03.001	Payment clearing — bill/airtime	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
CONSUMER	COMM_CR	401.04	Bill/topup commission income	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
CONSUMER	REFUND_CR	201.01.001	Refund to consumer wallet	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
CONSUMER	ADJ_SUSP	109.04.001	Manual adjustment suspense	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
MERCHANT	SETTLE_CLR	109.03.001	Payment clearing — settlement source	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
\.


ALTER TABLE public.wlt_gl_map ENABLE TRIGGER ALL;

--
-- Data for Name: wlt_tran_def; Type: TABLE DATA; Schema: public; Owner: -
--

ALTER TABLE public.wlt_tran_def DISABLE TRIGGER ALL;

COPY public.wlt_tran_def (tran_type, tran_desc, cr_dr_maint_ind, reversal_tran_type, check_fund_ind, check_restraint_ind, source_type, contra_gl_code, min_tran_amt, max_tran_amt, max_future_date_days, auto_approval, narrative, status, fee_type, fee_amt, fee_rate, fee_min, fee_max, vat_rate, fee_gl_code, vat_gl_code, fee_tran_type, channel, created_at, created_by, updated_at, updated_by) FROM stdin;
TOPUP	Top-up from bank	CR	RVTPUP	N	N	BANK	101.02.001	10000.00	500000000.00	0	Y	Topup	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
TRFOUT	Internal transfer out	DR	RVTRF	Y	Y	MOBILE	\N	1000.00	100000000.00	0	Y	Transfer	A	FIXED	5500.00	0.000000	0.00	0.00	0.1000	401.01	203.01	FEETRF	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
TRFIN	Internal transfer in	CR	RVTRF	N	N	MOBILE	\N	1000.00	100000000.00	0	Y	Transfer	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
WDRAW	Withdraw to bank	DR	RVWD	Y	Y	MOBILE	101.02.001	50000.00	200000000.00	0	Y	Withdraw	A	PERCENT	0.00	0.001000	11000.00	55000.00	0.1000	401.01	203.01	FEEWD	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
FEETRF	Fee for transfer	DR	RVFEE	N	N	SYS	401.01	0.00	10000000.00	0	Y	Fee	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
FEEWD	Fee for withdraw	DR	RVFEE	N	N	SYS	401.01	0.00	10000000.00	0	Y	Fee	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
RVTPUP	Reverse topup	DR	\N	N	N	SYS	101.02.001	0.00	500000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
RVTRF	Reverse transfer	CR	\N	N	N	SYS	\N	0.00	100000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
RVWD	Reverse withdraw	CR	\N	N	N	SYS	101.02.001	0.00	200000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
RVFEE	Reverse fee	CR	\N	N	N	SYS	401.01	0.00	10000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
SWEEPO	Sweep out from shard	DR	RVSWP	N	N	SYS	\N	0.00	1000000000.00	0	Y	Sweep	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
SWEEPI	Sweep in to settlement	CR	RVSWP	N	N	SYS	\N	0.00	1000000000.00	0	Y	Sweep	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
RVSWP	Reverse sweep	CR	\N	N	N	SYS	\N	0.00	1000000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
MERCHWD	Merchant withdraw	DR	RVMWD	Y	Y	SYS	101.02.001	50000.00	2000000000.00	0	Y	Withdraw	A	PERCENT	0.00	0.000500	22000.00	110000.00	0.1000	401.02	203.01	FEEMW	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
FEEMW	Fee merchant WD	DR	RVFEE	N	N	SYS	401.02	0.00	10000000.00	0	Y	Fee	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
RVMWD	Reverse merchant WD	CR	\N	N	N	SYS	101.02.001	0.00	2000000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:30.77554+07	postgres	2026-05-31 11:23:30.77554+07	postgres
DEPOSIT	Nạp ví qua đại lý	CR	RVDEP	N	N	AGENT	\N	10000.00	500000000.00	0	Y	Deposit	A	FIXED	5500.00	0.000000	0.00	0.00	0.1000	401.01	203.01	FEEDEP	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
FEEDEP	Phí nạp qua đại lý	DR	RVFEE	N	N	SYS	401.01	0.00	10000000.00	0	Y	Fee	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
PAYMENT	Thanh toán QR/merchant	DR	RVPAY	Y	Y	MOBILE	109.03.001	1000.00	100000000.00	0	Y	Payment	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
BILLPAY	Thanh toán hóa đơn	DR	RVBILL	Y	Y	MOBILE	109.03.001	1000.00	100000000.00	0	Y	Bill payment	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
AIRTIME	Nạp ĐT / data	DR	RVAIR	Y	Y	MOBILE	109.03.001	10000.00	5000000.00	0	Y	Airtime	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
SETTLE	Quyết toán merchant	CR	RVSETTL	N	N	SYS	109.03.001	0.00	5000000000.00	0	Y	Settlement	A	PERCENT	0.00	0.011000	0.00	100000000.00	0.1000	401.03	203.01	MDRFEE	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
MDRFEE	Phí chiết khấu MDR	DR	RVFEE	N	N	SYS	401.03	0.00	100000000.00	0	Y	MDR	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
CASHBACK	Hoàn tiền khuyến mãi	CR	RVCASH	N	N	SYS	502.01	1000.00	50000000.00	0	Y	Cashback	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
REFUND	Hoàn tiền giao dịch	CR	RVREF	N	N	SYS	109.03.001	1000.00	100000000.00	0	Y	Refund	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
ADJCR	Điều chỉnh tăng (ops)	CR	RVADJ	N	N	OPS	109.04.001	0.00	1000000000.00	0	N	Adjust CR	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
ADJDR	Điều chỉnh giảm (ops)	DR	RVADJ	Y	N	OPS	109.04.001	0.00	1000000000.00	0	N	Adjust DR	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
RVDEP	Đảo nạp đại lý	DR	\N	N	N	SYS	\N	0.00	500000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
RVPAY	Đảo thanh toán	CR	\N	N	N	SYS	109.03.001	0.00	100000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
RVBILL	Đảo TT hóa đơn	CR	\N	N	N	SYS	109.03.001	0.00	100000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
RVAIR	Đảo nạp ĐT	CR	\N	N	N	SYS	109.03.001	0.00	5000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
RVSETTL	Đảo quyết toán	DR	\N	N	N	SYS	109.03.001	0.00	5000000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
RVCASH	Đảo cashback	DR	\N	N	N	SYS	502.01	0.00	50000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
RVREF	Đảo hoàn tiền	DR	\N	N	N	SYS	109.03.001	0.00	100000000.00	0	Y	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
RVADJ	Đảo điều chỉnh	BOTH	\N	N	N	SYS	109.04.001	0.00	1000000000.00	0	N	Reversal	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
TRFOUTF	Chuyển tiền nội bộ (miễn phí)	DR	RVTRF	Y	Y	MOBILE	\N	1000.00	100000000.00	0	Y	Transfer free	A	NONE	0.00	0.000000	0.00	0.00	0.0000	\N	\N	\N	SYSTEM	2026-05-31 11:23:31.383491+07	postgres	2026-05-31 11:23:31.383491+07	postgres
\.


ALTER TABLE public.wlt_tran_def ENABLE TRIGGER ALL;

--
-- PostgreSQL database dump complete
--

\unrestrict PJoagrWLTmBkBwHK5cj4fwWn2WI9xTrvsXqKvxpoRUOsMmlv3F1X1znZZbbYtXj

