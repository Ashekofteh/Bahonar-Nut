import re

for path in ['recon/reservation.html', 'recon/reservation_nextweek.html',
             'recon/authed.html', 'recon/authed2.html',
             'captures/05_reservation_page.html', 'captures/23_week0.html',
             'captures/23_week1.html']:
    try:
        html = open(path, encoding='utf-8').read()
    except OSError:
        continue
    label = re.search(r'id="cphMain_lblWeekDate"[^>]*>(.*?)<', html, re.DOTALL)
    text = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', label.group(1))).strip() if label else '?'
    print('%-38s week = %s' % (path, text))
