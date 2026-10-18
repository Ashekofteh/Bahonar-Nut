# Food Basket App — Design Specification

**Date:** 2026-10-17
**Status:** Approved architecture; interfaces frozen for parallel development
**Author:** Founder / Principal Architect (Tier 1)

---

## 1. Problem Statement

A university dining portal (**سامانه تغذیه کالینان / Cullinan v8.10.27.1** at **دانشگاه شهید باهنر کرمان**)
allows students to reserve meals. Per official University Regulation 2091, reservations close at **20:00 (8:00 PM) two days prior**
to the meal date (not a rolling 48-hour clock). Once the cutoff passes, the reservation locks. Students who hold an unwanted locked
meal can list it in the peer-to-peer "Food Basket" (سبد غذایی); students who missed the cutoff can purchase it.
Crucially, unsold basket items count as uneaten meals and incur financial penalties (Regulation 2090), creating a strong incentive
for students to list unwanted meals as early as possible.

The user wants an Android-first (with Windows secondary) client that manages multiple student accounts, solves the 4-digit
security code without friction, automates Food Basket monitoring and auto-purchasing according to strict user-defined priority rankings,
and operates safely without triggering rate limits or bans.

**The product is a race-winner, not a feature collection.** Every trade-off resolves
toward (1) not getting banned, (2) not losing the race, (3) battery efficiency.

---

## 2. Goals and Non-Goals

### Goals
- Multi-account storage with seamless re-login.
- Native Persian RTL UI covering accounts, reservations, basket, rules, and logs.
- Automated basket monitoring with priority-ranked auto-reserve.
- Correct money path: no double-purchase, no silent failure.
- Background reliability on Android despite Doze and OEM task killers.
- Minimal battery drain — measured as radio wake-ups avoided.

### Non-Goals (explicit YAGNI)
- A general-purpose browser.
- Any server component. Credentials never leave the device.
- Shared listing feeds or fleet coordination (ban risk + ToS).
- Brand identity work or motion craft.
- iOS. Architecturally possible via Flutter; not a target.

---

## 3. Architecture

### 3.1 Layers

```
┌──────────────────────────────────────────────────────────┐
│ Platform shells (thin)                                   │
│   Android (priority)          Windows (secondary)        │
│   fg service · alarms ·       tray · notifications       │
│   notifications                                          │
├──────────────────────────────────────────────────────────┤
│ Flutter UI — Persian RTL                                 │
│   accounts · reservations · basket · rules · logs        │
├──────────────────────────────────────────────────────────┤
│ Domain core — platform-agnostic Dart, no Flutter imports │
│   Scheduler · PriorityRanker · SnipeEngine · Ledger      │
│   SessionManager · ServerClock                           │
├──────────────────────────────────────────────────────────┤
│ Portal Adapter ← THE ONLY portal-aware layer             │
│   implements PortalClient                                │
├──────────────────────────────────────────────────────────┤
│ Transport                                                │
│   HTTP · cookie jar · backoff · circuit breaker · budget │
├──────────────────────────────────────────────────────────┤
│ Secure storage                                           │
│   Android Keystore / Windows DPAPI                       │
└──────────────────────────────────────────────────────────┘
```

**Design invariant:** when the university redesigns its site, exactly one layer
(`Portal Adapter`) breaks. Everything below is generic; everything above is
site-independent. This is what makes Phases 1/3/4 parallelizable with Phase 0.

**Dependency rule:** the domain core must not import `flutter/*`. It is pure Dart with
injected dependencies, so it is unit-testable on the Dart VM without a device — which is
also what makes it reusable on Windows for free.

### 3.2 Why a single adapter boundary beats a generic scraping framework

A "support any portal" abstraction would be over-engineering for one site. The adapter
is a **plain interface with one implementation**, plus a contract test suite. If a second
portal ever appears, the interface already exists; if it never does, we paid nothing.

---

## 4. Domain Model

