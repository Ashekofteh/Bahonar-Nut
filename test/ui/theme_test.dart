import 'package:bahonar_nut/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The theme's contrast, checked rather than assumed.
///
/// ## Why this test exists
///
/// A chip label with **no colour** in its style inherits whatever ambient
/// colour it finds. In the widget test harness that ambient is dark, so the
/// label looked fine; on a device it was white, on a near-white chip, and
/// therefore invisible. The bug was only visible on the real screen.
///
/// So the label's colour is asserted here, against the theme's own scheme —
/// not against whatever the test harness happens to paint.
void main() {
  Color? chipLabelColour(WidgetTester tester, String label) {
    final rich = tester.widgetList<RichText>(find.byType(RichText)).firstWhere(
          (rt) => rt.text.toPlainText() == label,
        );
    return rich.text.style?.color;
  }

  Future<void> pumpChips(
    WidgetTester tester,
    ThemeData theme,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Column(
            children: [
              // `onSelected` is what makes a chip *enabled*, and an enabled
              // chip is the case that carries the readable label colour.
              ChoiceChip(
                label: const Text('unselected'),
                selected: false,
                onSelected: (_) {},
              ),
              ChoiceChip(
                label: const Text('selected'),
                selected: true,
                onSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the light theme', () {
    testWidgets('a chip label is coloured, not left to inherit',
        (tester) async {
      final theme = buildLightTheme();
      await pumpChips(tester, theme);

      final scheme = theme.colorScheme;
      expect(
        chipLabelColour(tester, 'unselected'),
        scheme.onSurfaceVariant,
        reason: 'an unselected chip label must be readable against the chip',
      );
      expect(
        chipLabelColour(tester, 'selected'),
        scheme.onSecondaryContainer,
        reason: 'a selected chip label must be readable against its fill',
      );
    });

    testWidgets('a chip label is not white on a light surface',
        (tester) async {
      await pumpChips(tester, buildLightTheme());

      for (final label in ['unselected', 'selected']) {
        final colour = chipLabelColour(tester, label);
        expect(colour, isNotNull, reason: '$label must carry a colour');
        expect(
          colour!.computeLuminance(),
          lessThan(0.5),
          reason: '$label must be dark on a light theme',
        );
      }
    });
  });

  group('the dark theme', () {
    testWidgets('a chip label is coloured, not left to inherit',
        (tester) async {
      final theme = buildDarkTheme();
      await pumpChips(tester, theme);

      final scheme = theme.colorScheme;
      expect(chipLabelColour(tester, 'unselected'), scheme.onSurfaceVariant);
      expect(chipLabelColour(tester, 'selected'), scheme.onSecondaryContainer);
    });
  });
}
