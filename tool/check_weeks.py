import re

for path in ['captures/50_next_week.html',
             'captures/52_book_response.html',
             'captures/52b_after_book_next_week.html']:
    try:
        html = open(path, encoding='utf-8').read()
    except OSError:
        print(path, 'absent')
        continue
    m = re.search(r'id="cphMain_lblWeekDate"[^>]*>(.*?)<', html, re.DOTALL)
    lab = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', m.group(1))).strip() if m else '?'
    c = re.search(r'<label[^>]*id="lblCredit"[^>]*>(.*?)</label>', html, re.DOTALL)
    cr = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', c.group(1))).strip() if c else '?'

    chk = []
    for g in ['grdReservationBreakfast', 'grdReservationLunch', 'grdReservationDinner']:
        t = re.search(r'<table[^>]*id="[^"]*' + g + r'"[^>]*>(.*?)</table>',
                      html, re.DOTALL)
        if not t:
            continue
        for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', t.group(1), re.DOTALL):
            raw = row.group(1)
            cb = re.search(r'<input[^>]*type="checkbox"[^>]*>', raw)
            if not cb or 'checked' not in cb.group(0):
                continue
            cells = re.findall(r'<td[^>]*>(.*?)</td>', raw, re.DOTALL)
            if len(cells) < 4:
                continue
            lab2 = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[1])).strip()
            d = re.search(r'\d{4}/\d{2}/\d{2}', lab2)
            chk.append(g.replace('grdReservation', '') + ':' +
                       (d.group(0) if d else '?'))

    print('%-40s' % path.split('/')[-1])
    print('   week   = %s' % lab)
    print('   credit = %s' % cr)
    print('   checked= %s' % chk)