### 4.1 Value types

```dart
/// Identifiers are opaque strings from the portal. Never parse them.
typedef MealId   = String;
typedef HallId   = String;
typedef OptionId = String;
typedef ListingId = String;
typedef AccountId = String;

enum MealSlot { breakfast, lunch, dinner }

/// A dining hall. Two exist today; do not hardcode the count.
class Hall { final HallId id; final String name; }

/// A menu option within a meal. Breakfast has exactly one.
class MenuOption {
  final OptionId id;
  final String name;
  final int priceRial;
}

/// A slot the user could reserve: a (date, meal, hall, option) tuple.
class MealOffering {
  final DateTime date;        // date only, no time component
  final MealSlot slot;
  final Hall hall;
  final MenuOption option;
  final bool reservable;      // false once past the server-side cutoff
}

/// A reservation the user holds.
class Reservation {
  final MealId id;
  final DateTime date;
  final MealSlot slot;
  final Hall hall;
  final MenuOption option;
  final ReservationState state;
}

enum ReservationState { active, cancelled, consumed, sold, unknown }

/// A listing in the Food Basket (someone else's released reservation).
class Listing {
  final ListingId id;
  final DateTime date;
  final MealSlot slot;
  final Hall hall;
  final MenuOption option;
  final int priceRial;
  final DateTime? expiresAt;  // server-reported, if present
}

/// Account balance snapshot.
class Balance {
  final int amountRial;
  final DateTime fetchedAt;
}
```

### 4.2 Time & Cutoff Logic: The `ServerClock`

**Crucial Domain Finding:** Per university regulation 2091, the reservation lock occurs at **20:00 (8:00 PM) two days prior** to the meal date (Tehran time / UTC+3:30), **not** a rolling 48-hour clock relative to meal distribution.

Example:
- Monday Lunch/Dinner cutoff = Saturday 20:00 (approx. 40-44 hours before the meal).
- Friday Lunch cutoff = Wednesday 20:00.

**Rule:** The device clock is never consulted for cutoff logic.
```dart
abstract class ServerClock {
  /// Server time as of the last successful response (Tehran time zone).
  DateTime get now;

  /// True once [now] is trustworthy (at least one sync succeeded).
  bool get isSynced;

  /// Returns true if reservations for the given target date have locked.
  /// Locks at 20:00:00 on (targetDate - 2 days).
  bool isLockedForReservation(DateTime targetDate);

  /// Exact DateTime when reservations lock for targetDate.
  DateTime reservationLockTime(DateTime targetDate);
}
```

Rationale: Android device clocks drift unmanaged, and users change timezones manually.
Computing "48 hours from now" locally produces either false refusals (app blocks a legal
reservation) or early snipes (a wall of 4xx responses that looks exactly like an attack).
A `ServerClock` also gives us the *staleness* signal needed for the pre-flight gate.

**Fallback policy:** if `isSynced` is false, the app **refuses to run auto-reserve** and
tells the user why. Guessing here risks both money and the account.

### 4.3 Priority model

The brief asked for option ranking *and* hall ranking. These conflict: a user may prefer
Option A and Hall Central, but Option A only exists in Hall Engineering.

**Resolution: one ordered list over `(hall, option)` pairs, with per-row reject.**

```dart
/// One row of the user's ranked preference for a given meal slot.
class PreferencePair {
  final HallId hall;
  final OptionId option;
  final bool rejected;   // explicit veto — never buy this
}

/// Full preference configuration for one meal slot.
class SlotPreference {
  final MealSlot slot;
  final List<PreferencePair> ranked;  // index 0 = highest priority
}
```

For lunch/dinner this is up to 4 rows (2 halls × 2 options); breakfast is 2. The rule
builder seeds rows from two quick taps ("rank halls", "rank options") and then allows
drag-to-reorder.

