/// The hunt's configuration: when to hunt, what to buy, and how hard to push.
///
/// ## The bounds are hard, not advisory
///
/// The user's interval preference is **clamped**, never honoured outside the
/// bounds in [HuntBounds]. The UI cannot represent a value beyond them, and
/// the model clamps again on the way in, so the guard does not depend on the UI
/// being correct. A hunt spends real money and spends the account's goodwill
/// with the portal; the app must not be configurable into behaviour that reads
/// as an attack.
///
/// ## The rate is a function of the time, not a constant
///
/// The portal publishes when each meal is distributed (see [distributionWindows]),
/// and a lunch hunt is not competitive at 19:00. So the hunt carries two
/// intervals and picks between them using the **server clock** — a device
/// clock an hour off would otherwise poll hard at the wrong time, or sleep
/// through the peak entirely.
///
/// ## The cost is shown, not implied
///
/// A faster interval is simultaneously a bigger competitive edge and a bigger
/// ban risk, and the two are the same knob. So the configuration can project
/// the request count for the window: a number the user is actually trading
/// against is information; a label saying "fast" is not.
library;

import 'models.dart';
import 'priority.dart';
import 'snipe.dart';
import 'time.dart';

/// The portal's published distribution window for a meal.
///
/// Read from `ForgotReceipt.aspx` ("زمان دریافت فیش فراموشی").
class DistributionWindow {
  const DistributionWindow(this.start, this.end);

  /// When the meal becomes collectable, portal-local.
  final ClockTime start;

  /// When the collection window closes, portal-local.
  final ClockTime end;

  /// Whether [now] falls inside the window.
  ///
  /// Inclusive at both ends: the window opens *at* [start] and closes *at*
  /// [end], and the closing minute is still inside it.
  bool contains(ClockTime now) => now >= start && now <= end;

  /// The window's length.
  Duration get duration => Duration(
        minutes: end.minutesSinceMidnight - start.minutesSinceMidnight,
      );

  @override
  String toString() => 'DistributionWindow($start..$end)';
}

/// The portal's own distribution windows, per meal.
///
/// Breakfast and dinner share the evening window — they are collected
/// together — so a hunt for either is hot at the same hours.
const Map<MealSlot, DistributionWindow> distributionWindows = {
  MealSlot.breakfast: DistributionWindow(ClockTime(16, 30), ClockTime(20, 30)),
  MealSlot.lunch: DistributionWindow(ClockTime(9, 0), ClockTime(15, 30)),
  MealSlot.dinner: DistributionWindow(ClockTime(16, 30), ClockTime(20, 30)),
};

/// The safety bounds on a hunt's polling rate.
///
/// Every one of these is a **clamp**, not a validation error: a request for
/// an out-of-bounds value is honoured at the bound, so a bad value can never
/// stop the user hunting, and can never make the app hunt more aggressively
/// than the bounds allow.
abstract final class HuntBounds {
  /// The fastest the hunt may poll, even in peak.
  ///
  /// The product owner's floor. Aggressive, but chosen deliberately, and it is
  /// still two orders of magnitude below "hammering".
  static const Duration minPeakInterval = Duration(seconds: 2);

  /// The slowest a peak poll may be. Beyond this the hunt is not hunting.
  static const Duration maxPeakInterval = Duration(seconds: 60);

  /// Below this interval the risk of a rate-limit or ban is material enough
  /// that the user must explicitly acknowledge it.
  static const Duration riskAcknowledgementThreshold = Duration(seconds: 10);

  /// The fastest an off-peak poll may be.
  ///
  /// Off-peak still has to catch a listing within a reasonable time. Without
  /// this floor the user could set off-peak as fast as peak, which would
  /// defeat the point of having two rates and leave the request budget as the
  /// only thing stopping the app.
  static const Duration minOffPeakInterval = Duration(seconds: 30);

  /// The slowest an off-peak poll may be. The product owner's baseline.
  static const Duration maxOffPeakInterval = Duration(minutes: 15);

  /// The hard cap on requests in one window, per account.
  ///
  /// The budget, not the interval, is the ultimate backstop: even a hunt
  /// configured at the fastest possible rate cannot exceed it.
  static const int defaultRequestBudget = 400;

  /// Clamps a peak interval to the permitted range.
  static Duration clampPeak(Duration interval) {
    if (interval < minPeakInterval) return minPeakInterval;
    if (interval > maxPeakInterval) return maxPeakInterval;
    return interval;
  }

