# Progress Log — Food Basket App

Append-only. Newest entries at the bottom.

---

## 2026-10-17 — Session 1: Discovery, audit, and architecture approval

**Founder (Tier 1).**

### What happened

1. **Environment recon.** `D:\Bahonar-Nut` found empty — no repo, no code, no brief.
2. **Invoked `brainstorming`** (mandatory pre-execution gate). Classified the request as
   **architectural** (new project, no existing flow to modify). Announced the path to the
   user before proceeding.
3. **Delivered Founder's Audit** — 7 defects in the brief:
   - CAPTCHA-solving may be a problem the user doesn't have (session persistence may suffice).
   - 48h lock likely governs *transfers* too, not just bookings — brief omitted this.
   - Two 48h clocks will desync (server vs device) — must use server time.
   - "Present the website interface" taken literally means building a full browser.
   - Storing N users' university passwords had no stated threat model.
   - "Safe polling interval" is an economic problem, not a constant.
   - Windows scope dilutes Android, which the user said is the priority.
4. **User decisions collected (3 rounds of alignment questions).**
5. **Architecture presented and approved** by the user.
6. **Invoked `planning-with-files`** and initialized `task_plan.md`, `findings.md`,
   `progress.md` on disk as the coordination spine.

### Decisions locked

| # | Decision | Choice |
|---|---|---|
| D1 | Stack | Flutter, Android-first, Windows secondary |
| D2 | Login strategy | Session-persistence first; OCR fallback only if needed |
| D3 | UI approach | Native Flutter screens; WebView only for top-up + rare flows |
| D4 | Priority model | Ordered `(hall, option)` pairs + per-row reject + max-price cap |
| D5 | Sniping mode | Auto by default, tunable per rule (Founder safeguard: dry-run + caps) |
| D6 | Monitoring location | On-device only; no server holds credentials |
| D7 | Org calibration | Right-sized — 3 departments, not 6 |

### Skills invoked this session

| Skill | Status | Notes |
|---|---|---|
| `brainstorming` | ✅ invoked | Architectural path; approval gate respected |
| `planning-with-files` | ✅ invoked | Planning spine written to disk |
| `karpathy-guidelines` | ⏳ pending | Loads for every coding agent in Phase 1+ |
| `design-dna` | ⏳ pending | Loads when UI work starts (Phase 3) |
| `brandkit` | ⛔ deliberately off | Utility app; brand identity is not a differentiator |
| `scrollcraft` | ⛔ deliberately off | Motion craft fights the resource-optimization goal |
| `agentic-actions-auditor` | ⏳ conditional | Fires in Phase 6 **only if** CI workflows are shipped |

**Note on the two declined skills:** these are declined with stated reasoning, not
forgotten. If the user later wants a distinctive visual identity, revisit.

### Files created

- `task_plan.md` — phases, locked decisions, hard correctness rules
- `findings.md` — portal facts, inferences I1–I3, risk register R1–R8, open questions Q1–Q8
- `progress.md` — this file

### Errors

None.

### Blockers

**Q1 — Portal URL is the critical path.** Phases 0 and 2 cannot start without it.
Phases 1, 3, 4, 5 are site-independent and unblocked.

### Files created (continued)

- `docs/superpowers/specs/2026-10-17-food-basket-app-design.md` — full design spec

### Spec self-review (2026-10-17)

Ran the required placeholder / consistency / scope / ambiguity pass. **Two defects found
and fixed inline:**

| # | Defect | Fix |
|---|---|---|
| SR1 | §4.4 `SnipeRule` used Flutter's `TimeOfDay`, violating the §3.1 rule that the domain core must not import `flutter/*` — it would have broken VM-only unit testing in Phase 1 | Introduced pure-Dart `ClockTime` value type |
| SR2 | Window times were ambiguous between device-local and server-local. A user travelling abroad would set "11:00–14:00", get device-local behaviour, and **silently miss every window** | Specified `windowStart`/`windowEnd` as **server-local**, with UI indicator when it differs from device timezone |

