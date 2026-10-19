"""Exactly which checkboxes were posted 'on', and what the response says about
the resulting rows' status and price."""
import re

body = open('captures/51_book_body.txt', encoding='utf-8').read()
print('=== POSTED checkboxes that are "on" ===')
for line in body.split('\n'):
    if 'chkReserve' in line and line.rstrip().endswith('=on'):
        print('  %s' % line.strip())

print()
print('=== POSTED: btnSave / EVENTTARGET ===')
for line in body.split('\n'):
    if 'btnSave' in line or 'EVENTTARGET' in line or 'EVENTARGUMENT' in line:
        print('  %s' % line.strip()[:120])

print()
print('=== RESPONSE: the 1405/08/03 row in each grid ===')
html = open('captures/52_book_response.html', encoding='utf-8').read()
for g in ['grdReservationBreakfast', 'grdReservationLunch', 'grdReservationDinner']:
    t = re.search(r'<table[^>]*id="[^"]*' + g + r'"[^>]*>(.*?)</table>', html, re.DOTALL)
    if not t:
        continue
    for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', t.group(1), re.DOTALL):
        raw = row.group(1)
        cells = re.findall(r'<td[^>]*>(.*?)</td>', raw, re.DOTALL)
        if len(cells) < 7:
            continue
        lab = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[1])).strip()
        if '1405/08/03' not in lab:
            continue
        cb = re.search(r'<input[^>]*type="checkbox"[^>]*>', raw)
        cbt = cb.group(0) if cb else ''
        amount = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[6])).strip()
        food = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[3])).strip()
        status = 'RESERVED-ICON' if 'imgStaus' in raw else '-'
        disabled = 'disabled' in cbt
        print('  %-24s checked=%-5s disabled=%-5s amount=%-8s %s' %
              (g.replace('grdReservation', ''), 'checked' in cbt, disabled,
               amount, status))
        print('       food = %s' % food[:80])
        if 'imgStaus' in raw:
            m = re.search(r'title="([^"]*)"', raw)
            print('       status title = %s' % (m.group(1) if m else '?'))

print()
print('=== credit label ===')
c = re.search(r'<label[^>]*id="lblCredit"[^>]*>(.*?)</label>', html, re.DOTALL)
print('  %s' % re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', c.group(1))).strip() if c else '?')
a = re.search(r'id="cphMain_alertBoxValue"[^>]*>(.*?)</', html, re.DOTALL)
print('  alertBox = %r' % (re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', a.group(1))).strip() if a else None))
