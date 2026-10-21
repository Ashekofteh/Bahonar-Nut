/// The payment gateway: the bank's own page, inside the app.
///
/// ## Why a WebView and not the app's HTTP client
///
/// The bank gateway is **not reachable from the app's transport**. Every
/// attempt to follow the portal's redirect to `sadad.shaparak.ir` fails the
/// TLS handshake — from Dart's `HttpClient`, from `curl`, and from Python
/// alike, on all three Shaparak hosts (F55). It is a network path, not a
/// client bug, and no amount of retrying in Dart would fix it.
///
/// And even if it were reachable, a card-entry page needs a browser: it is
/// a form-posting page with the bank's own scripts, and it is the only
/// thing on Android with a browser engine. So the gateway is opened in a
/// WebView, and the app keeps everything else — the amount, the token, the
/// confirmation — in its own tested transport.
///
/// ## Why the session cookies are injected
///
/// The gateway's return posts back to the portal, and the portal credits the
/// account that **started** the payment. So the WebView has to carry the
/// portal's session cookies, or the return would credit nobody.
///
/// ## How the app knows the payment is done
///
/// The gateway returns to the portal, so a navigation back to the portal's
/// host is the signal. The app then **re-reads** the portal's payment list,
/// which is the authority on what happened (F58) — the balance alone cannot
/// say, because the credit is applied asynchronously.
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// The screen that hosts the bank's payment page.
class TopUpGatewayScreen extends StatefulWidget {
  const TopUpGatewayScreen({
    super.key,
    required this.gateway,
    required this.cookies,
    required this.portalHost,
    this.onReturned,
  });

  /// The bank's gateway URL, with the token the portal minted.
  final Uri gateway;

  /// The portal's session cookies, so the return credits the right account.
  final Map<String, String> cookies;

  /// The portal's host — the signal that the payment is finished.
  final String portalHost;

  /// Called when the gateway returns to the portal.
  final void Function()? onReturned;

  @override
  State<TopUpGatewayScreen> createState() => _TopUpGatewayScreenState();
}

class _TopUpGatewayScreenState extends State<TopUpGatewayScreen> {
  late final WebViewController _controller;

  int _progress = 0;
  String? _error;
  bool _returned = false;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url != null) _onUrl(url);
          },
          onNavigationRequest: (request) => _onUrl(request.url),
          onWebResourceError: (error) {
            // A failed sub-resource must not close the page: the gateway
            // loads images and scripts from elsewhere, and one missing
            // script is not a failed payment.
            if (error.isForMainFrame == true) {
              if (mounted) {
                setState(() => _error = 'صفحه درگاه پرداخت باز نشد.');
              }
            }
          },
        ),
      );

    _load();
  }

  /// Puts the portal's cookies in place, then opens the gateway.
  ///
  /// The cookies go in **before** the load, so the very first request the
  /// gateway makes already carries them.
  Future<void> _load() async {
    final manager = WebViewCookieManager();
    final host = widget.gateway.host;

    for (final entry in widget.cookies.entries) {
      await manager.setCookie(
        WebViewCookie(
          name: entry.key,
          value: entry.value,
          domain: host,
          path: '/',
        ),
      );
    }

    // The portal's own cookies live on the portal's host, and the return
    // goes back there — so those are set on the portal's domain too.
    for (final entry in widget.cookies.entries) {
      await manager.setCookie(
        WebViewCookie(
          name: entry.key,
          value: entry.value,
          domain: widget.portalHost,
          path: '/',
        ),
      );
    }

    await _controller.loadRequest(widget.gateway);
  }

  /// Watches for the return to the portal.
  NavigationDecision _onUrl(String url) {
    if (_returned) return NavigationDecision.navigate;

    final uri = Uri.tryParse(url);
    if (uri == null) return NavigationDecision.navigate;

    // The gateway returns to the portal when the payment is done — and only
    // then. This is the signal to re-read the payment list.
    if (uri.host == widget.portalHost) {
      _returned = true;
      if (mounted) {
        // The navigation is allowed: the portal's own page is the receipt,
        // and the student should see it.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onReturned?.call();
        });
      }
    }

    return NavigationDecision.navigate;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('پرداخت اینترنتی'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: LinearProgressIndicator(
            value: _progress == 100 ? null : _progress / 100,
          ),
        ),
      ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: theme.colorScheme.errorContainer,
              ),
              child: Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}