**Why not weighted scoring:** under auto-buy, a mis-tuned weight silently spends real
money. An ordered list is readable top-to-bottom — the user can look at it and know
exactly what will be bought. *When the action spends money, auditability beats
expressiveness.*

**Subsidized-only constraint (user-confirmed 2026-10-18):** the portal renders both
subsidized (یارانه‌ای) and unsubsidized (بدون یارانه) price tiers, but the unsubsidized
tier is non-functional and never used. The adapter MUST filter to subsidized offerings
only and never present or purchase unsubsidized rows. Likewise the "cafeteria credit"
balance field is legacy from a closed dining hall and always reads zero — the app tracks
the single main credit and ignores the legacy field.

### 4.4 The reservation rule

```dart
/// Time of day in the domain core. NOTE: deliberately NOT Flutter's `TimeOfDay`,
/// because §3.1 forbids the core from importing flutter/*. Defined here so the
/// core stays testable on the plain Dart VM.
class ClockTime implements Comparable<ClockTime> {
  final int minutesSinceMidnight;  // 0..1439
  const ClockTime(this.minutesSinceMidnight);
  @override int compareTo(ClockTime other) =>
      minutesSinceMidnight.compareTo(other.minutesSinceMidnight);
}

/// Which date a rule targets.
enum DateTarget {
  /// The current day, in the *server's* timezone.
  today,
  /// The first date beyond the 48h cut-off wall.
  firstAvailableAfterCutoff,
  /// An explicit date chosen by the user.
  explicit,
}

enum MatchAction { autoBuy, notifyOnly }

class SnipeRule {
  final String id;
  final AccountId account;
  final bool enabled;

  /// Time-of-day window (in the SERVER's timezone) during which polling
  /// is allowed, e.g. 11:00–14:00. Server-local, not device-local — see §4.2.
  final ClockTime windowStart;
  final ClockTime windowEnd;

  /// Which slots this rule may buy.
  final Set<MealSlot> slots;

  /// Target date resolution.
  final DateTarget target;
  final DateTime? explicitDate;  // required iff target == DateTarget.explicit

  final Map<MealSlot, SlotPreference> preferences;

  /// Hard price ceiling. Founder-added safeguard, not in the original brief.
  final int? maxPriceRial;

  /// Founder-added: simulate without purchasing.
  final bool dryRun;

  /// Stop after N successful purchases in one window. Prevents runaway spend.
  final int maxPurchasesPerWindow;

  /// How to act on a match.
  final MatchAction action;
}
```

**Timezone note (important):** the portal's servers define the 48h wall, so the user's
window times are interpreted in *server-local* time and displayed with an explicit
indicator when the two differ. A user travelling abroad would otherwise set "11:00–14:00",
get device-local behavior, and silently miss every window.

**Two safeguards the brief did not request, added deliberately:** `dryRun` and
`maxPurchasesPerWindow`. Under auto-buy, a priority-scoring bug spends real money on food
the user did not want. Dry-run lets them validate the ranking against live data first;
the purchase cap bounds the blast radius of any bug that survives.

---

## 5. The Snipe Engine

### 5.1 State machine

```
                    ┌──────────────────────────────────────┐
                    ▼                                      │
IDLE ──▶ PREFLIGHT ──▶ HUNTING ⟲──── MATCHED ──▶ CLAIMING ─┴─▶ CLAIMED
              │           │                          │
              │           │                          └──▶ LOST ────┐
              │           ├──▶ BACKOFF (transient)                 │
              │           ├──▶ CIRCUIT_OPEN (consecutive failures) │
              │           ├──▶ FAILED_AUTH                        │
              │           └──▶ WINDOW_EXPIRED                     │
              ▼                                                    │
        ABORTED (unsynced clock / no session / no funds)           │
                                                                   ▼
                                                              (tombstone,
                                                               no retry)
```

### 5.2 States

