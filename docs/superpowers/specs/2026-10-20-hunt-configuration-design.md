# Hunt Configuration — Windows, Rates, and Peak Hours

**Date:** 2026-10-20
**Status:** Design approved by the product owner; ready for implementation
**Depends on:** `2026-10-17-food-basket-app-design.md` (snipe engine, hard correctness rules)

---

## 1. What this adds

The snipe engine exists and is tested, but it polls on one fixed cadence. This
adds the three things that make it usable in a real competition:

1. **A user-selectable active window** — when the hunt is allowed to run.
2. **A configurable polling interval range** — how hard it hunts, with the user
   in control of the trade-off.
3. **Automatic peak/off-peak rate switching** — the app polls hard when the
   target meal is actually being distributed and slowly otherwise.

The polling interval is the app's central knob: it sets how quickly a listing
is noticed and claimed, and therefore how many requests are made. Everything
below is about keeping that knob inside safe bounds while letting the user
push it as far as they judge worthwhile.

---

## 2. The ground truth: the portal publishes its own distribution windows

Read from `ForgotReceipt.aspx` (the "forgot receipt" page), which lists when
each meal may be collected:

| Meal | Distribution window (portal-local, UTC+3:30) |
|---|---|
| صبحانه breakfast | **16:30 – 20:30** |
| ناهار lunch | **09:00 – 15:30** |
| شام dinner | **16:30 – 20:30** |

Two facts follow that shape the whole design:

- **Breakfast and dinner share a window.** They are collected at the same time
  in the evening, so a hunt targeting either one is hot at the same hours.
- **The 20:00 cutoff sits 30 minutes before the evening window closes.** The
  last moment a student can act is the moment competition peaks.

The portal's own vocabulary for this feature is **"تعیین بازه زمانی و وعده غذایی"** —
"set the time range and the meal" — and the hunt configuration borrows it.

**Peak is per target meal**, not the union of all windows. A lunch hunt is not
competitive at 19:00, and treating it as such would burn the request budget
for no chance of winning.

---

## 3. Configuration model

```dart
/// How hard the hunt may push.
class HuntRate {
  /// The interval during the target meal's distribution window.
  /// Clamped to [minPeakInterval] .. [maxPeakInterval].
  final Duration peakInterval;

  /// The interval outside it.
  /// Clamped to [minOffPeakInterval] .. [maxOffPeakInterval].
  final Duration offPeakInterval;
}

/// The hunt's configuration for one rule.
class HuntConfig {
  /// When the hunt is allowed to run. Portal-local.
  final ClockTime windowStart;
  final ClockTime windowEnd;

  /// The meal this rule hunts for, which decides the peak window.
  final MealSlot targetSlot;

  final HuntRate rate;

  /// Off by default: a hunt spends money and makes requests.
  final bool enabled;

  /// Hard cap on requests in one window, per account.
  final int requestBudget;
}
```

### Defaults

| Setting | Default | Why |
|---|---|---|
| `windowStart` / `windowEnd` | 16:30 / 20:30 | The portal's evening distribution window — the only window where listings reliably appear. |
| `targetSlot` | dinner | The window with the most competition, and the one the reminder system already covers. |
| `peakInterval` | 10s | The fastest interval considered safe without an explicit risk acknowledgement. |
| `offPeakInterval` | 15 minutes | A quiet baseline that costs ~80 requests over a 20-hour day. |
| `requestBudget` | 400 | Already the engine's per-window budget; unchanged. |
| `enabled` | false | A hunt spends money. It is opt-in. |

---

## 4. The safety bounds — hard clamping

The user's interval preference is **clamped**, never honoured outside these
bounds. The UI cannot even represent a value beyond them, so the guard does
not depend on the UI being correct.

