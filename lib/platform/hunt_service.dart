/// The hunt's platform service: runs the hunt, posts the outcome, and keeps
/// the foreground service alive for exactly as long as the hunt lasts.
///
/// ## Why the service is released promptly
///
/// A foreground service is a user-visible notification and a battery drain. The
/// spec is explicit that it is released the moment the window closes or a
/// purchase lands, so every exit path here calls [PlatformBridge
/// .stopHuntService] — including the failure paths, because a service that
/// lingers after a refused hunt is the worst of both.
///
/// ## The notification is not optimistic
///
/// The success notification is posted **after the outcome is known**, never
/// when the claim is sent. A basket purchase is irreversible, so an ambiguous
/// claim may not have been a purchase at all — and a notification that says
/// "bought" when nothing was bought sends the student looking for a meal they
/// do not have.
library;

import 'dart:async';

import '../core/hunt_config.dart';
import '../core/hunt_notify.dart';
import '../core/models.dart';
import '../core/snipe.dart';
import '../core/snipe_engine.dart';
import 'platform_bridge.dart';

/// Runs hunts and reports their outcome.
class HuntService {
  HuntService({
    required this.bridge,
    required this.engine,
  });

  final PlatformBridge bridge;
  final SnipeEngine engine;

  /// The notification id of the hunt outcome, so a re-post replaces the old.
  static const int _outcomeNotificationId = 4150;

  /// Starts a hunt for [accountId].
  ///
  /// The foreground service is started first, because the system kills an app
  /// that calls `startForegroundService` without posting its notification
  /// promptly.
  ///
  /// ## A switched-off hunt does not start
  ///
  /// The flag is checked **here**, not only in the screen, because the UI is
  /// not the only thing that can start a hunt: the platform can ask for one at
  /// a moment when the student is not looking at the screen. A hunt spends
  /// money, so "off" has to mean off on every path — not just the one the
  /// student touched.
  ///
  /// The check is before the service is started, so a refused hunt leaves no
  /// foreground notification behind claiming the basket is being watched.
  Future<void> start({
    required AccountId accountId,
    required HuntConfig config,
  }) async {
    if (!config.enabled) return;

    await bridge.startHuntService(payload: accountId);

    final rule = config.toRule(id: _ruleId(accountId), account: accountId);
    await engine.start(rule, hunt: config);
  }

  /// Stops a running hunt and releases the foreground service.
  Future<void> stop(AccountId accountId) async {
    await engine.stop(_ruleId(accountId));
    await _releaseService();
  }

  /// The rule id a hunt runs under.
  static String _ruleId(AccountId accountId) => 'hunt-$accountId';

  /// Posts the outcome of a hunt and releases the service.
  ///
  /// Called by the engine's outcome listener. The service is released here
  /// rather than by the caller, so it happens on every path — a purchase, a
  /// refusal, a closed window — without the caller having to remember.
  Future<void> reportOutcome({
    required AccountId accountId,
    required HuntNotification notification,
  }) async {
    await bridge.postNotification(
      id: _outcomeNotificationId,
      title: notification.title,
      body: notification.body,
      deepLink: 'reservations://$accountId',
    );
    await _releaseService();
  }

  /// Releases the foreground service, swallowing a platform failure.
  ///
  /// A failure here means the notification stays on screen. That is ugly, not
  /// dangerous, and it is not worth turning a completed purchase into an
  /// error the user sees.
  Future<void> _releaseService() async {
    try {
      await bridge.stopHuntService();
    } catch (_) {
      // The service releases itself when the process ends anyway.
    }
  }
}

/// The engine's outcome listener for a hunt.
///
/// Posts the success notification when a meal was bought, and the "ended
/// without a purchase" notification when the hunt stopped for any other
/// reason.
class HuntNotifier implements HuntOutcomeListener {
  HuntNotifier({
    required this.service,
    required this.accountId,
  });

  final HuntService service;
  final AccountId accountId;

  @override
  Future<void> onClaimed({
    required String ruleId,
    required Listing listing,
    required Reservation reservation,
  }) async {
    final notification = composeHuntSuccess(
      slot: listing.slot,
      date: listing.date,
      dishName: listing.option.name,
      hallName: listing.hall.name,
      priceRial: listing.option.priceRial,
    );

    await service.reportOutcome(
      accountId: accountId,
      notification: notification,
    );
  }

  @override
  Future<void> onEnded({
    required String ruleId,
    required SnipeState state,
    required String reason,
  }) async {
    // A dry run that matched is a *success* of the simulation, not a purchase,
    // so it says so rather than claiming a meal was bought.
    final notification = composeHuntEnded(
      reason: state == SnipeState.claimed
          ? 'این یک اجرای آزمایشی بود؛ چیزی خریداری نشد.'
          : reason,
    );

    await service.reportOutcome(
      accountId: accountId,
      notification: notification,
    );
  }
}
