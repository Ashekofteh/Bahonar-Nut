# Account Aliases & Reservation Reminders — Design Specification

**Date:** 2026-10-18
**Status:** Approved design; ready for implementation planning
**Depends on:** `2026-10-17-food-basket-app-design.md` (core architecture), session management (not yet built)

---

## 1. Problem Statement

Two gaps in the current design:

1. **Accounts are identified by student ID**, which is unmemorable and, for
   multiple accounts, hard to tell apart at a glance. The portal reveals the
   student's real name only after a successful login.

2. **Nothing helps the student actually reserve meals.** The sniping engine wins
   *released* listings, but the primary path — reserving ahead of the 20:00
   two-days-prior cutoff — is entirely manual. A missed cutoff means no meal, and
   because tomorrow's breakfast ships with tonight's dinner (F1), a missed dinner
   reservation costs **two** meals.

The product owner's insight is that a useful reminder is not a nudge; it is a
**collection manifest**: for each selected account, what is actually being
collected, with dish names, so the student can act on gaps while the cutoff is
still open.

**Success is measured by:** the student never opens the portal to discover a meal
they thought they had, and never loses a meal to a missed cutoff they'd have
acted on.

---

## 2. Goals and Non-Goals

### Goals
- Custom alias per account, with profile-name then student-ID fallback.
- Configurable reminder times (defaults 10:30 lunch, 16:30 dinner+breakfast).
- Multi-account aggregated digest listing **reserved** meals with dish names.
- Master on/off switch, plus per-account selection.
- Reminders survive Doze and OEM task-killers, or fail visibly.
- Notification content fully testable without a device.

