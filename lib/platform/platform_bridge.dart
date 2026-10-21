/// The Dart side of the platform bridge.
///
/// Everything here is a thin adapter over a [MethodChannel]. The *decisions*
/// live in `lib/core`; this file only moves data across the boundary and
/// converts the platform's vocabulary into the domain's.
library;

import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/platform_stores.dart';
import '../core/session.dart';

/// The platform channel.
class PlatformBridge {
  PlatformBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'ir.ac.uk.bahonar_nut/platform';

  final MethodChannel _channel;

  /// A [SecureCredentialStore] backed by the Android Keystore.
  SecureCredentialStore get credentialStore => _KeystoreCredentialStore(this);

  /// A [PlainStore] backed by SharedPreferences.
  PlainStore get plainStore => _PreferencesStore(this);

  /// Whether the user has granted the notification permission.
  Future<bool> hasNotificationPermission() async =>
      await _call<bool>('notificationPermission') ?? false;

  /// Asks for the notification permission.
  Future<bool> requestNotificationPermission() async =>
      await _call<bool>('requestNotificationPermission') ?? false;

  /// Posts a notification.
  Future<void> postNotification({
    required int id,
    required String title,
    required String body,
    String? deepLink,
  }) async {
    await _call<void>('postNotification', {
      'id': id,
      'title': title,
      'body': body,
      'deepLink': deepLink,
    });
  }

  /// Cancels a notification.
  Future<void> cancelNotification(int id) async {
    await _call<void>('cancelNotification', {'id': id});
  }

  /// Whether exact alarms are permitted.
  Future<bool> canScheduleExactAlarms() async =>
      await _call<bool>('canScheduleExactAlarms') ?? false;

  /// Asks for the exact-alarm permission, which opens the system setting.
  Future<bool> requestExactAlarmPermission() async =>
      await _call<bool>('requestExactAlarmPermission') ?? false;

  /// Schedules an exact alarm.
  Future<void> scheduleAlarm({
    required int requestCode,
    required DateTime triggerAt,
    String? payload,
  }) async {
    await _call<void>('scheduleAlarm', {
      'requestCode': requestCode,
      'triggerAtMillis': triggerAt.millisecondsSinceEpoch,
      'payload': payload,
    });
  }

  /// Cancels an alarm.
  Future<void> cancelAlarm(int requestCode) async {
    await _call<void>('cancelAlarm', {'requestCode': requestCode});
  }

  /// The reminder deliveries the app owes.
  ///
  /// A reminder alarm fires when the app may not be running, and the digest
  /// is composed in Dart — so when the process was dead the alarm fired into
  /// nothing and the reminder was lost without a sound. The native side
  /// records the delivery instead, and the Dart side picks it up when it
  /// next runs.
  ///
  /// This is the **visible catch-up** the risk register asks for: a delivery
  /// that was owed is not forgotten, and the student learns about it.
  Future<List<String>> pendingDeliveries() async {
    final result = await _call<List<Object?>>('pendingDeliveries');
    if (result == null) return const [];
    return result.whereType<String>().toList();
  }

  /// Clears the owed deliveries, after they have been delivered.
  ///
  /// Cleared by the side that knows the outcome — the Dart side, once the
  /// digest has actually been posted. Clearing it in the receiver would
  /// forget a delivery that was handed over and then lost.
  ///
  /// Only the named payloads are cleared, and only their first occurrence: a
  /// live fire records the payload and hands it to the Dart side in the same
  /// breath, so the Dart side delivers it and clears that copy — leaving any
  /// other owed delivery alone.
  Future<void> clearPendingDeliveries(List<String> payloads) async {
    await _call<void>('clearPendingDeliveries', {'payloads': payloads});
  }

  /// Starts the hunt's foreground service.
  ///
  /// The service keeps the process alive for the length of the hunt, which a
  /// background job cannot be relied on to do: the system may defer it past
  /// the very cutoff it is trying to hit.
  ///
  /// [payload] identifies the account whose hunt it is, so the Dart side knows
  /// whose configuration to read.
  Future<void> startHuntService({String? payload}) async {
    await _call<void>('startHuntService', {'payload': payload});
  }

