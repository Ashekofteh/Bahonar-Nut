"""The ledger's ordering semantics: are rows newest-first, and does a
(booking, withdrawal, booking) sequence net out to one booking?

This decides the dashboard's metric. A naive sum of booking amounts would
double-count 1405/07/30 lunch, which has TWO booking rows and one withdrawal.
"""
import re

html = open('captures/85_ledger_after.html', encoding='utf-8').read()

ids = re.findall(r'id="(cphMain_grdContent_grdDetail_\d+)"', html)


def rows_of(did):
    t = re.search(r'<table[^>]*id="' + did + r'"[^>]*>(.*?)</table>', html, re.DOTALL)
    if not t:
        return []
    out = []
    for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', t.group(1), re.DOTALL):
        cells = [re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', c)).strip()
                 for c in re.findall(r'<td[^>]*>(.*?)</td>', row.group(1), re.DOTALL)]
        if cells and cells[0]:
            out.append(cells)
    return out


print('=== rows per detail grid, in document order ===')
for did in ids:
    rs = rows_of(did)
    for r in rs:
        print('  %-34s %s' % (did.replace('cphMain_grdContent_grdDetail_', 'detail_'), ' | '.join(r)))

print()
print('=== grouped by (date, slot), in document order ===')
groups = {}
for did in ids:
    for r in rows_of(did):
        key = (r[4], r[2])          # date, meal
        groups.setdefault(key, []).append(r[0])

for key in sorted(groups):
    seq = groups[key]
    print('  %s / %s -> %s' % (key[0], key[1], seq))

all_rows = [r for did in ids for r in rows_of(did)]

print()
print('=== the net, if the LAST event per (date, slot) wins ===')
for key in sorted(groups):
    seq = groups[key]
    last = seq[-1]
    amount = 0
    for r in all_rows:
        if r[4] == key[0] and r[2] == key[1]:
            amount = int(re.sub(r'\D', '', r[6]))
    state = 'HELD' if 'انصراف' not in last else 'RELEASED'
    print('  %s / %s : %-10s  amount=%d' % (key[0], key[1], state, amount))
