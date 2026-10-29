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

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/bank_card.dart';
import '../../core/persian.dart';

/// The screen that hosts the bank's payment page.
class TopUpGatewayScreen extends StatefulWidget {
  const TopUpGatewayScreen({
    super.key,
    required this.gateway,
    required this.cookies,
    required this.portalHost,
    this.savedCards = const [],
    this.onSaveCard,
    this.onDeleteCard,
    this.onReturned,
  });

  /// The bank's gateway URL, with the token the portal minted.
  final Uri gateway;

  /// The portal's session cookies, so the return credits the right account.
  final Map<String, String> cookies;

  /// The portal's host — the signal that the payment is finished.
  final String portalHost;

  /// The list of saved bank cards available for auto-filling.
  final List<SavedBankCard> savedCards;

  /// Invoked when the user confirms saving a new card.
  final Future<void> Function(SavedBankCard card)? onSaveCard;

  /// Invoked when the user deletes a saved card.
  final Future<void> Function(String id)? onDeleteCard;

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
  bool _paymentSuccessDetected = false;
  bool _hasPromptedSaveCard = false;
  SavedBankCard? _pendingCardToSave;
  late List<SavedBankCard> _cards;

  @override
  void initState() {
    super.initState();
    _cards = List.of(widget.savedCards);

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'BankCardCaptureChannel',
        onMessageReceived: _handleChannelMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url != null) _onUrl(url);
          },
          onPageFinished: (url) {
            _injectGatewayScript();
            _onUrl(url);
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

  void _handleChannelMessage(JavaScriptMessage message) {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final type = data['type'] as String?;

      if (type == 'card_input') {
        final pan = (data['pan'] as String? ?? '').replaceAll(RegExp(r'\D'), '');
        if (pan.length == 16) {
          final cvv2 = data['cvv2'] as String?;
          final expMonth = data['expMonth'] as String?;
          final expYear = data['expYear'] as String?;
          final bank = detectBankName(pan);

          final isAlreadySaved = _cards.any((c) => c.cleanPan == pan);
          if (!isAlreadySaved) {
            _pendingCardToSave = SavedBankCard(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              pan: pan,
              cvv2: cvv2?.isNotEmpty == true ? cvv2 : null,
              expMonth: expMonth?.isNotEmpty == true ? expMonth : null,
              expYear: expYear?.isNotEmpty == true ? expYear : null,
              bankName: bank,
              title: bank,
              savedAt: DateTime.now(),
            );
          }
        }
      } else if (type == 'payment_success') {
        if (mounted && !_paymentSuccessDetected) {
          setState(() => _paymentSuccessDetected = true);
        }
      }
    } catch (_) {}
  }

  Future<void> _injectGatewayScript() async {
    const script = r'''
(function() {
  function toEngDigits(str) {
    if (!str) return '';
    const fa = ['۰','۱','۲','۳','۴','۵','۶','۷','۸','۹'];
    const ar = ['٠','١','٢','٣','٤','٥','٦','٧','٨','٩'];
    let res = str.toString();
    for (let i = 0; i < 10; i++) {
      res = res.replaceAll(fa[i], i.toString()).replaceAll(ar[i], i.toString());
    }
    return res;
  }

  function cleanDigits(val) {
    return toEngDigits(val).replace(/\D/g, '');
  }

  function captureFormValues() {
    let pan = '';
    const splitInputs = document.querySelectorAll('input[id*="pan" i], input[name*="pan" i], input[id*="card" i], input[name*="card" i]');
    if (splitInputs.length >= 4) {
      let isFourFour = true;
      let combined = '';
      for (let i = 0; i < 4; i++) {
        if (splitInputs[i].maxLength > 4) { isFourFour = false; break; }
        combined += cleanDigits(splitInputs[i].value);
      }
      if (isFourFour && combined.length === 16) {
        pan = combined;
      }
    }

    if (pan.length !== 16) {
      const panSelectors = [
        '#CardNumber', '#cardNumber', '#cardnumber', '#pan', '#pan-input',
        'input[autocomplete="cc-number"]',
        'input[name="CardNumber"]', 'input[name="cardNumber"]', 'input[name="pan"]',
        'input[id*="card" i]:not([id*="pass" i]):not([id*="cvv" i]):not([id*="exp" i]):not([id*="pin" i])',
        'input[name*="card" i]:not([name*="pass" i]):not([name*="cvv" i]):not([name*="exp" i]):not([name*="pin" i])',
        'input[id*="pan" i]', 'input[name*="pan" i]',
        'input[placeholder*="کارت"]'
      ];
      for (const s of panSelectors) {
        const el = document.querySelector(s);
        if (el && el.type !== 'hidden') {
          const val = cleanDigits(el.value);
          if (val.length === 16) {
            pan = val;
            break;
          }
        }
      }
    }

    let cvv2 = '';
    const cvvSelectors = [
      '#Cvv2', '#cvv2', '#cvv', 'input[autocomplete="cc-csc"]',
      'input[id*="cvv" i]', 'input[name*="cvv" i]',
      'input[placeholder*="cvv" i]', 'input[placeholder*="CVV" i]'
    ];
    for (const s of cvvSelectors) {
      const el = document.querySelector(s);
      if (el && el.type !== 'hidden') {
        const val = cleanDigits(el.value);
        if (val.length >= 3 && val.length <= 4) {
          cvv2 = val;
          break;
        }
      }
    }

    let expMonth = '';
    const mSelectors = [
      '#ExpireMonth', '#expMonth', '#month', 'select[id*="month" i]',
      'input[id*="month" i]', 'input[name*="month" i]', 'select[name*="month" i]'
    ];
    for (const s of mSelectors) {
      const el = document.querySelector(s);
      if (el) {
        const val = cleanDigits(el.value);
        if (val.length === 1 || val.length === 2) {
          expMonth = val.padStart(2, '0');
          break;
        }
      }
    }

    let expYear = '';
    const ySelectors = [
      '#ExpireYear', '#expYear', '#year', 'select[id*="year" i]',
      'input[id*="year" i]', 'input[name*="year" i]', 'select[name*="year" i]'
    ];
    for (const s of ySelectors) {
      const el = document.querySelector(s);
      if (el) {
        let val = cleanDigits(el.value);
        if (val.length === 4 && val.startsWith('14')) val = val.substring(2);
        if (val.length === 2) {
          expYear = val;
          break;
        }
      }
    }

    if (pan.length === 16) {
      if (window.BankCardCaptureChannel) {
        window.BankCardCaptureChannel.postMessage(JSON.stringify({
          type: 'card_input',
          pan: pan,
          cvv2: cvv2,
          expMonth: expMonth,
          expYear: expYear
        }));
      }
    }
  }

  function attachListeners() {
    document.querySelectorAll('input, select').forEach(el => {
      el.removeEventListener('change', captureFormValues);
      el.removeEventListener('blur', captureFormValues);
      el.addEventListener('change', captureFormValues);
      el.addEventListener('blur', captureFormValues);
    });

    document.querySelectorAll('form').forEach(form => {
      form.removeEventListener('submit', captureFormValues);
      form.addEventListener('submit', captureFormValues);
    });

    document.querySelectorAll('button, input[type="submit"], input[type="button"], a').forEach(btn => {
      btn.removeEventListener('click', captureFormValues);
      btn.addEventListener('click', captureFormValues);
    });
  }

  function checkSuccessAndAutoReturn() {
    const pageText = document.body ? (document.body.innerText || '') : '';
    const hasSuccessText = pageText.includes('پرداخت با موفقیت انجام شد') || 
                           pageText.includes('تراکنش با موفقیت') || 
                           pageText.includes('تکمیل فرآیند خرید');

    if (hasSuccessText) {
      if (window.BankCardCaptureChannel) {
        window.BankCardCaptureChannel.postMessage(JSON.stringify({
          type: 'payment_success'
        }));
      }

      const buttons = document.querySelectorAll('button, input[type="submit"], input[type="button"], a, #btnConfirm, #submitBtn');
      for (const btn of buttons) {
        const text = (btn.innerText || btn.value || '').trim();
        if (text.includes('تکمیل فرآیند خرید') || text.includes('تکمیل خرید') || text.includes('بازگشت به سایت پذیرنده')) {
          setTimeout(() => {
            try { btn.click(); } catch(e) {}
          }, 800);
          break;
        }
      }
    }
  }

  attachListeners();
  checkSuccessAndAutoReturn();
  if (!window.__bankCaptureInterval) {
    window.__bankCaptureInterval = setInterval(() => {
      captureFormValues();
      checkSuccessAndAutoReturn();
    }, 1200);
  }
})();
''';
    try {
      await _controller.runJavaScript(script);
    } catch (_) {}
  }

  Future<void> _autoFillCard(SavedBankCard card) async {
    final pan = card.cleanPan;
    final cvv2 = card.cvv2 ?? '';
    final expMonth = card.expMonth ?? '';
    final expYear = card.expYear ?? '';

    final script = '''
(function() {
  const pan = '$pan';
  const cvv2 = '$cvv2';
  const expMonth = '$expMonth';
  const expYear = '$expYear';

  function setVal(el, val) {
    if (!el || !val) return false;
    el.focus();
    el.value = val;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.dispatchEvent(new Event('blur', { bubbles: true }));
    return true;
  }

  let panFilled = false;
  const splitInputs = document.querySelectorAll('input[id*="pan" i], input[name*="pan" i], input[id*="card" i], input[name*="card" i]');
  if (splitInputs.length >= 4) {
    let isFourFour = true;
    for (let i = 0; i < 4; i++) {
      if (splitInputs[i].maxLength > 4) { isFourFour = false; break; }
    }
    if (isFourFour) {
      for (let i = 0; i < 4; i++) {
        setVal(splitInputs[i], pan.substring(i * 4, (i + 1) * 4));
      }
      panFilled = true;
    }
  }

  if (!panFilled) {
    const panSelectors = [
      '#CardNumber', '#cardNumber', '#cardnumber', '#pan', '#pan-input',
      'input[autocomplete="cc-number"]',
      'input[name="CardNumber"]', 'input[name="cardNumber"]', 'input[name="pan"]',
      'input[id*="card" i]:not([id*="pass" i]):not([id*="cvv" i]):not([id*="exp" i]):not([id*="pin" i])',
      'input[name*="card" i]:not([name*="pass" i]):not([name*="cvv" i]):not([name*="exp" i]):not([name*="pin" i])',
      'input[id*="pan" i]', 'input[name*="pan" i]',
      'input[placeholder*="کارت"]'
    ];
    for (const s of panSelectors) {
      const el = document.querySelector(s);
      if (el && el.type !== 'hidden') {
        setVal(el, pan);
        break;
      }
    }
  }

  if (cvv2) {
    const cvvSelectors = [
      '#Cvv2', '#cvv2', '#cvv', 'input[autocomplete="cc-csc"]',
      'input[id*="cvv" i]', 'input[name*="cvv" i]'
    ];
    for (const s of cvvSelectors) {
      const el = document.querySelector(s);
      if (el && el.type !== 'hidden') {
        setVal(el, cvv2);
        break;
      }
    }
  }

  if (expMonth) {
    const mSelectors = [
      '#ExpireMonth', '#expMonth', '#month', 'select[id*="month" i]',
      'input[id*="month" i]', 'input[name*="month" i]', 'select[name*="month" i]'
    ];
    for (const s of mSelectors) {
      const el = document.querySelector(s);
      if (el) {
        setVal(el, expMonth);
        break;
      }
    }
  }
  if (expYear) {
    const ySelectors = [
      '#ExpireYear', '#expYear', '#year', 'select[id*="year" i]',
      'input[id*="year" i]', 'input[name*="year" i]', 'select[name*="year" i]'
    ];
    for (const s of ySelectors) {
      const el = document.querySelector(s);
      if (el) {
        setVal(el, expYear);
        break;
      }
    }
  }
})();
''';
    try {
      await _controller.runJavaScript(script);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('اطلاعات کارت ${card.displayName} در فرم درگاه قرار گرفت.'),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.indigo.shade700,
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _promptSaveCardIfPending() async {
    final card = _pendingCardToSave;
    if (card == null || _hasPromptedSaveCard) return;
    _hasPromptedSaveCard = true;

    final nameController = TextEditingController(
      text: card.title ?? card.bankName ?? 'کارت من',
    );

    final shouldSave = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.credit_card, color: Colors.blue),
            SizedBox(width: 8),
            Text('ذخیره اطلاعات کارت بانکی'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'آیا مایلید اطلاعات این کارت برای پرداخت‌های بعدی ذخیره شود تا در دفعات بعد نیازی به وارد کردن مجدد نباشد؟',
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(dialogCtx).colorScheme.primaryContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(dialogCtx).colorScheme.primary.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          card.bankName ?? 'کارت شتاب',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Icon(Icons.payment, size: 20),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        toPersianDigits(card.maskedPan),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 16,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (card.expMonth != null && card.expYear != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'انقضا: ${toPersianDigits(card.expYear!)}/${toPersianDigits(card.expMonth!)}',
                        style: Theme.of(dialogCtx).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'نام دلخواه کارت',
                  hintText: 'مثلاً: کارت سامان، کارت اصلی',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('انصراف'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            icon: const Icon(Icons.save),
            label: const Text('ذخیره کارت'),
          ),
        ],
      ),
    );

    if (shouldSave == true) {
      final title = nameController.text.trim();
      final toSave = card.copyWith(
        title: title.isNotEmpty ? title : (card.bankName ?? 'کارت من'),
      );
      await widget.onSaveCard?.call(toSave);
      if (mounted) {
        setState(() {
          _cards.removeWhere((c) => c.cleanPan == toSave.cleanPan);
          _cards.insert(0, toSave);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('کارت ${toSave.displayName} با موفقیت ذخیره شد.'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    }
  }

  Future<void> _finishAndReturn() async {
    if (_pendingCardToSave != null && !_hasPromptedSaveCard) {
      await _promptSaveCardIfPending();
    }
    widget.onReturned?.call();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// Puts the portal's cookies in place, then opens the gateway.
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
    if (uri.host == widget.portalHost ||
        uri.host.contains('uk.ac.ir') ||
        uri.path.contains('ePay') ||
        uri.path.contains('MyePayList')) {
      if (!_returned) {
        _returned = true;
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (_pendingCardToSave != null && !_hasPromptedSaveCard) {
              await _promptSaveCardIfPending();
            }
            if (mounted) {
              widget.onReturned?.call();
              Future.delayed(const Duration(milliseconds: 1500), () {
                if (mounted) Navigator.of(context).maybePop();
              });
            }
          });
        }
      }
    }

    return NavigationDecision.navigate;
  }

  @override
  void dispose() {
    _controller.loadRequest(Uri.parse('about:blank'));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _finishAndReturn();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('پرداخت اینترنتی'),
          actions: [
            FilledButton.tonalIcon(
              onPressed: _finishAndReturn,
              icon: Icon(
                Icons.check_circle_outline,
                color: _paymentSuccessDetected ? Colors.green.shade800 : null,
              ),
              label: Text(
                'تکمیل و بازگشت',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _paymentSuccessDetected ? Colors.green.shade900 : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
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
            if (_paymentSuccessDetected)
              Container(
                width: double.infinity,
                color: Colors.green.shade800,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'پرداخت با موفقیت انجام شد! برای ثبت نهایی و افزایش موجودی روی تکمیل و بازگشت بزنید.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.green.shade900,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      ),
                      onPressed: _finishAndReturn,
                      child: const Text(
                        'تکمیل و بازگشت',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            if (_cards.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  border: Border(
                    bottom: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.3),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.credit_card, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          'کارت‌های ذخیره‌شده (برای تکمیل خودکار ضربه بزنید):',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final card in _cards)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: InputChip(
                                avatar: const Icon(Icons.payment, size: 16),
                                label: Text(
                                  '${card.displayName} (${toPersianDigits(card.lastFourDigits)})',
                                ),
                                tooltip: 'درج خودکار اطلاعات ${card.displayName}',
                                onPressed: () => _autoFillCard(card),
                                onDeleted: widget.onDeleteCard != null
                                    ? () async {
                                        await widget.onDeleteCard!(card.id);
                                        if (mounted) {
                                          setState(() => _cards.removeWhere((c) => c.id == card.id));
                                        }
                                      }
                                    : null,
                                deleteIcon: const Icon(Icons.close, size: 14),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: WebViewWidget(controller: _controller),
            ),
          ],
        ),
      ),
    );
  }
}