| State | Meaning | Exit |
|---|---|---|
| `IDLE` | Not scheduled or window not open | Alarm fires → `PREFLIGHT` |
| `PREFLIGHT` | Clock synced? Session valid? Funds ≥ cheapest ranked option? | All pass → `HUNTING`; else `ABORTED` |
| `HUNTING` | Polling basket on adaptive schedule | Match → `MATCHED`; window end → `WINDOW_EXPIRED` |
| `MATCHED` | Candidate selected by `PriorityRanker` | → `CLAIMING` (auto) or notify + await user |
| `CLAIMING` | Claim request in flight. **Serialized per account.** | Terminal below |
| `CLAIMED` | Confirmed gone from basket / order appears | Terminal |
| `LOST` | Someone else got it, or claim rejected | Tombstone listing; → `HUNTING` if window open |
| `ABORTED` | Preconditions unmet | Terminal, **user-visible** |
| `WINDOW_EXPIRED` | Window closed with no purchase | Terminal, logged |

### 5.3 The three failure modes that will definitely happen

**(a) Lost race.** Another student claims the listing between our poll and our claim.
*Naive handling* — re-polling the same dead listing immediately — is precisely the
request pattern that gets accounts banned.
**Rule:** a claimed-and-lost `ListingId` enters a **cooldown tombstone** and is never
re-attempted for the life of that listing.

**(b) Ambiguous claim — the dangerous one.** The claim request times out. Did it
succeed? **We do not know.** A blind retry can buy two meals and charge twice.
**Rule:** on any ambiguous outcome, **never retry the claim.** Re-fetch the reservation
list to establish ground truth, then reconcile state. One in-flight claim per account,
serialized by a per-account mutex.

**(c) Session dies mid-hunt.** The design answer is preventive, not reactive: a
**session pre-flight runs before the window opens**, not during it. If re-login is
required, it happens while the user can still intervene — not silently at 11:03 when the
hunt is live and the CAPTCHA will not OCR.

### 5.4 The engine interface

```dart
abstract class SnipeEngine {
  /// Starts a rule. Idempotent for an already-running rule.
  Future<void> start(String ruleId);

  /// Stops a running rule and releases platform resources.
  Future<void> stop(String ruleId);

  /// Live state for UI. Broadcast so the rules screen can render progress.
  Stream<SnipeRunStatus> watch(String ruleId);
}

class SnipeRunStatus {
  final String ruleId;
  final SnipeState state;
  final int pollCount;
  final DateTime? lastPollAt;
  final String? lastError;
  final ListingId? claimedListingId;
  final int purchasesThisWindow;
}
```

---

## 6. The Scheduler

### 6.1 The core resource insight

**On mobile, battery cost is dominated by radio wake-ups, not CPU.** Every poll wakes
the cellular or WiFi radio for seconds. The optimization target is therefore *fewer
network round-trips*, not smaller payloads — gzip and payload trimming are rounding
errors next to radio state transitions.

This single fact drives every scheduling decision below.

### 6.2 Policy

```dart
class PollingPolicy {
  /// Base interval. Adjusted by the factors below.
  final Duration baseInterval;

  /// Absolute floor. Below this the app refuses to go, regardless of config.
  /// Protects both the portal and the user's account.
  static const Duration hardFloor = Duration(seconds: 20);

  /// Multiplicative jitter range, e.g. 0.8–1.2.
  final double jitterMin;
  final double jitterMax;

  /// Consecutive failures before the circuit opens.
  final int failureThreshold;

  /// Requests allowed per account per window. Hard budget.
  final int requestBudget;
}
```

**Rules:**
1. **Jitter every interval** (`base × [0.8, 1.2]`). A fixed interval across many phones
   synchronizes into a self-inflicted DoS — on the portal *and* on the user's battery.
2. **Adaptive, not fixed.** Poll faster only when expected value is high (inside the
   window, recent listing activity, near the 48h boundary); slow and jitter when the
   market is quiet.
