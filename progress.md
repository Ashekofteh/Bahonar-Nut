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