  /// Clamps an off-peak interval to the permitted range.
  static Duration clampOffPeak(Duration interval) {
    if (interval < minOffPeakInterval) return minOffPeakInterval;
    if (interval > maxOffPeakInterval) return maxOffPeakInterval;
    return interval;
  }

  /// Whether an interval at this rate needs an explicit risk acknowledgement.
  static bool needsRiskAcknowledgement(Duration interval) =>
      interval < riskAcknowledgementThreshold;
}

/// How hard the hunt may push.
///
/// Both intervals are **clamped on construction**, so an out-of-range value can
/// never be represented, let alone acted on. The clamp is silent by design: a
/// user who drags a slider past the floor gets the floor, not an error dialog
/// telling them off for something the UI should not have offered.
class HuntRate {
  HuntRate({
    Duration peakInterval = defaultPeakInterval,
    Duration offPeakInterval = defaultOffPeakInterval,
  })  : peakInterval = HuntBounds.clampPeak(peakInterval),
        offPeakInterval = HuntBounds.clampOffPeak(offPeakInterval);

  /// The fastest interval considered safe without an explicit risk
  /// acknowledgement.
  static const Duration defaultPeakInterval = Duration(seconds: 10);

  /// A quiet off-peak baseline: about 80 requests over a 20-hour day.
  static const Duration defaultOffPeakInterval = Duration(minutes: 15);

  /// The default rate.
  static final HuntRate defaults = HuntRate();

  /// The interval during the target meal's distribution window.
  final Duration peakInterval;

  /// The interval outside it, but still inside the hunt window.
  final Duration offPeakInterval;

  /// Whether this rate needs the user to acknowledge the ban risk.
  bool get needsRiskAcknowledgement =>
      HuntBounds.needsRiskAcknowledgement(peakInterval);

  /// A copy with the given intervals, clamped.
  HuntRate copyWith({
    Duration? peakInterval,
    Duration? offPeakInterval,
  }) =>
      HuntRate(
        peakInterval: peakInterval ?? this.peakInterval,
        offPeakInterval: offPeakInterval ?? this.offPeakInterval,
      );

  @override
  String toString() =>
      'HuntRate(peak=${peakInterval.inSeconds}s, offPeak=${offPeakInterval.inSeconds}s)';
}

/// One dish the hunt may buy.
///
/// **The dish is identified by its name, not by an option id.** The market
/// renumbers ids — the same dish on the same date is `62737` in the weekly
/// grid and `62798` on the buy page — so an id picked from the official menu
/// can never identify the market listing of that dish, and a hunt keyed on
/// ids would never fire. See [normalizeDishName].
class HuntDish {
  HuntDish({
    required this.optionId,
    required this.name,
    required this.priceRial,
  }) : dishKey = normalizeDishName(name);

  /// The portal's option id, as seen on the page the dish was picked from.
  ///
  /// **Not the identity.** It is retained so the UI can point back at the
  /// offering, and so a listing that happens to carry the same id can be
  /// preferred — but a match never *requires* it.
  final OptionId optionId;

  /// The dish's name, as the portal renders it.
  final String name;

  /// The normalised name the hunt matches listings on.
  final String dishKey;

  /// The price **for the target date and slot**, as the portal quoted it.
  ///
  /// Not a property of the dish: the same option id costs 2,150,000 as a
  /// breakfast and 500,000 as a lunch (verified). The ceiling is therefore
  /// always checked against the live offering for the target date, never a
  /// remembered price and never another date's price.
  final int priceRial;

  @override
  String toString() => 'HuntDish($optionId, $name, $priceRial Rial)';
}

/// A dining hall, as the portal named it for this account.
class HuntHall {
  const HuntHall({required this.id, required this.name});

  /// The portal's hall id. **The identity.**
  ///
  /// Never the name. The portal serves different hall names depending on the
  /// account — a female account may see «مرکزی خواهران» where a male one sees
  /// «مرکزی برادران» — and a string matcher for a Persian hall name is a bug
  /// waiting to happen. The name is display; the id is identity.
  final HallId id;

  /// The name the portal supplied. **Display only.**
  final String name;

  @override
  String toString() => 'HuntHall($id, $name)';
}

