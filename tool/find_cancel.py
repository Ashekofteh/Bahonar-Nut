"""Find the weekly-reservation cancel mechanism, from a captured page.

The account currently holds a 1405/07/30 lunch whose row is `checked` AND
`disabled=false` — i.e. booked, on a date still editable. That row is the best
evidence available for how a held meal is released, so dump it in full.

Read-only: parses a capture file, makes no requests.
"""
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else 'captures/30_reservation_current.html'
html = open(path, encoding='utf-8').read()

out = []
out.append('FILE: %s' % path)

# The lunch grid.
table = re.search(
    r'<table[^>]*id="[^"]*grdReservationLunch"[^>]*>(.*?)</table>', html, re.DOTALL)
if not table:
    print('lunch grid not found')
    sys.exit(1)

for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', table.group(1), re.DOTALL):
    r = row.group(1)
    if '1405/07/30' not in r:
        continue
    out.append('')
    out.append('=== ROW 1405/07/30 (checked AND editable) ===')
    out.append(r)
    break

# Every control on the page whose name is not a plain drp*/chkReserve.
out.append('')
out.append('=== page-level submit / link controls ===')
for m in re.finditer(r'<input[^>]*type="submit"[^>]*>', html):
    out.append('  ' + m.group(0)[:220])
for m in re.finditer(r'<input[^>]*type="image"[^>]*>', html):
    out.append('  ' + m.group(0)[:220])

# Any hidden field carrying a meal id.
out.append('')
out.append('=== hidden inputs (names only, first 40) ===')
names = []
for m in re.finditer(r'<input[^>]*type="hidden"[^>]*name="([^"]+)"', html):
    names.append(m.group(1))
out.append('  ' + ', '.join(names[:40]))

# Javascript that could act on a selected row.
out.append('')
out.append('=== script functions mentioning cancel/row ===')
for m in re.finditer(r'function\s+(\w+)\s*\(([^)]*)\)\s*\{(.*?)\n\s*\}',
                     html, re.DOTALL):
    name, args, body = m.group(1), m.group(2), m.group(3)
    if re.search(r'(cancel|row|check|delete|remove|del)', name + body, re.I):
        out.append('  function %s(%s) { %s }' % (name, args, body.strip()[:300]))

# CheckThis, which the row's checkbox calls.
for m in re.finditer(r'function\s+CheckThis\s*\([^)]*\)\s*\{(.*?)\}', html, re.DOTALL):
    out.append('')
    out.append('=== CheckThis ===')
    out.append(m.group(0)[:800])

print('\n'.join(out))