3. **Honor `Retry-After`** and back off exponentially on 429/5xx.
4. **Circuit-break** after `failureThreshold` consecutive failures and notify the user,
   rather than spinning.
5. **Hard floor + request budget per account.** Aggressive is a setting; abusive is not.
6. **Release the foreground service** the moment the window closes or a claim lands.
   Never a 24/7 service.
7. **No wake-locks held across sleeps.** Doze-aware, with an explicit and *explained*
   battery-optimization exemption request — never a silent one.

### 6.3 Android execution model

| Need | Mechanism | Constraint |
|---|---|---|
| Wake precisely at window open | `AlarmManager` exact alarm | Requires `SCHEDULE_EXACT_ALARM` on API 31+ |
| Poll during a live window | Foreground service | `FOREGROUND_SERVICE_DATA_SYNC`; released at window close |
| Pre-flight session/clock check | `WorkManager` | Runs before the exact alarm, opportunistically |
| Notify user | Notification channel | Persian copy, RTL-correct |
| Survive OEM task killers | Doze exemption | **Requested explicitly with rationale shown to the user** |

**Honest limitation:** if the phone is off, or the user force-stops the app, the window
is missed. The app must surface this as a *visible* catch-up message on next launch
rather than failing silently.

---

## 7. Portal Adapter

### 7.1 The interface — frozen before Phase 0

This is the contract Phases 1, 3, and 4 code against. It is defined now precisely so
that portal recon can proceed in parallel without blocking them.

Implemented in `lib/core/portal.dart`:

```dart
abstract class PortalClient {
  /// --- Auth ---
  /// Returns a login challenge (e.g. CAPTCHA image) if the portal demands one.
  Future<LoginChallenge?> beginLogin(String username);
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  });
  Future<Session> refresh(Session session);
  Future<void> logout(Session session);

  /// --- Time ---
  /// Server time, used to build a ServerClock. Authoritative for cutoff logic.
  Future<DateTime> fetchServerTime(Session session);

  /// --- Read ---
  Future<Balance> fetchBalance(Session session);
  Future<List<MealOffering>> fetchOfferings(Session session, DateTime date);
  Future<List<Reservation>> fetchReservations(Session session);
  Future<BasketPage> fetchBasket(Session session, {String? cursor});

  /// --- Write ---
  Future<ClaimResult> claim(Session session, ListingId listingId);
  Future<Reservation> reserve(Session session, MealOffering offering);
  Future<void> cancel(Session session, MealId mealId);

  /// --- Deep link ---
  Uri? topUpUrl(Session session);
}
```

**Cookie handling (corrected 2026-10-18).** The portal sets three cookies, and
`__AntiXsrfToken` is issued **only after authentication**. Implementations must
persist and replay the **entire cookie jar** rather than a hand-picked subset;
dropping a cookie the portal set surfaces as a failure on a write operation,
which is the worst possible time to discover it. Verified live: a persisted jar
reused across processes read an authenticated page with no login at all.

### 7.2 Result types must encode ambiguity explicitly

```dart
sealed class ClaimResult {
  const ClaimResult();
}
class ClaimSucceeded extends ClaimResult {
  final Reservation reservation;
}
class ClaimRejected extends ClaimResult {
  final String reason;   // e.g. "already claimed"
}
/// THE CRITICAL CASE: we do not know whether the claim landed.
/// The engine must reconcile, never retry.
class ClaimAmbiguous extends ClaimResult {
  final String diagnostic;
}
```

`ClaimAmbiguous` exists as a first-class type so that no caller can accidentally treat a
timeout as a plain failure. The type system enforces the money-path rule.

### 7.3 Recon targets (Phase 0)