/// The hunt's configuration for one rule.
class HuntConfig {
  HuntConfig({
    this.windowStart = const ClockTime(16, 30),
    this.windowEnd = const ClockTime(20, 30),
    this.targetSlot = MealSlot.dinner,
    this.targetDate,
    this.dishPriority = const [],
    this.hallPriority = const [],
    HuntRate? rate,
    this.enabled = false,
    this.requestBudget = HuntBounds.defaultRequestBudget,
    this.riskAcknowledged = false,
  })  : rate = rate ?? HuntRate.defaults,
        assert(requestBudget > 0, 'requestBudget must be positive');

  /// When the hunt is allowed to run at all, portal-local.
  final ClockTime windowStart;

  /// When the hunt stops running, portal-local.
  final ClockTime windowEnd;

  /// The meal this rule hunts for, which decides the peak window.
  final MealSlot targetSlot;

  /// The date the hunt targets, in the portal's civil frame.
  ///
  /// Null means "the first date the portal will serve", resolved at setup.
  final DateTime? targetDate;

  /// The dishes to buy, in priority order.
  ///
  /// A one-element list means "only this dish". A two-element list means
  /// "either will do, this one first".
  final List<HuntDish> dishPriority;

  /// The halls to buy from, in priority order.
  ///
  /// An empty list means "any hall the portal offers this dish in". A
  /// one-element list means only that hall. A two-element list means either,
  /// this one first.
  final List<HuntHall> hallPriority;

  final HuntRate rate;

  /// Off by default: a hunt spends money and makes requests.
  final bool enabled;

  /// Hard cap on requests in one window, per account.
  final int requestBudget;

  /// Whether the user has accepted the ban risk of a sub-10-second rate.
  ///
  /// Remembered so the warning is not shown on every launch, but the warning
  /// is shown again whenever the user *raises* the rate past the threshold.
  final bool riskAcknowledged;

  /// The distribution window of the target meal.
  DistributionWindow get peakWindow => distributionWindows[targetSlot]!;

  /// Whether [now] (portal-local) falls inside the hunt's own window.
  bool isWithinWindow(ClockTime now) {
    // A window never wraps past midnight; if the user sets end <= start the
    // hunt is inert rather than silently spanning a full day.
    if (windowEnd <= windowStart) return false;
    return now >= windowStart && now <= windowEnd;
  }

  /// Whether [now] is inside the target meal's distribution window.
  bool isPeak(ClockTime now) => peakWindow.contains(now);

  /// The interval to use at [now].
  ///
  /// Peak inside the target meal's distribution window, off-peak outside it.
  /// The caller is responsible for not polling at all outside the hunt's own
  /// window — this only answers "how hard", not "whether".
  Duration intervalAt(ClockTime now) =>
      isPeak(now) ? rate.peakInterval : rate.offPeakInterval;

  /// The credit the priority list needs.
  ///
  /// The **sum**, not the cheapest dish. The hunt may buy the second choice if
  /// the first is unavailable, and the second choice is what determines
  /// whether the purchase can actually be completed. A check on the first
  /// choice alone would pass a hunt that then fails for lack of funds at the
  /// moment of claiming — the worst moment to discover it.
  int get requiredCreditRial =>
      dishPriority.fold(0, (sum, dish) => sum + dish.priceRial);

  /// The hunt window's length, in seconds.
  int get windowSeconds =>
      (windowEnd.minutesSinceMidnight - windowStart.minutesSinceMidnight) * 60;

  /// The overlap between the hunt window and the target meal's distribution
  /// window, in seconds.
  ///
  /// **Zero when the two do not overlap.** A lunch hunt running in the
  /// evening window never sees peak, so it polls entirely off-peak — and
  /// projecting it as if it were peak would overstate the request count and
  /// hide the fact that the user has set the hunt up wrong.
  int get peakOverlapSeconds {
    final huntStart = windowStart.minutesSinceMidnight;
    final huntEnd = windowEnd.minutesSinceMidnight;
    if (huntEnd <= huntStart) return 0;

    final peak = peakWindow;
    final start = huntStart > peak.start.minutesSinceMidnight
        ? huntStart
        : peak.start.minutesSinceMidnight;
    final end = huntEnd < peak.end.minutesSinceMidnight
        ? huntEnd
        : peak.end.minutesSinceMidnight;
    if (end <= start) return 0;
    return (end - start) * 60;
  }

