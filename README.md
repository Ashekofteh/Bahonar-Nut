# Bahonar-Nut — Food Basket App

Cross-platform (Android-first, Windows secondary) client automating the Shahid
Bahonar University dining portal (Cullinan) — multi-account management, native
Persian RTL reservations, and priority-ranked Food Basket auto-reserve.

## Docs

- `docs/superpowers/specs/2026-10-17-food-basket-app-design.md` — frozen design spec
- `task_plan.md` — phases and locked decisions
- `findings.md` — portal recon, risk register
- `progress.md` — session log

## Project layout (target)

```
lib/
  core/       # platform-agnostic domain: scheduler, ranker, engine, clock (no flutter/* imports)
  adapter/    # PortalClient implementation (only portal-aware layer)
  transport/  # HTTP, cookies, backoff, circuit breaker
  store/      # Keystore/DPAPI secure storage
  ui/         # Persian RTL Flutter screens
  platform/   # Android fg service, alarms / Windows tray
```
