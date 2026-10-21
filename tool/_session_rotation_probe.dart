/// Probes the portal's session-cookie behaviour.
///
/// READ-ONLY: it only reads the login page and the CAPTCHA.
///
/// ## Why
///
/// A read between fetching the CAPTCHA image and posting the answer makes the
/// answer wrong. The hypothesis was that the portal binds the answer to the
/// `ASP.NET_SessionId` that was current at image-fetch time, and that the id
/// rotates on every request. This probe prints the raw `Set-Cookie` headers
/// so the mechanism is established rather than assumed.
///
/// Usage: `dart run tool/_session_rotation_probe.dart`
// Diagnostic CLI tool: stdout printing is the entire point.
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings

library;

import 'package:http/http.dart' as http;

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  final client = http.Client();
  try {
    print('=== GET / (the login page) ===');
    final first = await client.get(Uri.parse('${_base}'));
    _dump('GET /', first);

    print('\n=== GET /UserControls/Captcha.ashx, same session ===');
    final second = await client.get(
      Uri.parse('${_base}UserControls/Captcha.ashx'),
      headers: {'cookie': _cookieHeader(first)},
    );
    _dump('GET Captcha.ashx', second);

    print('\n=== GET / again, same session ===');
    final third = await client.get(
      Uri.parse('${_base}'),
      headers: {'cookie': _cookieHeader(second)},
    );
    _dump('GET / (second)', third);

    print('\n=== GET Captcha.ashx with the cookies as they now stand ===');
    final fourth = await client.get(
      Uri.parse('${_base}UserControls/Captcha.ashx'),
      headers: {'cookie': _cookieHeader(third)},
    );
    _dump('GET Captcha.ashx (second)', fourth);
  } finally {
    client.close();
  }
}

/// The cookie names the portal sets, and the only ones we care about here.
const _names = ['ASP.NET_SessionId', 'keyId', '__AntiXsrfToken'];

void _dump(String what, http.Response response) {
  print('  $what -> HTTP ${response.statusCode}');
  final raw = response.headers['set-cookie'];
  if (raw == null || raw.isEmpty) {
    print('    (no Set-Cookie)');
    return;
  }
  for (final name in _names) {
    final match = RegExp('$name=([^;,]*)').firstMatch(raw);
    if (match != null) {
      print('    $name = ${match.group(1)}');
    }
  }
}

String _cookieHeader(http.Response response) {
  final raw = response.headers['set-cookie'];
  if (raw == null) return '';
  final parts = <String>[];
  for (final name in _names) {
    final match = RegExp('$name=([^;,]*)').firstMatch(raw);
    if (match != null) parts.add('$name=${match.group(1)}');
  }
  return parts.join('; ');
}
