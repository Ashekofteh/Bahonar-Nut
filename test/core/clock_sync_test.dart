import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/transport/http_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A transport whose server sends a `Date` header the test controls.
PortalTransport transportServing(
  String? serverDate, {
  SyncedServerClock? clock,
  void Function(int request)? onRequest,
}) =>
    transportServingFrom(() => serverDate, clock: clock, onRequest: onRequest);

/// A transport whose server reads the `Date` header afresh on every request.
PortalTransport transportServingFrom(
  String? Function() serverDate, {
  SyncedServerClock? clock,
  void Function(int request)? onRequest,
}) {
  var requests = 0;
  return PortalTransport(
    baseUri: Uri.parse('https://nut.uk.ac.ir/'),
    clock: clock,
    httpClient: MockClient((request) async {
      requests++;
      onRequest?.call(requests);
      final date = serverDate();
      return http.Response(
        '<html></html>',
        200,
        headers: {
          'date': ?date,
        },
      );
    }),
  );
}

void main() {
  group('the transport syncs the clock from the portal', () {
    test('a response with a Date header syncs the clock', () async {
      final clock = SyncedServerClock();
      final transport = transportServing(
        'Tue, 20 Oct 2026 12:00:00 GMT',
        clock: clock,
      );

      expect(clock.isSynced, isFalse);

      await transport.get('a1', '/');

      expect(clock.isSynced, isTrue,
          reason: 'without a synced clock the hunt pre-flight refuses to '
              'start, because peak detection would be guessing');
    });

    test('a response with no Date header is not an observation', () async {
      final clock = SyncedServerClock();
      final transport = transportServing(null, clock: clock);

      await transport.get('a1', '/');

      expect(clock.isSynced, isFalse,
          reason: 'a response without a Date header tells us nothing about the '
              'server time, and guessing is worse than not knowing');
    });

    test('the synced time tracks the server, not the device', () async {
      final clock = SyncedServerClock();
      final transport = transportServing(
        'Tue, 20 Oct 2026 15:00:00 GMT',
        clock: clock,
      );

      final before = DateTime.now().toUtc();
      await transport.get('a1', '/');
      final after = DateTime.now().toUtc();

      // The device and the portal disagree by three and a half hours here, and
      // the clock must land on the *portal's* time, not the device's.
      final serverTime = DateTime.utc(2026, 10, 20, 15, 0);
      expect(
        clock.nowUtc.difference(serverTime).abs(),
        lessThan(after.difference(before) + const Duration(seconds: 1)),
      );
      expect(clock.nowUtc.isAfter(before.add(const Duration(hours: 2))),
          isTrue,
          reason: 'the synced time must be the portal\'s, not the device\'s');
    });

    test('a later response re-syncs the clock', () async {
      final clock = SyncedServerClock();
      var serverDate = 'Tue, 20 Oct 2026 12:00:00 GMT';
      final transport = transportServingFrom(() => serverDate, clock: clock);

      await transport.get('a1', '/');
      final first = clock.nowUtc;

      serverDate = 'Tue, 20 Oct 2026 18:30:00 GMT';
      await transport.get('a1', '/');
      final second = clock.nowUtc;

      expect(
        second.difference(first).inHours,
        greaterThanOrEqualTo(6),
        reason: 'the second response moved the clock forward by six and a half '
            'hours',
      );
    });

    test('a transport with no clock syncs nothing', () async {
      // The clock is optional so a parsing-only transport does not have to
      // carry one. The app always supplies it.
      final transport = transportServing('Tue, 20 Oct 2026 12:00:00 GMT');

      await transport.get('a1', '/');
    });
  });

  group('SyncedServerClock.observe', () {
    test('a null server date leaves the clock unsynced', () {
      final clock = SyncedServerClock();

      clock.observe(
        serverDateUtc: null,
        roundTrip: const Duration(milliseconds: 100),
        localReceivedAt: DateTime.now().toUtc(),
      );

      expect(clock.isSynced, isFalse);
    });

    test('a server date syncs the clock', () {
      final local = DateTime.utc(2026, 10, 20, 12, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);

      clock.observe(
        serverDateUtc: DateTime.utc(2026, 10, 20, 15, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );

      expect(clock.isSynced, isTrue);
      expect(clock.nowUtc, DateTime.utc(2026, 10, 20, 15, 0));
    });
  });
}
