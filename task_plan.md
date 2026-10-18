# Task Plan — Food Basket App

**Goal:** A Flutter (Android-first, Windows secondary) client that automates an Iranian
university dining portal: multi-account management, seamless login, native meal
reservations, balance checks, and automated Food Basket monitoring with priority-ranked
auto-reserve ("sniping") — optimized for Persian RTL and minimal mobile resource use.

**Success criteria:**
1. Wins basket races without triggering portal rate limits or account bans.
2. Runs reliably in the background through Android Doze / OEM task killers, or fails visibly.
3. Battery cost is dominated by *radio wake-ups avoided*, not features sacrificed.
4. Credentials never leave the device.
5. Handles the money-path correctly: no double-purchase on an ambiguous claim.

**Owner:** Founder (Tier 1). Workers report upward; they do not rewrite this file.

---

## Phase Status

| # | Phase | Status | Blocked by |
|---|-------|--------|-----------|
| 0 | Recon — inspect portal, map auth + endpoints | `complete` | — |
| 1 | Core — domain models, ranker, storage, transport | `partial` | — |
| 2 | Adapter — Cullinan `PortalClient` + `ServerClock` | `partial` | Phase 1 |
| 3 | Sessions — `SessionManager`, per-account jars, silent re-login | `pending` | Phase 2 |
| 4 | Sniper — scheduler, state machine, ledger, dry-run | `pending` | Phase 3 |
| 5 | Android — Persian RTL UI, accounts + aliases, fg service, alarms | `pending` | Phase 3 |
| 6 | Windows — thin shell over shared core | `pending` | Phase 4, 5 |
| 7 | Reminders domain — alias chain, config, `composeNotification` | `pending` | Phase 1 |
| 8 | Reminders digest — `DigestBuilder` + sessions | `pending` | Phase 3, 7 |
| 9 | Reminders platform — scheduler, notifications, screens | `pending` | Phase 5, 8 |
| 10 | Hardening — battery profiling, Doze tests, OCR fallback | `pending` | Phase 4, 9 |

**Phase 2 progress:** CAPTCHA solver complete and validated (100% on 90 live
samples), live read-only login proven. Remaining in phase 2: the full
`PortalClient` implementation for basket/reservations/balance/claim.

**Phase 7 is Android-free** — pure Dart, VM-testable, parallelisable with 3–5.

See `docs/superpowers/specs/2026-10-18-reminders-and-aliases-design.md` for the
reminders subsystem (phases 7–9).

**Reconnaissance Milestone Achieved (2026-10-18):**
- Target verified: `https://nut.uk.ac.ir/` (Cullinan v8.10.27.1 on IIS 10).
- CAPTCHA format decoded: 4 digits, 235x40 GIF, fixed bounding box `x=[76..155], y=[9..33]`, isolated cleanly via luminance thresholding >185.
- Business rule confirmed: Cutoff is **20:00 (8:00 PM), 2 days prior to target date** (Announcement 2091).
- Unsold basket listings incur penalty (Announcement 2090), creating continuous secondary supply.
- **Authenticated recon complete (live login):** full page inventory mapped
  (Reservation hub, Cafeteria, BasketBuy, BasketSale, ePay, Transactions, ForgotReceipt).
  Lock semantics empirically confirmed (current week locked, next-week Sat editable).
  Security questions answered read-only: lock not bypassable via supported paths;
  top-up correctly outsourced to Shaparak PSPs; no evidence of reserve-without-balance.
  Dual balances observed: main credit 225,000 Rial vs cafeteria credit 0 Rial.
  Halls: مرکزی برادران (1), فنی برادران (2). No `__EVENTVALIDATION` on any page.

---

## Architecture (approved 2026-10-17)

```
Platform shells (thin)          Android = priority | Windows = free-rider
  ↓
Flutter UI (Persian RTL)        accounts · reservations · basket · rules · logs
  ↓
Domain core (platform-agnostic Dart)
                                Scheduler · PriorityRanker · SnipeStateMachine
                                SessionManager · Ledger
  ↓
Portal Adapter ← THE fragile boundary (only portal-aware layer)
                                LoginPage · BasketAPI · ReserveAPI · Balance
                                ServerClock (authoritative 48h boundary)
  ↓
Transport                       HTTP · cookie jar · backoff · circuit breaker
                                · request budget
  ↓
Secure storage                  Android Keystore / Windows DPAPI
```

**Invariant:** when the university redesigns their site, exactly one layer breaks.

---

## Locked Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Stack | **Flutter** | True native Android, RTL built in, <9MB portable runtime for Windows reuse |
| Login strategy | **Session-persistence first**, OCR fallback | Superset of the CAPTCHA problem; removes the largest ban surface |
| UI | **Native Flutter screens** | WebView cannot run in background for hours without destroying battery |
| Priority model | **Ordered (hall, option) pairs** + reject + max-price cap | Auditability under auto-buy — readable top-to-bottom before it spends money |
| Sniping | **Auto by default, tunable per rule** | User's risk tolerance; mitigated by dry-run + caps |
| Monitoring | **On-device, no server** | Credentials never leave the phone |
| Time source | **Server clock authoritative** | Device clock drift breaks 48h boundary logic |

---

## Hard Correctness Rules (non-negotiable)

1. **Never trust the device clock for cutoff logic.** Derive time from server response headers.
2. **Never retry an ambiguous claim.** On timeout, re-fetch orders to establish ground truth.
   A blind retry can buy two meals.
3. **One in-flight claim per account**, serialized.
4. **Claimed-and-lost listing IDs go into cooldown tombstones** and are never re-attempted.
   Re-polling dead listings is the request pattern that looks like an attack.
5. **Session pre-flight before the hunt window opens**, never during it.
6. **Hard polling floor + per-account request budget.** Aggressive is a setting; abusive is not.
7. **Windows never dictates core design.** It inherits; it does not constrain.

---

## Errors Encountered

| Error | Attempt | Resolution |
|-------|---------|-----------|
| (none yet) | | |

---

## Session Log Pointer

See `progress.md`. Research and portal findings go in `findings.md`, never here —
this file is auto-injected by hooks and untrusted content would amplify on every call.