Also completed during the pass: added `DateTarget` enum (previously used undefined),
sealed-class clarification on `ClaimResult`, and the full open-risk table.

### Errors

None.

## 2026-10-18 — Session 2: Live Portal Reconnaissance (Phase 0)

### Findings from https://nut.uk.ac.ir/

1. **Host accessibility:** Fully reachable directly from the local environment over HTTPS.
2. **Software:** سامانه تغذیه کالینان (Cullinan v8.10.27.1) by شرکت پدیده عصر فناوری کویر سبز یزد.
3. **Framework:** Microsoft-IIS/10.0 + ASP.NET WebForms (`__VIEWSTATE`, `__VIEWSTATEGENERATOR`).
4. **Login mechanics:**
   - Plaintext credentials transmitted (`loginSecurtxt` = `False`).
   - `txtUsername` (Student ID) and `txtPassword` (Password/National ID).
   - Form submitted via `btnLogin` (value `ورود سمت سرور `).
   - Server errors returned in `<label id="lblLoginError">` on HTTP 200.
5. **CAPTCHA mechanics:**
   - Served from `UserControls/Captcha.ashx`.
   - Requires active session; server allocates `Session["Captcha"]` only when the image is fetched.
   - 235x40 GIF containing exactly 4 numeric digits.
   - Digits sit in a fixed bounding box `x=[76..155], y=[9..33]` with dark background cross-hatching.
   - Thresholding at luminance >185 isolates digits completely.
6. **Critical business rule discovery (Announcement 2091):**
   - **Reservation cutoff is NOT a rolling 48-hour clock.**
   - Official rule: **"رزرو غذا جهت هر وعده ی غذایی تا ساعت ۲۰ دو روز قبل امکان پذیر می باشد."** (Until 20:00 / 8:00 PM, 2 calendar days prior to the target date).
7. **Food basket incentive mechanism (Announcement 2090):**
   - If a student puts a meal up for sale in the basket and it goes unsold, it counts as an uneaten meal and incurs a monetary penalty. This drives active supply into the basket.


## 2026-10-18 — Session 3: Authenticated Recon (live login)

### What happened

1. User supplied credentials for 401405035. First login attempt failed: an intermediate
   page re-GET between CAPTCHA fetch and POST rotated the BotDetect session binding.
2. Second attempt — single continuous session, no intermediate requests — succeeded.
   Redirected to `Reservation/Reservation.aspx`.
3. Mapped 7 authenticated pages read-only (GET + navigation postbacks only):
   Reservation hub, Cafeteria, BasketBuy, BasketSale, ePay, Transactions, ForgotReceipt.
   **No reservation, payment, cancellation, or basket action was submitted.**
4. Empirically confirmed lock semantics: current week fully `disabled`; next-week
   Saturday 1405/08/02 rows editable.
5. Answered the user's three security questions by read-only analysis (see findings.md).
   Declined to probe payment/reservation bypasses with live submissions.

### Key corrections to prior assumptions

| # | Was | Now |
|---|---|---|
| C1 | "Two menu options per meal" = dish A vs dish B | **SUPERSEDED 2026-10-18 by user:** unsubsidized (بدون یارانه) tier is never used / non-functional. Original (hall, dish) pair model stands; adapter filters to subsidized only |
| C2 | CAPTCHA answer stable per session | Answer binds at image-fetch time; ANY page re-GET rotates it. Adapter must do GET-page → GET-captcha → solve → POST as an atomic sequence |
| C3 | Single balance | **SUPERSEDED 2026-10-18 by user:** cafeteria credit is legacy from a closed dining hall, always 0, never used. Single main credit only |

### Errors

| Error | Attempt | Resolution |
|---|---|---|
| `کد امنیتی صحیح نمی باشد` on first login | 1 | Removed intermediate page refresh; single continuous cookie session |
| `TaskUpdate` on stale task IDs from prior session | 1 | Listed tasks, recreated tracker, continued |

