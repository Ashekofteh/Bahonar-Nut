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
| 1 | Core — domain models, ranker, storage, transport | `done` | — |
| 2 | Adapter — Cullinan `PortalClient` + `ServerClock` | `done` | Phase 1 |
| 3 | Sessions — `SessionManager`, per-account jars, silent re-login | `done` | Phase 2 |
| 4 | Sniper — scheduler, state machine, ledger, dry-run | `done` | Phase 3 |
| 5 | Android — Persian RTL UI, accounts + aliases, fg service, alarms | `done` | Phase 3 |
| 6 | Windows — thin shell over shared core | `pending` | Phase 4, 5 |
| 7 | Reminders domain — alias chain, config, `composeNotification` | `done` | Phase 1 |
| 8 | Reminders digest — offline mirror, ledger reconciliation | `done` | Phase 3, 7 |
| 9 | Reminders platform — scheduler, notifications, screens | `done` | Phase 5, 8 |
| 10 | Hardening — battery profiling, Doze tests, OCR fallback | `in progress` | Phase 4, 9 |
| 11 | Reservations — the table, the booking sheet, the cancel | `done` | Phase 2, 5 |
| 12 | Top-up — the ePay flow, the bank gateway, the payment list | `done` | Phase 2, 5 |

**The five portal workflows, all in the app** (the app's purpose is that the
student never has to open the web portal):

| Workflow | Where it lives | State |
|---|---|---|
| Account top-up / balance recharge | the accounts screen → the top-up sheet → the bank's gateway | done, live |
| Meal booking / reservation | the reservations table → the booking sheet | done, live |
| Viewing active reservations | the reservations table, and the dashboard | done, live |
| Locked / past-cutoff days | shown as locked on the table, from the portal's clock | done, live |
| Cancelling an eligible reservation | the row's cancel button | done, live |

**Phase 5 progress:** the Persian RTL app shell, the accounts screen (with the
alias chain), the reservations screen, the finance dashboard (multi-select
filters, Toman) and the reminders screen are built and **verified on a real
Android 14 emulator** — the reservations screen shows live portal data, and a
reminder alarm fires, posts its Persian digest and re-arms itself. The
foreground service, the exact alarms, the Android Keystore-backed stores and
the real portal wiring are all done and on the device.

**Phases 11 and 12 progress:** the reservations screen is now a **table** of
the days that can still be acted on — the held meals with their prices in
Toman, the locked days shown as locked, and a tap on a bookable row opening
a booking sheet. The full **book → cancel → re-book cycle** is proven against
the live portal: the reservations went 7 → 6 → 7, the credit 75,000 →
225,000 → 75,000 Rial, and the transactions 50 → 51 → 52, with the app's
screen and the portal agreeing at every step. The **top-up** is in the app
too: the amount and the bank on a sheet, the payment handed to the bank's own
gateway in a WebView, and the settlement read from the portal's payment list
rather than from the balance (a top-up is credited asynchronously, so the
balance lies for a while).

**Phase 2 progress:** the full `PortalClient` is implemented and live-proven.
The **write** paths have been exercised against the live portal: a weekly
reservation was booked and cancelled, and a Food Basket meal was purchased and
verified. The portal's own failures — a silently refused locked date, a
purchase that lands only in the ledger — are handled and covered by tests
against captured pages.

**Phase 9 progress:** the reminder alarms are armed from the configuration,
a fired alarm reaches the Dart side as its own method, and the delivery posts
the digest and re-arms the slot. The digest is scoped to the day it fires
for, and the mirror holds only the meals that are still ahead.

**Phase 10 progress.** The **CAPTCHA fallback is done and verified on the
device**: when the on-device solver declines, the student is asked to read the
code, and the answer is accepted — proven live, with the code read off the
image, typed, and the dashboard rendering the balance afterwards. The part that
made it work is that the portal judges the answer against the **session** the
image was fetched in, so the challenge now carries its session id and the answer
is posted back in it. That is what makes the student's reading time safe, and
what lets the app keep reading the portal while they read.

**Still to come in phase 10:** battery profiling (the duty cycle and the radio
wake-ups), Doze and OEM-killer behaviour under a long hunt, and a live read of
the request budget against the portal. Phase 6, the Windows shell, remains the
one untouched platform — by design, it is a free-rider.

**Transport** (phase 1 remainder) is done: per-account cookie jars, Date-header
capture, explicit redirect following, HTML parsing.

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