| # | Question | Method |
|---|---|---|
| Q1 | Portal URL | user |
| Q2 | CAPTCHA type; login-only or per-request? | inspect |
| Q3 | Session cookie `Max-Age`/`Expires` | inspect after manual login |
| Q4 | Server-rendered forms vs XHR/JSON | inspect network tab |
| Q5 | Basket endpoint cost; pagination, page size | inspect |
| Q6 | **Does the 48h cutoff apply to transfers same as reservations?** | inspect rules text / test |
| Q7 | Top-up deep link constructible? | inspect |
| Q8 | Currency; is purchase debit atomic? | inspect |

**Q6 is the highest-value unknown.** If transfers are bound by the same wall, listings
only exist >48h out and the engine is a race against a shared deadline. If transfers are
*exempt* — plausible, since resale is the portal's own escape valve for the lock — then
the sniping problem is materially different and possibly easier.

### 7.4 Login & CAPTCHA Strategy: Dual-Engine

The portal's authentication is standard ASP.NET WebForms with:
- Endpoint: `https://nut.uk.ac.ir/` (POST `./`)
- Fields: `__VIEWSTATE`, `__VIEWSTATEGENERATOR`, `__VIEWSTATEENCRYPTED`, `txtUsername`, `txtPassword`, `txtCaptcha`, `btnLogin`
- CAPTCHA Image: `UserControls/Captcha.ashx` (requires cookie jar matching the ASP.NET session)

Reconnaissance revealed key properties of the CAPTCHA:
1. Format: 235x40 GIF, exactly 4 digits (`0-9`), no letters.
2. Geometry: Strictly confined to bounding box `x=[76..155], y=[9..33]`, height 25px.
3. Separation: Digits are white foreground on a dark patterned grid. Thresholding luminance at `>185` eliminates the grid completely.

**Dual-engine design:**
1. **Tier 1 — Session Persistence:** Session cookies (`ASP.NET_SessionId`, `keyId`) are stored securely. Re-login is only triggered when a request encounters an auth redirect or session expiration.
2. **Tier 2 — Local 4-Digit Solver:** When login is needed, the client downloads `UserControls/Captcha.ashx`, thresholds the image in pure Dart (no native C++ or external binaries needed), segments the 4 digit slots, and runs a lightweight digit recognizer on-device in <10ms.
3. **Tier 3 — Fallback UI:** If confidence on any digit is below 0.85, the app prompts the user with the cropped CAPTCHA image to enter the 4 digits manually.

---

## 8. Security Model

Threat: **N sets of university credentials on a phone that can be lost, stolen, or rooted.**

| Control | Implementation |
|---|---|
| Credential storage | Android Keystore-backed encryption; Windows DPAPI. Never plaintext. |
| Credential scope | Never leave the device. No server, no analytics, no crash-report payloads. |
| Logging | Interactive log redacted. **Never log** passwords, tokens, cookies, CAPTCHA images. |
| Screenshots | `FLAG_SECURE` on credential and balance screens. |
| Clipboard | No credential copy to clipboard. |
| Biometric gate | Optional lock before viewing stored accounts. |
| Session storage | Same encrypted store as credentials. Sessions are bearer tokens. |
| Network | HTTPS only; certificate validation never disabled, not even in debug builds. |

**Note on ToS:** this automates a portal the user does not own, using their own account
and credentials. Ban avoidance is the honest description of the polling design, and it
likely conflicts with the portal's terms of service. The user has been told this
explicitly and accepts the risk knowingly.

---

## 9. Persian RTL

- `MaterialApp.locale = fa_IR`, `Directionality` set RTL at the root.
- Persian (Jalali) calendar for all date display; the domain core stores Gregorian
  `DateTime` in UTC and conversion happens at the presentation boundary only.
- Persian digits for all user-facing numbers; **Latin digits for internal IDs and
  network payloads** (mixing these up is a classic and painful bug class).
- Currency formatted as Rial/Toman with correct grouping. *Confirm the portal's unit —
  a Toman/Rial confusion is a 10× error in every price shown.*
- Vazirmatn or similar as the bundled Persian font; bundled, not fetched, so the app
  works offline and does not leak a font-request signal.
