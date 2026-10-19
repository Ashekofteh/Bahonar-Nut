import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else 'captures/11_reserve_response_hall1.html'
html = open(path, encoding='utf-8').read()
out = []

# Any label/span/div that carries an error-ish message.
for m in re.finditer(
        r'<(label|span|div|p)\b[^>]*id="([^"]+)"[^>]*>(.*?)</\1>',
        html, re.DOTALL):
    txt = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', m.group(3))).strip()
    if not txt:
        continue
    ident = m.group(2)
    if re.search(r'(err|message|warn|confirm|alert|invalid|denied|lock|closed|not)', ident, re.I):
        out.append('ID %-28s = %r' % (ident, txt[:200]))

out.append('--- labels present ---')
for m in re.finditer(r'<label[^>]*id="([^"]+)"[^>]*>(.*?)</label>', html, re.DOTALL):
    txt = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', m.group(2))).strip()
    out.append('  %-30s %r' % (m.group(1), txt[:160]))

out.append('--- target row in the RESPONSE ---')
for m in re.finditer(r'<tr[^>]*>(.*?)</tr>', html, re.DOTALL):
    r = m.group(1)
    if '1405/07/28' not in r:
        continue
    cells = re.findall(r'<td[^>]*>(.*?)</td>', r, re.DOTALL)
    if len(cells) < 4:
        continue
    out.append('  label=%r' % re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[1])).strip())
    for c in cells:
        t = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', c)).strip()
        out.append('     cell: %r' % t[:150])
        for cb in re.finditer(r'<input[^>]*type="checkbox"[^>]*>', c):
            out.append('        CB: %s' % cb.group(0)[:170])
        for sel in re.finditer(r'<select[^>]*name="([^"]+)"[^>]*>', c):
            out.append('        SEL: %s' % sel.group(1))
    break

out.append('--- script alerts ---')
for m in re.finditer(r'alert\s*\((.*?)\)', html, re.DOTALL):
    out.append('  ' + re.sub(r'\s+', ' ', m.group(1))[:200])

out.append('--- text mentioning the meal / error in Persian ---')
plain = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', html))
for kw in ['امکان', 'امکان ندارد', 'گذشته', 'بسته', 'مهلت', 'خطا', 'اکبرجوجه']:
    for m in re.finditer(re.escape(kw), plain):
        s = max(0, m.start() - 90)
        out.append('  [%s] ...%s...' % (kw, plain[s:m.end() + 90]))

print('\n'.join(out))
