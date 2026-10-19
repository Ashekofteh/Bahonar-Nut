import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the platform bridge.
///
/// ## Why these exist
///
/// The bridge had a bug where `_call` invoked itself instead of the channel,
/// which produced a **stack overflow** on the first platform call. Every write
/// silently failed: the app appeared to save an account while storing nothing.
///
/// The bug was invisible to the analyzer and to every other test, because the
/// bridge talks to a platform that only exists on a device. These tests give it
/// a fake channel, which is the only way to catch this class of mistake.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ir.ac.uk.bahonar_nut/platform');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'plainReadString':
          return 'stored-value';
        case 'plainReadInt':
          return 42;
        case 'plainReadBool':
          return true;
        case 'plainKeys':
          return <String>['a', 'b'];
        case 'secureRead':
          return <String, dynamic>{
            'studentId': '401405035',
            'password': 'secret',
          };
        case 'secureList':
          return <String>['a1', 'a2'];
        case 'notificationPermission':
          return true;
        case 'canScheduleExactAlarms':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('the plain store', () {
    test('reads and writes go to the channel', () async {
      final store = PlatformBridge(channel: channel).plainStore;

      expect(await store.readString('k'), 'stored-value');
      await store.writeString('k', 'v');
      expect(calls.map((c) => c.method), contains('plainWriteString'));
    });

    test('a null value removes the key', () async {
      final store = PlatformBridge(channel: channel).plainStore;
      await store.writeString('k', null);
      final write = calls.firstWhere((c) => c.method == 'plainWriteString');
      expect((write.arguments as Map)['value'], isNull);
    });

    test('the other types round-trip', () async {
      final store = PlatformBridge(channel: channel).plainStore;
      expect(await store.readInt('k'), 42);
      expect(await store.readBool('k'), isTrue);
      expect(await store.keys(), {'a', 'b'});
    });
  });

  group('the credential store', () {
    test('reads the credentials back', () async {
      final store = PlatformBridge(channel: channel).credentialStore;
      final credentials = await store.read('a1');
      expect(credentials!.studentId, '401405035');
      expect(credentials.password, 'secret');
    });

    test('writes and deletes', () async {
      final store = PlatformBridge(channel: channel).credentialStore;
      await store.write('a1', const Credentials(studentId: '401405035', password: 'pw'));
      expect(calls.map((c) => c.method), contains('secureWrite'));

      await store.delete('a1');
      expect(calls.map((c) => c.method), contains('secureDelete'));
    });

    test('lists the account ids', () async {
      final store = PlatformBridge(channel: channel).credentialStore;
      expect(await store.listAccountIds(), ['a1', 'a2']);
    });
  });

  group('failures are surfaced, not swallowed', () {
    test('a platform error becomes a StateError naming the method', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'PLATFORM_ERROR', message: 'boom');
      });

      final store = PlatformBridge(channel: channel).plainStore;
      await expectLater(
        store.readString('k'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('plainReadString'), contains('boom')),
          ),
        ),
      );
    });

    test('a missing plugin becomes a StateError, not a crash', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      final store = PlatformBridge(channel: channel).plainStore;
      await expectLater(store.readString('k'), throwsA(isA<StateError>()));
    });
  });

  group('notifications and alarms', () {
    test('permission checks are reported', () async {
      final bridge = PlatformBridge(channel: channel);
      expect(await bridge.hasNotificationPermission(), isTrue);
      expect(await bridge.canScheduleExactAlarms(), isTrue);
    });

    test('a notification is posted with its deep link', () async {
      await PlatformBridge(channel: channel).postNotification(
        id: 7,
        title: 'یادآور',
        body: 'متن',
        deepLink: 'reminder://lunch',
      );
      final post = calls.firstWhere((c) => c.method == 'postNotification');
      expect((post.arguments as Map)['id'], 7);
      expect((post.arguments as Map)['deepLink'], 'reminder://lunch');
    });

    test('an alarm is scheduled with its trigger time', () async {
      final at = DateTime.utc(2026, 10, 20, 10, 30);
      await PlatformBridge(channel: channel).scheduleAlarm(
        requestCode: 3,
        triggerAt: at,
        payload: 'lunch',
      );
      final schedule = calls.firstWhere((c) => c.method == 'scheduleAlarm');
      expect((schedule.arguments as Map)['requestCode'], 3);
      expect((schedule.arguments as Map)['triggerAtMillis'],
          at.millisecondsSinceEpoch);
    });
  });
}
