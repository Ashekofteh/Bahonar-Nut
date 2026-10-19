/// HTML parsing helpers for the Cullinan portal.
///
/// Hand-rolled rather than pulled from a package, for two reasons: the portal's
/// markup is small and known, and a dependency-free parser keeps the adapter
/// auditable against the live HTML that produced it. The risk with hand-rolled
/// parsing is silent breakage when the site changes, which is why every parser
/// here is paired with a test against a captured fixture.
library;

/// A parsed `<select>`.
class ParsedSelect {
  const ParsedSelect({
    required this.name,
    required this.options,
    this.selectedValue,
  });

  final String name;
  final List<ParsedOption> options;

  /// The value of the option marked `selected`, when there is one.
  final String? selectedValue;

  /// The option with the given value, or null.
  ParsedOption? optionWithValue(String value) {
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }

  /// The selected option, or the first one.
  ParsedOption? get selected =>
      selectedValue != null ? optionWithValue(selectedValue!) : null;
}

class ParsedOption {
  const ParsedOption({required this.value, required this.text});

  final String value;
  final String text;
}

/// A parsed `<tr>`.
class ParsedRow {
  const ParsedRow({required this.cells, required this.raw});

  final List<String> cells;
  final String raw;

  /// Cell [index], or an empty string when the row is short.
  String cell(int index) => index < cells.length ? cells[index] : '';
}

/// A parsed `<input>`.
class ParsedInput {
  const ParsedInput({
    required this.name,
    required this.id,
    required this.type,
    required this.value,
    required this.checked,
    required this.disabled,
  });

  final String name;
  final String id;
  final String type;
  final String value;
  final bool checked;
  final bool disabled;
}

/// Extracts the value of a hidden input by id or name.
String hiddenFieldValue(String html, String nameOrId) {
  final byId = RegExp(
    '<input[^>]*id="${RegExp.escape(nameOrId)}"[^>]*value="([^"]*)"',
    dotAll: true,
  ).firstMatch(html);
  if (byId != null) return byId.group(1)!;

  final byName = RegExp(
    '<input[^>]*name="${RegExp.escape(nameOrId)}"[^>]*value="([^"]*)"',
    dotAll: true,
  ).firstMatch(html);
  return byName?.group(1) ?? '';
}

/// Extracts the text of a `<label>` by id.
String? labelText(String html, String id) {
  final match = RegExp(
    '<label[^>]*id="${RegExp.escape(id)}"[^>]*>(.*?)</label>',
    dotAll: true,
  ).firstMatch(html);
  if (match == null) return null;
  final text = stripTags(match.group(1)!);
  return text.isEmpty ? null : text;
}

/// Extracts the text of any element with the given id.
String? elementText(String html, String id) {
  final match = RegExp(
    '<(label|span|div|td)[^>]*id="[^"]*${RegExp.escape(id)}"[^>]*>(.*?)</\\1>',
    dotAll: true,
  ).firstMatch(html);
  if (match == null) return null;
  final text = stripTags(match.group(2)!);
  return text.isEmpty ? null : text;
}

/// Every `<select>` in [html].
List<ParsedSelect> selects(String html) {
  final out = <ParsedSelect>[];
  for (final match in RegExp(
    '<select([^>]*)>(.*?)</select>',
    dotAll: true,
  ).allMatches(html)) {
    final attributes = match.group(1)!;
    final name = _attribute(attributes, 'name') ?? '';
    final options = <ParsedOption>[];
    String? selected;

    for (final optionMatch in RegExp(
      '<option([^>]*)>(.*?)</option>',
      dotAll: true,
    ).allMatches(match.group(2)!)) {
      final optionAttributes = optionMatch.group(1)!;
      final value = _attribute(optionAttributes, 'value');
      final text = stripTags(optionMatch.group(2)!);
      final optionValue = value ?? text;
      options.add(ParsedOption(value: optionValue, text: text));
      if (_attribute(optionAttributes, 'selected') != null &&
          selected == null) {
        selected = optionValue;
      }
    }

    out.add(ParsedSelect(
      name: name,
      options: options,
      selectedValue: selected,
    ));
  }
  return out;
}

/// The `<select>` whose name ends with [suffix].
ParsedSelect? selectBySuffix(String html, String suffix) {
  for (final select in selects(html)) {
    if (select.name.endsWith(suffix)) return select;
  }
  return null;
}

/// Every `<select>` whose name ends with [suffix].
List<ParsedSelect> selectsBySuffix(String html, String suffix) =>
    selects(html).where((s) => s.name.endsWith(suffix)).toList();

/// The rows of the `<table>` whose id ends with [tableIdSuffix].
List<ParsedRow> tableRows(String html, String tableIdSuffix) {
  final table = RegExp(
    '<table[^>]*id="[^"]*${RegExp.escape(tableIdSuffix)}"[^>]*>(.*?)</table>',
    dotAll: true,
  ).firstMatch(html);
  if (table == null) return const [];

  final rows = <ParsedRow>[];
  for (final match in RegExp('<tr[^>]*>(.*?)</tr>', dotAll: true)
      .allMatches(table.group(1)!)) {
    final raw = match.group(1)!;
    final cells = RegExp('<td[^>]*>(.*?)</td>', dotAll: true)
        .allMatches(raw)
        .map((m) => stripTags(m.group(1)!))
        .toList();
    rows.add(ParsedRow(cells: cells, raw: raw));
  }
  return rows;
}

/// The `<input>` elements inside [html].
List<ParsedInput> inputs(String html) {
  final out = <ParsedInput>[];
  for (final match in RegExp('<input([^>]*)>', dotAll: true).allMatches(html)) {
    final attributes = match.group(1)!;
    out.add(ParsedInput(
      name: _attribute(attributes, 'name') ?? '',
      id: _attribute(attributes, 'id') ?? '',
      type: (_attribute(attributes, 'type') ?? 'text').toLowerCase(),
      value: _attribute(attributes, 'value') ?? '',
      checked: _attribute(attributes, 'checked') != null,
      disabled: _attribute(attributes, 'disabled') != null,
    ));
  }
  return out;
}

/// The first `<input>` whose name ends with [suffix].
ParsedInput? inputBySuffix(String html, String suffix) {
  for (final input in inputs(html)) {
    if (input.name.endsWith(suffix)) return input;
  }
  return null;
}

/// Strips tags and collapses whitespace.
///
/// Handles the Persian text the portal serves, which is RTL and often padded
/// with non-breaking spaces.
String stripTags(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Reads an attribute from a raw tag's attribute string.
String? _attribute(String attributes, String name) {
  final match = RegExp(
    '${RegExp.escape(name)}\\s*=\\s*"([^"]*)"',
    caseSensitive: false,
  ).firstMatch(attributes);
  return match?.group(1);
}

/// Parses a Rial amount, tolerating separators and Persian digits.
///
/// The portal writes `225,000 ريال`; the value we need is the integer.
int? parseRial(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0x06F0 && rune <= 0x06F9) {
      // Persian digit -> ASCII.
      buffer.writeCharCode(rune - 0x06F0 + 0x30);
    } else if (rune >= 0x30 && rune <= 0x39) {
      buffer.writeCharCode(rune);
    }
    // Separators and the currency word are dropped.
  }
  final digits = buffer.toString();
  if (digits.isEmpty) return null;
  return int.tryParse(digits);
}