  /// Stops the hunt's foreground service.
  ///
  /// Called on every exit path, including a successful purchase: the service
  /// is released the moment there is nothing left to hunt for.
  Future<void> stopHuntService() async {
    await _call<void>('stopHuntService');
  }

  /// Invokes a platform method, surfacing any failure.
  ///
  /// A silent failure here is the worst kind: the app would appear to have
  /// saved an account or a password when it had not, and the user would only
  /// find out when the app failed to log in later. So the error is re-thrown
  /// with the platform's message attached.
  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw StateError('platform call "$method" failed: ${e.message}');
    } on MissingPluginException catch (e) {
      throw StateError(
        'platform call "$method" failed: the platform is not available. '
        'This happens in a test, or before the activity is ready. ($e)',
      );
    }
  }

  /// Registers a handler for the platform asking for a hunt.
  ///
  /// The handler is called for the platform's own requests: a hunt, a
  /// reminder alarm that fired, a reboot, and a notification tap.
  ///
  /// The payload distinguishes them. A reminder's payload names a slot
  /// (`lunch`, `evening`); anything else is the platform asking the app to
  /// act on its own state.
  void onHuntRequested(void Function(String? payload) handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'huntRequested') {
        handler(call.arguments as String?);
      }
      if (call.method == 'reminderFired') {
        handler(call.arguments as String?);
      }
      if (call.method == 'rebootCompleted') {
        handler(null);
      }
      if (call.method == 'deepLink') {
        handler(call.arguments as String?);
      }
      return null;
    });
  }
}

/// A [SecureCredentialStore] on the Android Keystore.
class _KeystoreCredentialStore implements SecureCredentialStore {
  _KeystoreCredentialStore(this._bridge);

  final PlatformBridge _bridge;

  @override
  Future<Credentials?> read(AccountId accountId) async {
    final result = await _bridge._call<Map<Object?, Object?>>(
      'secureRead',
      {'accountId': accountId},
    );
    if (result == null) return null;
    final studentId = result['studentId'];
    final password = result['password'];
    if (studentId is! String || password is! String) return null;
    return Credentials(studentId: studentId, password: password);
  }

  @override
  Future<void> write(AccountId accountId, Credentials credentials) async {
    await _bridge._call<void>('secureWrite', {
      'accountId': accountId,
      'studentId': credentials.studentId,
      'password': credentials.password,
    });
  }

  @override
  Future<void> delete(AccountId accountId) async {
    await _bridge._call<void>('secureDelete', {
      'accountId': accountId,
    });
  }

  @override
  Future<List<AccountId>> listAccountIds() async {
    final result = await _bridge._call<List<Object?>>('secureList');
    if (result == null) return const [];
    return result.whereType<String>().toList();
  }
}

/// A [PlainStore] on SharedPreferences.
class _PreferencesStore implements PlainStore {
  _PreferencesStore(this._bridge);

  final PlatformBridge _bridge;

  @override
  Future<String?> readString(String key) async =>
      await _bridge._call<String>('plainReadString', {'key': key});

  @override
  Future<void> writeString(String key, String? value) async {
    await _bridge._call('plainWriteString', {
      'key': key,
      'value': value,
    });
  }

  @override
  Future<int?> readInt(String key) async =>
      await _bridge._call<int>('plainReadInt', {'key': key});

  @override
  Future<void> writeInt(String key, int value) async {
    await _bridge._call<void>('plainWriteInt', {
      'key': key,
      'value': value,
    });
  }

  @override
  Future<bool?> readBool(String key) async =>
      await _bridge._call<bool>('plainReadBool', {'key': key});

  @override
  Future<void> writeBool(String key, bool value) async {
    await _bridge._call<void>('plainWriteBool', {
      'key': key,
      'value': value,
    });
  }

  @override
  Future<void> remove(String key) async {
    await _bridge._call<void>('plainRemove', {'key': key});
  }

  @override
  Future<Set<String>> keys() async {
    final result = await _bridge._call<List<Object?>>('plainKeys');
    if (result == null) return <String>{};
    return result.whereType<String>().toSet();
  }
}