### Next actions

1. **User reviews the written spec** (required by the `brainstorming` skill's review gate).
2. Phase 1 + 4 kickoff: scaffold Flutter project (`git init` first — repo still doesn't exist),
   implement domain core per frozen `PortalClient` interface.
3. Phase 2 adapter now has exact field names, grid IDs, and the atomic login sequence.
4. Recommend user **change their portal password** (shared in chat; also transmitted as
   plaintext POST by the portal itself).

## 2026-10-18 — Session 4: Toolchain Setup & Scaffold

### What happened

1. Installed Flutter **3.47.7 stable** (Dart 3.13.5) to `D:/flutter`.
2. Wired `scripts/env.sh`: `FLUTTER_ROOT`, `JAVA_HOME` (JDK 17), `ANDROID_HOME`,
   `GRADLE_USER_HOME`. **Note:** PATH entries must use POSIX `/d/...` form in Git Bash —
   Windows-style `D:/...` entries do not resolve for command lookup.
3. Installed Android platform 36 + build-tools 36 (SDK was at 32, below Flutter's
   minimum). Accepted all SDK licenses.
4. `flutter doctor` → **No issues found!**
5. Scaffolded project: `flutter create . --project-name bahonar_nut --org ir.ac.uk
   --platforms=android,windows`. Existing `.gitignore`, docs, and planning files preserved.
6. `flutter test` → passes. `flutter build apk --debug` → **144MB debug APK built**.

### Errors

| Error | Attempt | Resolution |
|---|---|---|
| Flutter SDK download returned 250-byte XML error | 1 | My URL had a duplicated `releases/` segment. Used `base_url` + `archive` from the release manifest — byte-exact 1,934,624,561 bytes |
| `flutter: command not found` after `export PATH="D:/flutter/bin:$PATH"` | 1 | Git Bash needs POSIX `/d/flutter/bin`. Fixed in `env.sh` |
| **APK build failed: `No space left on device`** | 1 | **C: was at 0 bytes free (100%)** — Gradle writes there. Not a toolchain fault |
| APK build failed in 1s on retry | 2 | Cached failure; needed real free space |
| Build OOM risk from default `-Xmx8G` | — | Reduced to `-Xmx3G`, redirected `GRADLE_USER_HOME` and `buildDir` to D: |

### Critical environment constraint

| Drive | Size | Free | Note |
|---|---|---|---|
| **C:** | 201G | **5.5G** | Near-full. Gradle defaults here — **this broke the first build.** |
| **D:** | 752G | 40G | Project + Flutter + Gradle home live here |

**Mitigation now in place:** `GRADLE_USER_HOME=/d/gradle-home` and
`org.gradle.project.buildDir=D:/Bahonar-Nut/.gradle-build`, so builds no longer
consume C:. C: held at 5.5G free through a full successful build.

### Commits

- `0e28b7f` — architecture, design spec, authenticated recon
- `1dc51a7` — Flutter scaffold + verified toolchain

### Next actions

Phase 1 (domain core) + Phase 4 (sniper engine) — both site-independent, per the
frozen `PortalClient` interface in the spec. `karpathy-guidelines` loads for all
coding agents. Start with pure-Dart domain types and `PriorityRanker`, tested on the
VM with no Flutter dependency (spec §3.1 invariant).

## 2026-10-18 — Session 5: Phase 1 Domain Core

**Skill invoked:** `karpathy-guidelines` (mandatory for all coding work).

### Delivered

| Module | Contents |
|---|---|
| `lib/core/models.dart` | IDs, MealSlot, ReservationState, Hall, MenuOption, MealOffering, Reservation, Listing, Balance |
| `lib/core/time.dart` | Pure-Dart `ClockTime`, `ServerClock`, cutoff arithmetic for the 20:00 two-days-prior rule, `firstReservableDate` |
| `lib/core/priority.dart` | `PreferencePair`, `SlotPreference`, `PriorityRanker`, `RankResult`, veto + price ceiling |
| `lib/core/polling.dart` | `PollingPolicy` (jitter, exponential backoff, hard floor), `RequestBudget`, `CircuitBreaker` |
| `lib/core/snipe.dart` | `SnipeState`, transition table, `SnipeRun`, `SnipeRule`, `DateTarget`, `MatchAction` |
| `lib/core/portal.dart` | `PortalClient` interface, sealed `ClaimResult`, `Session`, `LoginChallenge`, `BasketPage` |

### Verification

- **89 tests pass** under plain `dart test` (not `flutter_test` — which is itself
  the proof that the core stayed Flutter-free).
- `flutter analyze lib test` → **No issues found!**
- Architecture test enforces §3.1: core must not import `package:flutter`, `dart:ui`,
  or `dart:io`. Fails loudly with file paths if violated.

### Notable test coverage

- **48-point sweep** across the cutoff boundary proves `firstReservableDate` is
  correct at every half-hour of a day — the bug class that would otherwise cause
  phantom 4xx storms from early snipes.
- **Exhaustive property test** over all 16 subsets of a 4-listing inventory proves
  `PriorityRanker` always picks the highest-ranked eligible listing.
- **Veto sweep** across all 4 ranks proves correct fall-through.
- **Reachability test** proves every state is reachable from `idle` and terminal
  states are truly final.

### Errors

| Error | Attempt | Resolution |
|---|---|---|
| `PollingPolicy` assertion failed: `jitterMax must be >= 1` | 1 | **Test was wrong, code was right.** My aggressive-test policy used `jitterMax: 0.2`, but jitter must never scale intervals *below* base. Fixed the test |
| **Off-by-one in exponential backoff** | 2 | **Real bug caught by tests.** `1 << (failures - 1)` gave no backoff on the first failure (1× instead of 2×), so a failing portal kept being hammered at base rate. Changed to `1 << failures` |
| Jitter bounds compared ms against seconds-valued constants | 1 | Test bug; bounds were `80`/`120` for a 100s base instead of `80_000`/`120_000` |

**The backoff bug is worth noting:** it was a genuine defect that would have made
the app's retry behaviour materially more aggressive than designed exactly when
things were going wrong — the worst possible failure mode for ban avoidance. Tests
caught it before any code touched the live portal.

### Commit

`81c9f98` — Phase 1 domain core

### Remaining in Phase 1

- Transport layer (HTTP, cookie jar, `HeaderServerClock` from response headers)
- Secure storage (`Keystore`/DPAPI abstraction)
- The `SnipeEngine` orchestration that wires scheduler + ranker + client together

## 2026-10-18 — Session 6: CAPTCHA Solver & First Live Login

**User authorised read-only live probing.** Scope held strictly to reads: login,
balance, basket, reservations. No reserve/claim/cancel/top-up was ever submitted.

### Delivered

- `lib/adapter/captcha_solver.dart` — pure-Dart 4-digit solver
- `lib/adapter/captcha_templates.g.dart` — generated glyph templates
- `scripts/gen_captcha_templates.py` + `scripts/captcha_labels.json` — reproducible
  regeneration with a leave-one-out self-check that refuses to emit bad templates
- `tool/live_login_check.dart` — live read-only login probe
- `test/adapter/captcha_solver_test.dart` — 5 tests, including 90 real samples

### Measured accuracy

| Set | Result |
|---|---|
| Leave-one-out, 60 training samples | **60/60** |
| Unseen holdout, 30 samples | **30/30** |
| Threshold sweep 150–205 | **100% at every value** |

### Live proof

Logs in to `https://nut.uk.ac.ir` for real with no human reading the CAPTCHA:

```
3. solved: 5327 (confidence 4145.076)
4. LOGIN OK (302 -> /Reservation/Reservation.aspx)
5. credit: 225,000 ریال
6. basket listings parsed: 3
```

### Errors

| Error | Attempt | Resolution |
|---|---|---|
| Solver Dart/Python mismatch (83% accuracy) | 1 | Python templates were bilinear-resampled; Dart used nearest-neighbour. **Root cause was resampling itself.** Dropping resize and cropping at native 24×31 restored 100% |
| Greedy glyph clustering split into 39–56 groups | 2 | Abandoned unsupervised clustering. Hand-labelled + computational validation instead |
| k-means k=10 gave skewed clusters (47 vs 11) | 3 | Same conclusion — labels needed, then verified by LOO |
| Live login failed with correct CAPTCHA reading | 1 | **Client bug, not solver.** Dart's `HttpClient` followed the 302 but my code treated the followed response as the failure page. Fixed with `followRedirects = false` + explicit redirect handling. Verified the solver was right by reading the challenge image by eye |
| Added `badCertificateCallback => true` defensively | 1 | **Removed.** The cert is a valid wildcard (`CN=*.uk.ac.ir`, Certum) that verifies cleanly. The workaround masked nothing and violated spec §8 |
| `captcha_templates.g.dart` silently not committed | 1 | Blanket `*.g.dart` gitignore rule swallowed it. Added a narrow `!` negation so the checked-in templates survive the codegen rule |

### Note on the security workaround

Worth recording because it's a near-miss: I added a TLS-validation bypass while
debugging, and the reflex was to leave it in "since it works". Checking the
certificate showed it was perfectly valid — the workaround was unnecessary. That
is the failure mode where a debugging convenience becomes a permanent
vulnerability. Removed, and the probe now validates certificates strictly.

### Commit

`89d77a9` — CAPTCHA solver + live login probe

## 2026-10-18 — Session 7: Reminder Design + Phase 7 Implementation

### Requirements added by the product owner

1. **Suppress reminders on closed cafeteria slots.**
2. **Next-week reservation nudge** — six checks from Wednesday noon to Thursday
   evening, warning if the coming week is unbooked.
3. Account aliases (from session 6, landed in the spec).

### Verified the service calendar against live data

Two weeks of captured grids agree exactly, and the pattern is **wider than
stated**: Thursday dinner and all of Friday were named by the product owner, and
Saturday breakfast + Friday breakfast follow from the same rule (breakfast ships
with the previous night's dinner). Encoded as an explicit table with an
invariant test asserting every missing breakfast is explained by a missing
dinner.

### Design decision on the nudge

The six specified times would fire even when the week was already booked, which
trains the user to ignore the alert. Modelled them as **check times, not
guaranteed fires**: each reads state and speaks only on a gap, with escalation so
a persistent gap re-fires while a booked week falls silent after the first check.

### Delivered (phase 7 — pure Dart, no Flutter, no network)

| Module | Contents |
|---|---|
| `lib/core/service_calendar.dart` | Weekday serving table, advisory; portal grid wins |
| `lib/core/persian.dart` | Jalali conversion, Persian digits, Rial/clock formatting |
| `lib/core/reminder.dart` | `ReminderConfig`, `ReminderDigest`, failures, `NotificationText` |
| `lib/core/next_week.dart` | `BookingGap`, `NextWeekStatus`, `detectNextWeekGaps` |
| `lib/core/reminder_compose.dart` | Pure composers for digest and nudge |

**193 tests pass, analyzer clean.**

### Errors

| Error | Attempt | Resolution |
|---|---|---|
| `ReminderFailure` defined in two files | 1 | Consolidated into `reminder.dart`; `next_week.dart` imports it |
| Absurd expression in the deadline line (`month == 0 ? 20 : 20`) | — | Caught on re-read; now renders `ClockTime.cutoff` |
| Composer test expected `۲ مهر`, output was `۲ آبان` | 1 | **Test was wrong, code was right.** Oct 24 is Aban (08/02); Mehr ends 07/30 |
| Cutoff tests assumed the whole week locks at once | 2 | **Test assumption was wrong.** Deadlines are per-meal: on a Friday the coming Saturday is locked while the following Tuesday is open. Code was right; spec §4A.1 corrected |
| `const DateTime.utc(...)` in a test top level | 1 | Not a valid const expression; made it `final` |

### Insight worth keeping

**The deadline is per-meal, not per-week.** Discovered by a failing test rather
than by reasoning, and it changes the nudge's behaviour: the gap list shrinks
progressively across the week instead of switching from full to empty. Recorded
in spec §4A.1.

### Commit

`2004f36` — phase 7 implementation

## 2026-10-18 — Session 8: Session Management (Phase 3)

**Goal:** unblock the snipe engine, the reminder digest, and the aliases screen —
all three depend on knowing how to hold an authenticated session.

### Delivered

| Module | Contents |
|---|---|
| `lib/core/session.dart` | `SessionStore`, `Credentials`, `ChallengeSolver`, sealed `SessionResult` |
| `lib/core/session_manager.dart` | Reuse-first lifecycle, per-account serialisation |
| `lib/core/time.dart` | Added `SyncedServerClock` (RFC 1123 `Date` header, RTT-corrected) |

### The live answer that shaped the design

```
1. found a stored session (3 cookies)
   RESULT: stored session STILL VALID - no login needed
```

A session established in one process was loaded from disk and read an
authenticated page in a **later process**, with no login and no CAPTCHA.

**So reuse is the common path and the solver is a fallback.** That matters more
than it sounds: repeated automated logins are the loudest ban signal available,
and this means they mostly do not happen. Daily request cost is also far lower
than the design assumed.

### Error found in my own earlier recon

I had recorded "no anti-forgery token observed". **That was wrong** — the portal
does set `__AntiXsrfToken`, but only *after* authentication. The earlier note came
from inspecting the unauthenticated page, where it does not exist. Corrected in
`findings.md` and the spec, with the consequence stated: persist the **whole
cookie jar**, never a hand-picked subset, because a dropped portal-set cookie
fails on a write operation.

### Errors

| Error | Attempt | Resolution |
|---|---|---|
| Convoluted `ensureSession` locking, low confidence on correctness | — | Rewrote as a simple per-account promise queue before testing; documented why serialisation is required (CAPTCHA binds at fetch time) |
| `prefer_initializing_formals` lint on 4 injected fields | 1–3 | Tried `// ignore:` pragmas (wrong place), then considered disabling the lint. **The analyzer was right**: public fields with `this.x` formals is the clean idiom. Renamed; no suppressions needed |

**Worth noting:** the reflex on the lint was to silence it. That's the same
instinct as the TLS bypass two sessions ago — reach for the suppression instead of
asking whether the tool has a point. It did.

### Commit

`3687c78` — session management

## 2026-10-19 — Session 9: Snipe Engine (Phase 4)

**Goal:** assemble the tested parts into the loop that actually wins a listing.
Assembly, not invention — the ordering of decisions is the whole design.

### Delivered

| Module | Contents |
|---|---|
| `lib/core/tombstone.dart` | Per-account cooldown tombstones for dead listings |
| `lib/core/ledger.dart` | Bounded append-only audit log, dry-run flagged simulated |
| `lib/core/preflight.dart` | All-failures-collected precondition gate + ClaimReconciler |
| `lib/core/snipe_engine.dart` | `DefaultSnipeEngine` with injected sleep, ledger outlives runs |

Extended `SnipeRunStatus` with `withState`/`withPoll`/`withClaimed`/`withPurchase`
helpers (existing class, engine's direct requirement).

**278 tests pass, analyzer clean.**

### Money-path guarantees, proven by test

- An ambiguous claim is NEVER re-claimed (thrown and returned-ambiguous both go
  through reconcile-never-retry)
- Reconciliation matches on slot/date/hall, NOT listing id, because the portal
  assigns a fresh reservation id
- Reconciled-as-claimed records a real purchase (understating a charge would be
  its own kind of wrong)
- Dry-run never issues claim/reserve/cancel, but records what it would have done
- A lost listing is tombstoned after the first rejection, never re-polled

### Errors

| Error | Attempt | Resolution |
|---|---|---|
| Completed runs never removed from `_runs`: `isRunning` true forever, 13 test timeouts | 1 | `_runs.remove` in `finally`; ledgers retained in a separate `_ledgers` map so purchases stay explainable after the fact |
| reconcile-as-claimed wrote a note but no purchase, so `purchaseCount` understated the charge | 1 | Record `claimSucceeded` on reconcile-as-claimed |
| Stop-test raced the 400-request budget (instant sleep burns it in ms) | 1 | **Test was wrong, budget was right.** Assert immediately after start |

### Commit

`5eb80a5` — phase 4 snipe engine

## 2026-10-19 — Session 11: Transport + Portal Adapter (Phases 3a & 2)

**Goal:** turn the recon into working code, and validate it against the live
portal without touching money or meals.

### The correction that mattered

The recon snapshot had led to a wrong model of the Food Basket. `FoodBasketBuy.aspx`
is **not** a marketplace of other students' meals — it renders **the student's own
held meals** for one date, and the purchasable items live in each row's **food
dropdown**, one `<option>` per listing. A lunch row was seen carrying two options
(62726, 62729), each with its own menu id and price.

So a listing is `(date, slot, optionId)` — a **composite identity**, not a single
portal id. That changed `Listing.id`, which the tombstone set, the ledger and the
ranker all key on, so it was settled **before** the adapter was written rather
than retrofitted across three modules. `Listing.compositeListingId` builds it in
one place.

### Delivered

| Module | Contents |
|---|---|
| `lib/transport/cookie_jar.dart` | Per-account jars, HTTP-date parsing |
| `lib/transport/http_transport.dart` | GET/POST, Date-header capture, explicit redirects |
| `lib/transport/html_parsing.dart` | Minimal HTML parsing (selects, rows, inputs, Rial) |
| `lib/adapter/cullinan_parser.dart` | Page -> domain objects, pure functions |
| `lib/adapter/cullinan_client.dart` | The frozen `PortalClient` contract |

**325 pure-Dart tests + 1 widget test pass; analyzer clean.**

### Live validation (read-only)

```
1. challenge fetched: digits4 (3400 bytes)   solved: 4489
2. LOGIN OK - cookies: [ASP.NET_SessionId, keyId, __AntiXsrfToken]
3. server time: 2026-10-19 13:53:33.000Z
4. balance: 225000 Rial
5. reservations held: 6
6. offerings on 2026-10-19: 5
7. basket listings: 3
     2026-10-19|breakfast|62725  شیر/حلواشکری/نان/چای/قند (150000)
     2026-10-19|lunch|62726      چلو خورشت قیمه,ماست, میوه (350000)
     2026-10-19|lunch|62729      چلو خورشت مسما بادمجان,سالاد فصل, میوه (350000)
```

### Errors

| Error | Attempt | Resolution |
|---|---|---|
| **Login failed 4x against the live portal** | 1–4 | **`package:http`'s `Client.send` does NOT follow redirects** — the flag only applies to the convenience methods. The portal answers a successful login with a 302, so the adapter read the redirect page, judged success as failure, and reported "login failed". Redirects are now followed explicitly. This was the exact bug the earlier probe had already solved by following redirects, and I reintroduced it by assuming the flag worked |
| First hand-written Jalali→Gregorian algorithm was wrong (returned July for October) | 1 | **Derived the inverse by searching the already-verified `toJalali`** instead of writing a second algorithm. The pair is now correct by construction; round-trips tested over a full year, a leap year, and the Nowruz boundary |
| HTTP-date parser's token-cursor approach was wrong (time is one token, not three) | 1 | Replaced with direct regexes for the three standard formats |
| `getBytes` issued a *second* request | — | Would have fetched a **different** CAPTCHA than the login POST is judged against, since the portal binds the answer at fetch time. Now goes through the same request path |
| My parser test expectations were wrong (option ids and dates from the wrong fixture) | 1 | **The parser was right, my test was wrong.** Re-derived expectations from the actual fixture contents |
| `LoginChallenge.imageBytes` typed `List<int>` | — | Changed to `Uint8List`; the image decoders want bytes. Updated the two affected tests |

### Note on `__AntiXsrfToken`

The token only appeared in the cookie jar **after redirects were followed** —
because it is set on the page the login redirect lands on. This independently
confirms the earlier recon correction (the token exists, but only on
authenticated pages).

### Commit

`2b1d51a` — transport + adapter

## 2026-10-19 — Session 12: Live write-path capture (account 401157013)

**Requested:** lunch for Mehr 28, 1405 (Tuesday), dish Akbar Joojeh (چلو اکبرجوجه),
hall Central first with Engineering fallback.

**Outcome: refused — and the capture proves exactly why, rather than leaving it
as a guess.**

### Why: the date is locked

Mehr 28 = 2026-10-20; its cutoff was 20:00 on Mehr 26 (2026-10-16) — three
days before the run. The portal renders that row `disabled` and **silently
ignores** a reservation posted for it: no error label, no alert box, no state
change.

Before concluding that, the POST was verified to be correctly targeted: the
control **name** index (`$ctl05$chkReserve`) is exactly the 1405/07/28 row, with
`$ctl04$` = 07/27 and `$ctl06$` = 07/29 as neighbours, and `drpFood=62738` is
exactly Akbar Joojeh. So this is the server refusing a locked row, not a
client-side targeting error.

### The cutoff rule observed, not inferred

The same page shows the lock frontier at exactly the predicted place:
**1405/07/30 was the only editable row in the current week**, because its
cutoff (1405/07/28 20:00) had not yet arrived.

And the strongest evidence available: comparing the 2026-10-18 capture with
today's, **the frontier moved forward exactly one day**. Two observations, two
different days, same rule. This is now asserted as a test.

### Other facts established

- **No bookable Akbar Joojeh exists on this account.** Option 62738 appears only
  in the 1405/07/28 lunch row — the locked one. The published next week serves
  entirely different dishes.
- The **publish horizon is about one week**: weeks 1405/08/09 onward render
  every row as `-`.
- **The control `name` index and the `id` index differ** (`$ctl05$chkReserve` vs
  `chkReserve_3`): the name index counts data rows, the id index counts
  rendered rows including the header. **Parsing must use `name`** — which is
  what the POST sends.
- The server's error channel is `cphMain_alertBoxValue`, and a locked row
  bypasses it entirely.
- Write-path fields: `__VIEWSTATE`, `__VIEWSTATEGENERATOR`, the row's
  `chkReserve=on` / `drpSelf=<hallId>` / `drpFood=<optionId>` /
  `drpFoodCount=1`, and `btnSave{Breakfast,Lunch,Dinner}`. `__EVENTTARGET` is
  empty for a save (it is for navigation postbacks).

### What changed in the code

- `ReservationLockedException` — a distinct type, because the response looks
  identical to a successful-but-unrendered post. Without it, the engine would
  retry a date that can never be booked.
- `CullinanPortalClient.reserve` re-reads the row and raises it when the portal
  still renders the date as disabled.
- `test/adapter/locked_refusal_test.dart` — 7 tests asserting the refusal
  contract against the captured pages, including the two-day frontier movement.

### A mistake I made and corrected

I committed the capture directory (authenticated page snapshots, viewstate,
session cookies) to git. That is exactly the material the project deliberately
keeps out of history, and it was my error. Fixed by resetting the commit,
re-committing without the artifacts, adding `captures/` to `.gitignore`, and
deleting the backup branch — then verifying **no reachable commit contains a
capture**. The files remain on disk for analysis. The password was redacted in
the captured POST body, but the page snapshots still held the account holder's
name, id and balance.

### Tests

**332 pure-Dart tests + 1 widget test pass; analyzer clean.**

### Commit

`2f80688` — silent-refusal handling
