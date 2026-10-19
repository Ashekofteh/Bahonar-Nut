"""Verify the POST addressed the intended row: the lunch row for 1405/07/28.

The `id` attribute and the `name` attribute of a grid control carry DIFFERENT
indices (`chkReserve_3` vs `grdReservationLunch$ctl05$chkReserve`), so an
earlier analysis reading the id could mislead. This checks the NAME, which is
what the POST actually sends.
"""
import re

html = open('captures/05_reservation_page.html', encoding='utf-8').read()

grid = re.search(
    r'<table[^>]*id="[^"]*grdReservationLunch"[^>]*>(.*?)</table>', html, re.DOTALL)
print('lunch grid found:', bool(grid))

posted_name = 'ctl00$cphMain$grdReservationLunch$ctl05$chkReserve'

for row in re.finditer(r'<tr[^>]*>(.*?)</tr>', grid.group(1), re.DOTALL):
    r = row.group(1)
    cells = re.findall(r'<td[^>]*>(.*?)</td>', r, re.DOTALL)
    if len(cells) < 4:
        continue
    label = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', cells[1])).strip()
    cb = re.search(r'<input[^>]*type="checkbox"[^>]*>', r)
    if not cb:
        continue
    tag = cb.group(0)
    name = re.search(r'name="([^"]+)"', tag)
    ident = re.search(r'id="([^"]+)"', tag)
    disabled = 'disabled' in tag
    food = re.findall(
        r'<option(?:[^>]*value="([^"]*)")?[^>]*>(.*?)</option>',
        re.search(r'drpFood"[^>]*>(.*?)</select>', r, re.DOTALL).group(1)
        if re.search(r'drpFood"[^>]*>(.*?)</select>', r, re.DOTALL) else '',
        re.DOTALL)
    names = [re.sub(r'\s+', ' ', f[1]).strip()[:38] for f in food]
    mark = '   <== THE POSTED ROW' if name and name.group(1) == posted_name else ''
    print('%-22s name=%-58s id=%-46s disabled=%s%s'
          % (label,
             name.group(1) if name else '?',
             ident.group(1) if ident else '?',
             disabled,
             mark))
    if names:
        print('      foods: %s' % names)

print()
print('posted checkbox name: %s' % posted_name)
print('that name appears in the page: %s'
      % (posted_name in html))
