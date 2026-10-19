import re

for path in ['recon/reservation.html', 'recon/reservation_nextweek.html',
             'captures/05_reservation_page.html']:
    html = open(path, encoding='utf-8').read()
    m = re.search(r'<table[^>]*id="[^"]*grdReservationLunch"[^>]*>(.*?)</table>',
                  html, re.DOTALL)
    print('=' * 12, path)
    if not m:
        print('  grid missing')
        continue
    for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', m.group(1), re.DOTALL):
        r = row.group(1)
        cells = re.findall(r'<td[^>]*>(.*?)</td>', r, re.DOTALL)
        if len(cells) < 4:
            continue
        label = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[1])).strip()
        cb = re.search(r'<input[^>]*type="checkbox"[^>]*>', r)
        tag = cb.group(0) if cb else ''
        date = re.search(r'\d{4}/\d{2}/\d{2}', label)
        print('   %s disabled=%-5s checked=%s'
              % (date.group(0) if date else label,
                 'disabled' in tag, 'checked' in tag))