  /// The number of requests the hunt is projected to make over its own window.
  ///
  /// This is the number the user trades against, so it is surfaced rather
  /// than buried.
  int projectedRequests() {
    final peak = peakOverlapSeconds;
    final offPeak = windowSeconds - peak;

    final requests = peak / rate.peakInterval.inSeconds +
        offPeak / rate.offPeakInterval.inSeconds;
    return requests.ceil();
  }

  /// The projected request count over an arbitrary span of seconds, at the
  /// given interval.
  ///
  /// Used by the UI to price a slider position before the user commits to it.
  static int requestsFor(Duration interval, int seconds) {
    if (interval.inSeconds <= 0 || seconds <= 0) return 0;
    return (seconds / interval.inSeconds).ceil();
  }

  /// A copy with the given fields changed.
  HuntConfig copyWith({
    ClockTime? windowStart,
    ClockTime? windowEnd,
    MealSlot? targetSlot,
    DateTime? targetDate,
    List<HuntDish>? dishPriority,
    List<HuntHall>? hallPriority,
    HuntRate? rate,
    bool? enabled,
    int? requestBudget,
    bool? riskAcknowledged,
  }) =>
      HuntConfig(
        windowStart: windowStart ?? this.windowStart,
        windowEnd: windowEnd ?? this.windowEnd,
        targetSlot: targetSlot ?? this.targetSlot,
        targetDate: targetDate ?? this.targetDate,
        dishPriority: dishPriority ?? this.dishPriority,
        hallPriority: hallPriority ?? this.hallPriority,
        rate: rate ?? this.rate,
        enabled: enabled ?? this.enabled,
        requestBudget: requestBudget ?? this.requestBudget,
        riskAcknowledged: riskAcknowledged ?? this.riskAcknowledged,
      );

  /// The ranker's preference, built from the dish and hall priority lists.
  ///
  /// The cartesian product of the two lists, ordered dish-first: the first
  /// dish is preferred in every hall before the second dish is considered at
  /// all. That is what "the first choice, then the second" means when a dish
  /// is available in two halls.
  ///
  /// A hall list of one restricts the preference to that hall. A hall list of
  /// two ranks central first, engineering second. An empty hall list means any
  /// hall, which the ranker expresses as "not listed" — but the ranker
  /// rejects unlisted pairs, so the product is taken over every hall the
  /// portal actually offers.
  SlotPreference toSlotPreference({required List<HuntHall> offeredHalls}) {
    final ranked = <PreferencePair>[];

    for (final dish in dishPriority) {
      for (final hall in hallPriority.isEmpty ? offeredHalls : hallPriority) {
        ranked.add(PreferencePair(hallId: hall.id, optionId: dish.optionId));
      }
    }

    return SlotPreference(slot: targetSlot, ranked: ranked);
  }

  /// The rule the engine runs, derived from this configuration.
  ///
  /// The window and the slot come from the configuration, so the engine's own
  /// window check and the hunt's are the same window — a rule that hunted
  /// outside the configured window would be a rule the user could not see.
  ///
  /// The price ceiling is the *dearest* dish on the priority list, because the
  /// hunt may buy the second choice when the first is unavailable, and a
  /// ceiling below the second choice's price would forbid the fallback the
  /// user asked for.
  SnipeRule toRule({
    required String id,
    required AccountId account,
    bool dryRun = false,
  }) =>
      SnipeRule(
        id: id,
        account: account,
        enabled: enabled,
        windowStart: windowStart,
        windowEnd: windowEnd,
        slots: {targetSlot},
        target: targetDate == null
            ? DateTarget.today
            : DateTarget.explicit,
        explicitDate: targetDate,
        preferences: {
          targetSlot: toSlotPreference(offeredHalls: hallPriority),
        },
        maxPriceRial: maxPriceRial,
        dryRun: dryRun,
      );

  /// The highest price the hunt will pay.
  ///
  /// Null when the hunt set no ceiling, in which case the price is judged
  /// against the live offering per dish instead.
  int? get maxPriceRial {
    if (dishPriority.isEmpty) return null;
    var highest = dishPriority.first.priceRial;
    for (final dish in dishPriority) {
      if (dish.priceRial > highest) highest = dish.priceRial;
    }
    return highest;
  }

  @override
  String toString() => 'HuntConfig($targetSlot, ${dishPriority.length} dishes, '
      '${hallPriority.length} halls, $rate)';
}
