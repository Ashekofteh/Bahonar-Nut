import re

# Compare the REQUEST page and the RESPONSE page: does the lunch row for
# 1405/07/28 exist in the response, and is it checked?
for path, tag in [('captures/05_reservation_page.html', 'REQUEST'),
                  ('captures/11_reserve_response_hall1.html', 'RESPONSE')]:
    html = open(path, encoding='utf-8').read()
    print('=' * 20, tag, path)

    for grid in ['grdReservationBreakfast', 'grdReservationLunch',
                 'grdReservationDinner']:
        m = re.search(r'<table[^>]*id="[^"]*' + grid + r'"[^>]*>(.*?)</table>',
                      html, re.DOTALL)
        if not m:
            print('  %s: GRID MISSING' % grid)
            continue
        found = False
        for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', m.group(1), re.DOTALL):
            r = row.group(1)
            if '1405/07/28' not in r:
                continue
            found = True
            cells = re.findall(r'<td[^>]*>(.*?)</td>', r, re.DOTALL)
            cb = re.search(r'<input[^>]*type="checkbox"[^>]*>', r)
            cbtag = cb.group(0) if cb else ''
            checked = 'checked' in cbtag
            disabled = 'disabled' in cbtag
            food = re.findall(
                r'<option(?:[^>]*value="([^"]*)")?[^>]*>(.*?)</option>',
                re.search(r'drpFood"[^>]*>(.*?)</select>', r, re.DOTALL).group(1)
                if re.search(r'drpFood"[^>]*>(.*?)</select>', r, re.DOTALL) else '',
                re.DOTALL)
            names = [re.sub(r'\s+', ' ', f[1]).strip()[:40] for f in food]
            print('  %-26s row FOUND  checked=%-5s disabled=%-5s' %
                  (grid, checked, disabled))
            print('       ctl-index: %s' % (
                re.search(r'chkReserve_(\d+)', cbtag).group(1)
                if re.search(r'chkReserve_(\d+)', cbtag) else '?'))
            print('       foods: %s' % names)
        if not found:
            print('  %-26s row 1405/07/28 ABSENT' % grid)

    # alert box
    for m in re.finditer(r'id="cphMain_alertBoxValue"[^>]*>(.*?)</', html, re.DOTALL):
        print('  alertBox: %r' % re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', m.group(1))).strip()[:200])
    for m in re.finditer(r'alertBoxValue[^>]*>(.*?)</', html, re.DOTALL):
        t = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', m.group(1))).strip()
        if t:
            print('  alertBox(2): %r' % t[:200])
