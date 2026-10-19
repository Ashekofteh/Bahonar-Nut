"""Verify the basket purchase, with the basket grid's actual shape.

The basket grid has NO date column: it is one row per MEAL for the filtered
date (date comes from the page's date field). An earlier analysis assumed a
date column and silently printed nothing, so this one reads the rows directly.

Also checks the LEDGER's structure, which turned out to matter: the main
`grdContent` grid shows only the MOST RECENT transaction, and the full history
lives in the `grdDetail_N` sub-grids.
"""
import re

print('=== BUY grid rows (no date column; the page is date-filtered) ===')
for path in ['captures/81_buy_page_1405_07_28.html',
             'captures/86_buy_page_after.html']:
    html = open(path, encoding='utf-8').read()
    date = re.search(r'id="cphMain_txtDate"[^>]*value="([^"]*)"', html)
    t = re.search(r'<table[^>]*id="[^"]*grdFoodBasketReservation"[^>]*>(.*?)</table>',
                   html, re.DOTALL)
    print('\n  %s   (page date=%s)' % (path.split('/')[-1],
                                       date.group(1) if date else '?'))
    if not t:
        print('    grid missing')
        continue
    for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', t.group(1), re.DOTALL):
        raw = row.group(1)
        cells = re.findall(r'<td[^>]*>(.*?)</td>', raw, re.DOTALL)
        if len(cells) < 8:
            continue
        meal = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[1])).strip()
        amt = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[6])).strip()
        status = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[7])).strip()
        cb = re.search(r'<input[^>]*type="checkbox"[^>]*>', raw)
        tag = cb.group(0) if cb else ''
        opts = re.findall(r'<option[^>]*value="([^"]*)"[^>]*>(.*?)</option>',
                          re.search(r'drpFood"[^>]*>(.*?)</select>', raw, re.DOTALL).group(1)
                          if re.search(r'drpFood"[^>]*>(.*?)</select>', raw, re.DOTALL) else '',
                          re.DOTALL)
        print('    %-8s checked=%-5s disabled=%-5s amount=%-8s status=%r' % (
            meal, 'checked' in tag, 'disabled' in tag, amt, status))
        for v, txt in opts:
            txt = re.sub(r'\s+', ' ', txt).strip()
            print('        option %s: %s' % (v, txt[:60]))

print()
print('=== LEDGER structure ===')
for path in ['captures/80_ledger_before.html', 'captures/85_ledger_after.html']:
    html = open(path, encoding='utf-8').read()
    t = re.search(r'<table[^>]*id="[^"]*grdContent"[^>]*>(.*?)</table>',
                  html, re.DOTALL)
    main = []
    for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', t.group(1) if t else '', re.DOTALL):
        cells = [re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', c)).strip()
                 for c in re.findall(r'<td[^>]*>(.*?)</td>', row.group(1), re.DOTALL)]
        if cells and cells[0]:
            main.append(' | '.join(cells))
    print('\n  %s' % path.split('/')[-1])
    print('    main grid rows: %d' % len(main))
    for r in main:
        print('      %s' % r)

    detail_ids = re.findall(r'id="(cphMain_grdContent_grdDetail_\d+)"', html)
    print('    detail sub-grids: %d' % len(detail_ids))
    total = 0
    for did in detail_ids:
        dt = re.search(r'<table[^>]*id="' + re.escape(did) + r'"[^>]*>(.*?)</table>',
                       html, re.DOTALL)
        if not dt:
            continue
        for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', dt.group(1), re.DOTALL):
            cells = [re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', c)).strip()
                     for c in re.findall(r'<td[^>]*>(.*?)</td>', row.group(1), re.DOTALL)]
            if cells and cells[0]:
                total += 1
                if 'اکبرجوجه' in ' '.join(cells):
                    print('      TARGET in %s: %s' % (did, ' | '.join(cells)))
    print('    total rows across detail sub-grids: %d' % total)