- Icons and directional affordances mirrored; back-navigation direction reversed.
- Digits and mixed-direction strings (prices, times, IDs) tested explicitly — these are
  where RTL layouts break in practice.

---

## 10. Testing Strategy

| Layer | Approach |
|---|---|
| Domain core | Pure Dart unit tests on the VM. No device, no Flutter. |
| PriorityRanker | Property tests: given a ranking and an inventory set, the chosen item is always the highest-ranked available non-rejected one. |
| Snipe state machine | Deterministic simulation with an injected clock and a fake portal. Includes: lost race, ambiguous claim, session death mid-hunt, circuit-open. |
| PollingPolicy | Assert the hard floor is never breached; assert jitter distribution; assert budget exhaustion stops polling. |
| Portal adapter | **Contract tests** against recorded fixtures. Refuses to make live requests in CI. |
| Money path | Explicit test: `ClaimAmbiguous` never triggers a second claim. |
| Platform runtime | Manual/emulator: Doze, battery saver, low-memory kill, reboot mid-window. |

**Note:** the `SnipeEngine` must be testable without a network. A fake `PortalClient`
with scripted responses (including delaying a claim past the timeout to force
`ClaimAmbiguous`) is the highest-value test asset in the project.

---

## 11. Phasing and Parallelization

| Phase | Scope | Blocked on URL? | Owner |
|---|---|---|---|
| **0** Recon | Map auth, CAPTCHA, sessions, endpoints, transfer rules | **Yes** | Portal & Recon |
| **1** Core | Domain models, ranker, storage, transport, backoff | No | Core & Engine |
| **2** Adapter | `PortalClient` impl, `ServerClock`, contract fixtures | Yes | Portal & Recon |
| **3** Android | Accounts UI, RTL shell, fg service, alarms, notifications | Partial | Platform & Runtime |
| **4** Sniper | Scheduler, state machine, ledger, dry-run | No | Core & Engine |
| **5** Windows | Thin shell over shared core; tray, notifications | No | Platform & Runtime |
| **6** Hardening | Battery profiling, Doze tests, OCR fallback, failure injection | Partial | All + independent review |

**Critical path:** Q1 (URL) → Phase 0 → Phase 2 → Phase 6.
**Off critical path:** Phases 1, 3, 4, 5 — all site-independent, start immediately.

### Org assignment (right-sized)

| Department | Staffing | Owns |
|---|---|---|
| **Core & Engine** | Lead + 1 IC | Phases 1, 4 — domain, ranker, scheduler, state machine |
| **Platform & Runtime** | Lead + 1 IC | Phases 3, 5 — Flutter shell, RTL, fg service, battery |
| **Portal & Recon** | Lead + 1 IC | Phases 0, 2 — inspection, adapter, ServerClock, OCR |

QA and SecOps are real gates but do not warrant standing departments at this size;
verification folds into each lead's exit criteria, with **one independent review pass**
at Phase 6. `karpathy-guidelines` loads for every coding agent; `design-dna` for UI work;
`planning-with-files` is the coordination spine; `agentic-actions-auditor` fires at
Phase 6 **only if** CI workflows ship.

---

## 12. Open Risks

| Risk | Severity | Status |
|---|---|---|
| Account ban from request pattern | Critical | Mitigated by design (§6.2); residual risk accepted |
| Double-charge on ambiguous claim | Critical | Mitigated by type system (§7.2) + serialization |
| 48h cutoff semantics for transfers unknown | High | **Blocks engine semantics — Q6** |
| Android kills app; window missed | High | Mitigated by §6.3; residual risk is *visible*, not silent |
| Portal is a server-rendered SPA with no clean endpoints | Medium | Adapter absorbs; may force WebView for some flows |
| Toman/Rial unit confusion | Medium | Confirm in Phase 0 |
| CAPTCHA changes, breaking OCR | Low | Degrades to tier 2 (semi-automated) by design |
