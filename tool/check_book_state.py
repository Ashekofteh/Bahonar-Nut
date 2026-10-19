"""Which week does the response show, and was the booking actually taken?

The book POST's response was the same size as the current-week page, so the
verification may have looked in the wrong week and reported a false failure.
"""
import re


def week_label(html):
    m = re.search(r'id="cphMain_lblWeekDate"[^>]*>(.*?)<', html, re.DOTALL)
    if not m:
        return '?'
    return re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', m.group(1))).strip()


def checked_rows(html, grid):
    t = re.search(r'<table[^>]*id="[^"]*' + grid + r'"[^>]*>(.*?)</table>',
                  html, re.DOTALL)
    if not t:
        return {}
    out = {}
    for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', t.group(1), re.DOTALL):
        raw = row.group(1)
        cb = re.search(r'<input[^>]*type="checkbox"[^>]*>', raw)
        tag = cb.group(0) if cb else ''
        if 'checked' not in tag:
            continue
        cells = re.findall(r'<td[^>]*>(.*?)</td>', raw, re.DOTALL)
        if len(cells) < 4:
            continue
        lab = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[1])).strip()
        d = re.search(r'\d{4}/\d{2}/\d{2}', lab)
        if d:
            out[d.group(0)] = True
    return out


def credit(html):
    m = re.search(r'<label[^>]*id="lblCredit"[^>]*>(.*?)</label>', html, re.DOTALL)
    if not m:
        return '?'
    return re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', m.group(1))).strip()


for path in ['captures/50_next_week.html',
             'captures/52_book_response.html',
             'captures/30_reservation_current.html']:
    try:
        html = open(path, encoding='utf-8').read()
    except OSError:
        print('%s  (absent)' % path)
        continue
    print('=' * 12, path)
    print('  week  = %s' % week_label(html))
    print('  credit= %s' % credit(html))
    for grid in ['grdReservationBreakfast', 'grdReservationLunch',
                 'grdReservationDinner']:
        rows = checked_rows(html, grid)
        if rows:
            print('  %-26s checked: %s' % (grid, sorted(rows)))