### Non-Goals (YAGNI)
- No wake-up-alarm behaviour: no full-screen intent, no ongoing ring.
- No reminders for the Food Basket (that is the sniping engine's job).
- No server-side scheduling; reminders are entirely on-device.
- No reminder history retention beyond a bounded debug log.
- No per-account *time* configuration — times are per slot, not per account.

---

## 3. Domain Model

All of the following lives in `lib/core/` and stays pure Dart (no `flutter/*`),
per the existing §3.1 invariant, so it is testable on the VM.

### 3.1 Account identity

```dart
/// A locally saved account.
class SavedAccount {
  final AccountId id;          // stable local id, independent of studentId
  final String studentId;      // portal username, known at save time
  final String? alias;         // user-set nickname, may be null
  final String? profileName;   // discovered only after a successful login
  final DateTime addedAt;
  final DateTime? lastLoginAt;

  /// Resolution chain: alias -> profile name -> student ID.
  ///
  /// Never returns blank: studentId is captured at save time, so a freshly added
  /// account still renders something meaningful before its first login.
  String get displayName => alias ?? profileName ?? studentId;

  SavedAccount withProfileName(String name);
  SavedAccount withAlias(String? alias);
}
```

**Why the chain ends at studentId:** the portal exposes the profile name only on
authenticated pages (F3). A never-logged-in account has no profile name, and a
blank row in the account list would be a bug the user cannot fix.

### 3.2 Reminder configuration

```dart
enum ReminderSlot { lunch, evening }

/// One configurable reminder slot.
class ReminderSlotConfig {
  final ReminderSlot slot;
  final ClockTime time;      // portal-local
  final bool enabled;
  final Set<MealSlot> covers;

  static const lunchDefault = ReminderSlotConfig(
    slot: ReminderSlot.lunch,
    time: ClockTime(10, 30),
    enabled: true,
    covers: {MealSlot.lunch},
  );

  static const eveningDefault = ReminderSlotConfig(
    slot: ReminderSlot.evening,
    time: ClockTime(16, 30),
    enabled: true,
    covers: {MealSlot.dinner, MealSlot.breakfast},
  );
}

class ReminderConfig {
  final bool masterEnabled;
  final Set<AccountId> accountIds;
  final ReminderSlotConfig lunch;
  final ReminderSlotConfig evening;

  /// Accounts excluded from one specific slot. Additive to accountIds so a user
  /// can receive the evening digest without the morning one for an account.
  final Map<ReminderSlot, Set<AccountId>> excludedFromSlot;
}
```

**Times are portal-local, not device-local**, matching the cutoff rules in the
existing spec. A user travelling abroad would otherwise set 10:30, get
device-local behaviour, and silently miss every reminder.

### 3.3 The digest — content as data

The reminder's entire risk is that its *content* is wrong: a missing account, a
phantom reservation, the wrong dish. So content is modelled as data and rendered
separately.

```dart
/// Everything one reminder needs to say.
class ReminderDigest {
  final ReminderSlot slot;
  final DateTime generatedAt;
  final List<AccountDigest> accounts;     // accounts that were checked
  final List<ReminderFailure> failures;   // accounts that could NOT be checked
  final bool nothingReserved;             // every checked account was empty
}

class AccountDigest {
  final AccountId accountId;
  final String displayName;
  final List<ReservedMealItem> items;     // empty when nothing reserved
}

class ReservedMealItem {
  final DateTime date;
  final MealSlot slot;
  final String hallName;
  final String dishName;
  final int priceRial;
}

class ReminderFailure {
  final AccountId accountId;
  final String displayName;
  final ReminderFailureCause cause;
}

enum ReminderFailureCause {
  /// Could not authenticate: bad credentials, or CAPTCHA solve declined.
  authFailed,

  /// Authenticated, but the reservations read failed (network, portal error).
  readFailed,

  /// Session was stale and cannot be refreshed without user action.
  sessionExpired,
}
```

### 3.4 The composer is a pure function

```dart
/// Renders a digest into notification title + body. Pure: no clock, no I/O.
///
/// This is the deliverable the user actually reads, so it is a pure function of
/// the digest and is unit-tested directly rather than verified by eyeballing a
/// rendered notification.
NotificationText composeNotification(ReminderDigest digest);

class NotificationText {
  final String title;
  final String body;
  final String? summary;   // collapsed one-liner for the notification shade
}
```

---

## 4. Message Format (Persian)

### 4.1 Evening slot — dinner + tomorrow's breakfast

```
🌙 یادآوری شام امروز (یکشنبه ۲۶ مهر):
• مقسمی — خوراک تن ماهی، لیمو ترش — مرکزی برادران

🍳 صبحانه فردا (دوشنبه ۲۷ مهر) — همراه شام امروز تحویل میگیرید:
• مقسمی — شیر/حلواشکری/نان/چای/قند
• شکفته — شیر/حلواشکری/نان/چای/قند
```

### 4.2 Lunch slot

```
🍽 یادآوری ناهار امروز (یکشنبه ۲۶ مهر):
• شکفته — زرشک پلو با مرغ، سس مرغ، ماست — مرکزی برادران
```

### 4.3 Rules the composer must follow

| Rule | Rationale |
|---|---|
| A meal section lists only accounts that hold that reservation | Confirmed semantics: reserved-only, all slots |
| A meal with no reservations anywhere omits its whole section | Avoids three empty headings |
| If every section is empty, the body is `امروز هیچ وعده رزروشدهای ندارید` | An empty-looking notification reads as a bug; say it explicitly |
| Failed accounts appear as a trailing `⚠️ بررسی نشد: <names>` line | **Silently omitting an account is the one unacceptable outcome** |
| Dates use Persian (Jalali) calendar and Persian digits | Persian-first RTL design |
| Dish names come from the menu grid, not a flag | The point is knowing *what* you're collecting |
| Hall name is included when the account holds meals in a hall | Helps the student know where to collect |

### 4.4 Failure visibility, worked through

Three accounts selected; شریفی's session is stale and re-login fails:

```
🌙 یادآوری شام امروز (یکشنبه ۲۶ مهر):
• مقسمی — خوراک تن ماهی، لیمو ترش — مرکزی برادران

⚠️ بررسی نشد: شریفی
```

The user learns both that they hold dinner and that one account is unchecked. A
digest with failures is always labelled; there is no code path that drops an
account quietly.

---

## 5. Scheduling and Delivery

### 5.1 Timing

| Need | Mechanism |
|---|---|
| Fire precisely at the configured time | `AlarmManager` exact alarm |
| Catch-up if the phone was off or Doze deferred the alarm | `WorkManager` one-shot, scheduled at the same time as a backstop |
| Re-arm daily | Reschedule the next occurrence after each fire |

Requires `SCHEDULE_EXACT_ALARM` on API 31+. The permission is requested with an
in-app explanation of why exact timing matters (a reminder at 10:35 may be too
late for a 20:00 cutoff if the user is away from their phone — acceptable, but
the user should know the trade) — never requested silently.

### 5.2 Presentation

- Standard system notification, `BigTextStyle`, so the multi-account list expands
  inline.
- **No** full-screen intent, **no** ongoing ring, **no** alarm audio. This was
  called out explicitly by the product owner and is a hard requirement.
- High-priority channel so it is visible, but not `CATEGORY_ALARM`.
- One notification per slot per fire — not one per account. The digest is the unit.

### 5.3 Tap behaviour

Tapping opens the app and deep-links to a **Reminders detail screen** showing the
same digest, per-account rows, and for each reserved meal the hall, dish, price
and date. The screen re-reads live state rather than replaying the cached digest,
so what the user sees on tap is current, not a snapshot from 10:30.

### 5.4 Cost

Two reminder fires per day. Each authenticates every selected account once and
reads its reservations — O(accounts) requests, twice daily. This is negligible
against the per-account request budget defined for the sniping engine, and there
is no polling loop: the app sleeps between reminders.

---

## 6. Components

```
lib/core/
  accounts.dart      SavedAccount, display-name resolution chain
  reminder.dart      ReminderSlot, ReminderSlotConfig, ReminderConfig, ReminderDigest,
                     ReservedMealItem, ReminderFailure, NotificationText
  reminder_compose.dart   composeNotification(digest) -> NotificationText   [pure]

lib/adapter/
  reminder_digest_builder.dart   DigestBuilder: reads N accounts -> ReminderDigest
                                 (depends on PortalClient + SessionManager)

lib/platform/
  reminder_scheduler.dart        Schedule/cancel exact alarms + WorkManager backstop
  reminder_notifier.dart         Post the notification, deep-link extras

lib/ui/reminders/
  reminders_screen.dart          Management: master toggle, times, account selection
  reminder_detail_screen.dart    Deep-link target: the digest, live

lib/store/
  account_store.dart             Persist SavedAccount list (Keystore-backed)
  reminder_config_store.dart     Persist ReminderConfig
```

### Boundary rules

- `composeNotification` imports nothing but `reminder.dart`. Pure, VM-testable.
- `DigestBuilder` is the only new component that touches the network. It takes a
  `PortalClient` and a session provider, so tests inject fakes.
- `ReminderScheduler` and `ReminderNotifier` are the only Android-aware pieces;
  they are thin and contain no message logic.

---

## 7. Error Handling

| Situation | Behaviour |
|---|---|
| Master switch off | No alarms scheduled; existing ones cancelled on toggle |
| All account sessions dead, re-login succeeds | Normal path — CAPTCHA solves silently, no user involvement |
| CAPTCHA solve declines for one account | That account is a `authFailed` failure, named in the message |
| Network unreachable | The WorkManager backstop retries once after 10 minutes; if it still fails, post a failure notification: `یادآوری امروز انجام نشد` |
| Portal returns an unrecognised page (redesign) | Treated as `readFailed`, surfaced, and logged — never silently swallowed |
| Device clock far off from server | Digest generation is skipped and the user is told; guessing the date would produce a briefing about the wrong day |
| Phone off at fire time | Catch-up runs on next boot via WorkManager |
| Notification permission denied | In-app banner on the Reminders screen explaining reminders are muted at OS level |

**Absence of a notification is never the only signal.** If a reminder fails
entirely, a failure notification is posted, because a user who receives nothing
cannot distinguish "nothing to collect" from "the feature is broken".

---

## 8. Testing Strategy

| Layer | Approach |
|---|---|
| `displayName` chain | Unit: alias wins, then profileName, then studentId; never blank |
| `composeNotification` | Unit, on the VM, asserting the exact Persian strings including digit/calendar formatting |
| Composer edge cases | Empty digest; one account reserved; mixed reserved/empty; with failures; all-empty |
| `DigestBuilder` | Fake `PortalClient` scripted to return reservations, to fail auth for one account, and to fail reads; assert failures are reported not dropped |
| Scheduler | Assert next-fire calculation across slot times, DST-free UTC+3:30, and after a missed fire |
| Config persistence | Round-trip `ReminderConfig` including per-slot exclusions |
| Notification rendering | Manual on device: expand the notification, verify Persian RTL and Persian digits |
| Doze behaviour | Manual: fire a reminder with the device in Doze and confirm the backstop |

**The highest-value test asset** is the scripted `PortalClient` fake, shared with
the sniping engine's tests, which lets the whole reminder path run deterministically
with no network and no device.

---

## 9. Phasing

This feature depends on session management, which does not exist yet. Proposed
order, per the product owner's decision that sniping comes first:

| Phase | Scope | Depends on |
|---|---|---|
| 1–2 | Domain core + portal adapter | — (in progress) |
| 3 | Session management: `SessionManager`, per-account cookie jars, silent re-login via the solver | 1–2 |
| 4 | Snipe engine | 3 |
| 5 | Android shell: Persian RTL UI, accounts list, aliases, persistence | 3 |
| 6 | Windows shell (thin, inherits core) | 4, 5 |
| 7 | **Reminder domain**: `SavedAccount` chain, `ReminderConfig`, `composeNotification` + tests | 1 |
| 8 | **`DigestBuilder`** + session integration | 3, 7 |
| 9 | **Scheduler, notifications, Reminders screens, permissions** | 5, 8 |
| 10 | Hardening: Doze tests, deep-link verification, battery profiling | 4, 6, 9 |

**Phase 7 has no Android dependency at all** and is fully testable on the VM, so
it can be built in parallel with phases 3–5 if desired. Phases 8–9 are where the
Android risk concentrates, deliberately kept as late and as thin as possible.

---

## 10. Decisions on Ambiguous Cases

Recorded as decisions rather than open questions, so implementation has no
grey areas. Each is cheap to reverse if the product owner disagrees.

| # | Case | Decision |
|---|---|---|
| D1 | Reminder text and section order | As specified in §4; the product owner's live sample is the reference |
| D2 | Days with no service (Fridays, university holidays) | **Fire anyway**, producing the all-empty body. Modelling the university holiday calendar is out of scope and would silently go stale; a quiet "nothing reserved" message costs nothing and never lies. |
| D3 | Meal price in the notification | **Detail screen only.** The notification body stays short; price is secondary to knowing what you're collecting. |
| D4 | Multiple halls in one account's day | Each reserved item carries its own hall name, so a lunch at مرکزی and dinner at فنی render as two bullets with different halls. |
| D5 | Account with reservations but a failed name lookup | `displayName` falls back to student ID, so the digest is never blocked on a missing profile name. |
| D6 | Reminder fires while the app is open on the Reminders screen | The notification still posts (Android behaviour); the screen refreshes live. No special-casing. |
| D7 | User disables a slot while an alarm is pending | Alarm cancelled immediately on config write; a fire already in flight completes and posts, which is correct — the user asked for that reminder when it was scheduled. |