| Bound | Value | Rationale |
|---|---|---|
| Minimum peak interval | **2s** | The product owner's chosen floor. Aggressive, but the user asked for it and it is permitted. |
| Interval requiring explicit risk acknowledgement | **< 10s** | Below this the account is at material risk of rate-limiting or ban. The user must confirm. |
| Maximum off-peak interval | 15 minutes | The product owner's chosen off-peak baseline and floor. |
| Minimum off-peak interval | 30s | Off-peak still needs to catch a listing within a reasonable time; below this the request budget is the only thing stopping the app. |
| Maximum requests per window | 400 | Unchanged from the engine. The budget, not the interval, is the ultimate backstop. |

### The 2-second floor is a real cost, and the app must say so

At 2 seconds, a four-hour evening window is **7,200 requests and ~232 MB** of
HTML. At 10 seconds it is 1,440 requests and ~46 MB. The difference is the
entire competitive edge, and the entire ban risk.

The UI therefore shows the **projected request count for the window** next to
the slider, and recalculates it as the user drags. A number that moves is
information; a label that says "fast" is not.

### The ban warning

Choosing an interval below 10 seconds raises a confirmation that states, in
Persian and in plain terms, that:

- polling faster than 10 seconds carries a **significant risk of rate-limiting
  or banning the account**;
- the risk applies to **the account itself**, and a ban affects every other
  feature of the app, not just the hunt;
- the projected request count for the window, at the chosen rate.

The choice is remembered per rule, and the warning is shown again if the user
raises the rate later — but the risk acknowledgement is not hidden behind a
setting.

---

## 5. The timing rule: cooldown measured **after** the load completes

**The interval is the wait *between the end of one request cycle and the start
of the next*.** Requests never overlap.

This is not a detail — it is the difference between a hunt and a self-inflicted
denial of service:

```
  t=0s     request starts
  t=0.4s   response received, page parsed
  t=0.4s   ── wait the interval ──▶
  t=2.4s   next request starts
```

Measuring from the *start* of the previous request instead would make a slow
response (say 1.5s) overlap the next one, and an overlap in a hunt is how a
client ends up hammering the portal with more concurrency than the user asked
for — the exact signature of abuse.

The implementation is a `Future.delayed` chained **after** the parse completes,
never a `Timer` started before the request.

---

## 6. Peak detection

```dart
/// The distribution window of a meal, portal-local.
class DistributionWindow {
  const DistributionWindow(this.start, this.end);
  final ClockTime start;
  final ClockTime end;
}

/// The portal's published windows.
const distributionWindows = {
  MealSlot.breakfast: DistributionWindow(ClockTime(16, 30), ClockTime(20, 30)),
  MealSlot.lunch:     DistributionWindow(ClockTime(9, 0),  ClockTime(15, 30)),
  MealSlot.dinner:    DistributionWindow(ClockTime(16, 30), ClockTime(20, 30)),
};
```

A time is **peak** when it falls inside the target meal's window. The
comparison is portal-local time from the **server clock**, never the device
clock — a device whose clock is an hour off would otherwise poll hard at the
wrong time, or sleep through the peak.

---

## 7. How the engine uses it

The engine's existing `PollingPolicy` gains a mode where the interval depends
on the current time:

```
loop:
  preflight (clock synced? session alive? funds enough?)
  poll the basket
  parse and rank
  if matched -> claim (with the existing ambiguity rules)
  wait:
    now = serverClock.now
    if inside the hunt window:
        interval = inside the target meal's distribution window
                     ? rate.peakInterval
                     : rate.offPeakInterval
    else:
        do not poll at all; wait for the window to open
```

Outside the hunt window the engine does **not** poll at all. It sleeps until
the window opens, which is what keeps the request count near zero for a user
who only hunts in the evening.

### What does not change

The hard correctness rules are untouched by this feature:

- never retry an ambiguous claim;
- one in-flight claim per account;
- tombstone a lost listing and never re-poll it;
- session pre-flight before the window opens, not during it;
- respect the server clock for all cutoff logic.

A faster interval makes the *claim* happen sooner. It does not make the claim
safer, and it must not be allowed to weaken any of the rules above.

---

