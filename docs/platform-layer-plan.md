# Android platform layer — plan

**Scope:** the platform pieces the app needs to be a real product rather than a
prototype. Keystore-backed credentials, persistent stores, notifications, exact
alarms, a foreground service for the hunt window, and live portal wiring.

## Assumptions, stated before building

1. **The core stays platform-free.** Every rule about what to do remains in
   `lib/core`, testable on the VM. The platform layer only *does* things:
   stores bytes, schedules alarms, posts notifications. No business logic in
   Kotlin.
2. **The platform layer is thin and mostly untestable in isolation.** Keystore,
   AlarmManager and NotificationManager are Android APIs with no JVM
   equivalent, so they are verified *on a device*, not by unit test. The Dart
   side of each contract is tested on the VM.
3. **Credentials are the only thing that needs Keystore.** The account list
   (student ids and aliases) and the reminder config are not secret, so they
   live in SharedPreferences. Putting them in Keystore would add cost without
   adding security.
4. **The service is a lifecycle container, not a worker.** It holds the hunt
   alive and hosts the snipe engine; the engine's own state machine
   (`lib/core/snipe_engine.dart`) remains the only thing deciding when to buy.

## The build order, with how each step is verified

| # | Step | Verified by |
|---|---|---|
| 1 | Platform store contracts (Dart) | VM tests; the contracts are pure interfaces |
| 2 | Keystore-backed secure store | **On device**: add an account, restart the app, the credentials are still there |
| 3 | SharedPreferences stores | **On device**: accounts and config survive a restart |
| 4 | Notification channel + posting | **On device**: a notification appears in the shade |
| 5 | Exact alarms | **On device**: the alarm fires at the configured minute |
| 6 | Foreground service | **On device**: the service starts and shows its notification |
| 7 | Live portal wiring | **On device**: the balance and reservations load from the real portal |

## The one thing that must not be rushed

**The `ClaimAmbiguous` path.** If the app is killed between a purchase request
and its response, on restart it must NOT retry the purchase — it must reconcile
by reading the ledger. A blind retry buys two meals. The service therefore
persists a "purchase in flight" marker before any write, and clears it only
after the outcome is known. This is the same rule the core already enforces;
the platform layer's job is to not defeat it across a process death.

## What is deliberately NOT in this phase

- Background *servers* — on-device only, per the original decision.
- A shared listing feed across users — a #1 ban risk, already rejected.
- The Windows shell (phase 6) — it inherits the same core.
