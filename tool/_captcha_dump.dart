/// Saves the portal's CAPTCHA images to disk, for inspection.
///
/// READ-ONLY: it only fetches the image and writes it to a local folder.
///
/// ## Why
///
/// The solver declined on 20 of 20 live images, all of them exactly the
/// same size, with a confidence of zero. A confidence of zero means every
/// glyph matched its template equally well — which is what a picture with
/// no glyphs in it looks like. So either the portal changed the image, or
/// the response is no longer an image at all.
///
/// Writing the bytes down settles it: a GIF header means an image, and
/// anything else means the endpoint is answering with something else.
///
/// Usage: `dart run tool/_captcha_dump.dart <studentId> [count]
library;

import 'dart:io';

import 'package:bahonar_nut/adapter/captcha_solver.dart';
import 'package:bahonar_nut/transport/http_transport.dart';

const _base = 'https://nut.uk.ac.ir/';

Future<void> main(List<String> args) async {
  if (args.length < 1) {
    print('usage: dart run tool/_captcha_dump.dart <id> [count]');
    return;
  }
  final user = args[0];
  final count = args.length > 1 ? int.parse(args[1]) : 5;
  final out = Directory('${Directory.current.path}/.shots/captcha');
  if (!out.existsSync()) out.createSync(recursive: true);

  final transport = PortalTransport(baseUri: Uri.parse(_base));
  final solver = CaptchaSolver();
  try {
    for (var i = 0; i < count; i++) {
      await transport.get(user, '/');
      final image = await transport.getBytes(user, '/UserControls/Captcha.ashx');
      final header = image.length > 6
          ? image.sublist(0, 6).toList()
          : const <int>[];
      final isGif = header.length == 6 &&
          header[0] == 0x47 &&
          header[1] == 0x49 &&
          header[2] == 0x46;
      final isPng = header.length == 6 &&
          header[0] == 0x89 &&
          header[1] == 0x50 &&
          header[2] == 0x4E;
      final path = '${out.path}/cap$i.bin';
      File(path).writeAsBytesSync(image);
      final solution = solver.solve(image);
      print('${(i + 1).toString().padLeft(3)}: ${image.length} bytes  '
          'gif=$isGif png=$isPng  '
          'solver="${solution.text}" conf=${solution.confidence}  '
          '-> $path');
      if (!isGif && !isPng) {
        final head = image.length > 120 ? image.sublist(0, 120) : image;
        print('     not an image. first bytes: $head');
        print('     as text: ${String.fromCharCodes(image.take(300))}');
      }
    }
  } catch (e, st) {
    print('EXCEPTION: $e');
    print(st.toString().split('\n').take(6).join('\n'));
  } finally {
    transport.close();
  }
}