## 8. The UI

A dedicated **"شکار" (hunt)** section in the reminders/settings area, using the
portal's own phrase **"تعیین بازه زمانی و وعده غذایی"**.

### The range slider

A single continuous slider per rate, with the bounds baked in:

- **Peak slider**: 2s … 60s, logarithmic. Logarithmic because the useful range
  spans 2s to 60s and a linear slider spends most of its travel on the slow
  end, where nothing interesting happens.
- **Off-peak slider**: 30s … 15 minutes, logarithmic for the same reason.

The slider shows the live value in Persian digits, the projected request count
for the hunt window, and a colour band: green at the conservative end, amber
below 10s, red at the 2s extreme.

### The animation

The slider animates the thumb position, and the projected request count
**counts up or down** as the value changes rather than jumping. The count is
the number the user is actually trading against, so it should move like
something being spent.

A subtle pulse on the peak/off-peak indicator when the current time crosses
into or out of the target meal's distribution window — so the user can see the
app switching rate without opening a screen.

### The risk acknowledgement

Reaching below 10s raises a modal (not a snackbar — it must be acknowledged)
in Persian, stating the ban risk, the scope of that risk, and the projected
request count. The confirm button is distinct from the cancel button; the
default focus is cancel.

---

## 9. Data flow

```
  HuntConfig (persisted, plain store)
        │
        ▼
  SnipeEngine reads it at start
        │
        ├── server clock ──▶ is now inside the hunt window?
        │                          │ no  ──▶ sleep until it opens (no requests)
        │                          │ yes ──▶ is now inside the target meal's
        │                                       distribution window?
        │                                          │ no  ──▶ offPeakInterval
        │                                          │ yes ──▶ peakInterval
        ▼
  poll → parse → rank → claim (existing rules)
```

The configuration is read once when the run starts, not per poll: a hunt that
changed its own rate mid-flight would be harder to reason about, and the
difference is not worth the complexity. The *window* is re-evaluated per cycle,
because crossing into peak mid-hunt is exactly when the rate should change.

---

## 10. Error handling

| Situation | Behaviour |
|---|---|
| The server clock is not synced | The hunt does not start. Peak detection needs the server clock, and a device clock would put the rate in the wrong place |
| The hunt window is already past today | The run waits for tomorrow's window |
| The target meal has no distribution window | It does — every meal has one |
| The request budget is exhausted | The run stops, and the ledger says why |
| The user lowers the rate below 10s later | The warning is shown again |
| The portal rate-limits (429) | The circuit breaker opens, and the run backs off exponentially. **A 429 is a rate-limit signal, not a transient error** |

---

## 11. Testing

| Layer | Approach |
|---|---|
| Clamping | Unit: values below/above the bounds are clamped, never rejected |
| Peak detection | Unit: the boundary instants of each distribution window, in portal-local time |
| Interval selection | Unit: peak inside the window, off-peak outside it, and the hunt window itself |
| The timing rule | Unit with an injected clock: the next request starts at least `interval` after the previous one **finished** |
| The ban warning | Widget: the modal appears below 10s and does not appear at or above it |
| The slider | Widget: the projected count moves with the value |
| End to end | The engine with a fake clock and a scripted client: the request timeline is asserted against the expected schedule |

The timing test is the important one. It is easy to write an engine that
respects the interval when responses are instant and violates it when a
response is slow, so the test uses a deliberately slow response and asserts the
gap is measured from the response's end.

---

## 12. Out of scope

- **Predicting listing availability.** The app cannot know when a listing will
  appear; it can only react faster.
- **Multiple simultaneous hunts.** One hunt per rule, one foreground service.
- **Server-side coordination.** A shared feed of listings across users was
  already rejected as a ban risk.
- **Adapting the rate to observed competition.** The app could measure how fast
  listings disappear and tighten the rate accordingly. That is a real
  improvement, and it is deliberately deferred: it needs reliable measurements
  of listing turnover, which the app does not yet collect.
