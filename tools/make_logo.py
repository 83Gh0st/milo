"""Milo logo + 2A look-dev reference mockups (PIL). The shipped character is the
code-drawn v2 renderer; these PNGs are reference boards for the human's pick,
approximating looks A/B/C in five expressions. Run: python tools/make_logo.py [--concept A|B|C]"""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageOps

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024
BODY, INK, LEAF, STEM, IRIS = (142, 155, 255), (31, 35, 64), (47, 181, 132), (52, 195, 143), (61, 75, 196)
BLUSH = (255, 122, 122)

# look params: body rx/ry, eye scale, sprout length, legs?, cheek scale
LOOKS = {'A': (300, 280, 1.0, 1.0, False, 1.0), 'B': (340, 250, 1.1, .55, False, 1.2), 'C': (260, 310, .95, 1.1, True, .9)}
EXPRS = ['neutral', 'happy', 'curious', 'concerned', 'sleepy']

def ell(d, cx, cy, rx, ry, fill):
    d.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=fill)

def rot_ell(img, cx, cy, rx, ry, ang, fill):
    l = Image.new('RGBA', (rx * 2 + 8, ry * 2 + 8), (0, 0, 0, 0))
    ImageDraw.Draw(l).ellipse((4, 4, rx * 2 + 4, ry * 2 + 4), fill=fill)
    l = l.rotate(ang, expand=True, resample=Image.BICUBIC)
    img.alpha_composite(l, (int(cx - l.width / 2), int(cy - l.height / 2)))

def milo(look='A', expr='neutral', bg=None, px=S):
    """Head-forward Milo with sprout, <=3 body tones + highlight, no text."""
    brx, bry, es, sl, legs, ch = LOOKS[look]
    img = Image.new('RGBA', (S, S), bg or (0, 0, 0, 0))
    m = Image.new('RGBA', (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(m)
    cx, cy = S // 2, 560
    ell(d, cx, cy + bry + 40, brx - 60, 60, (0, 0, 0, 40))
    if legs:
        for sx in (-1, 1):
            d.rounded_rectangle((cx + sx * 110 - 45, cy + bry - 60, cx + sx * 110 + 45, cy + bry + 90), 40, fill=BODY)
            ell(d, cx + sx * 110, cy + bry + 90, 85, 50, BODY)
    else:
        for sx in (-1, 1):
            ell(d, cx + sx * 150, cy + bry - 30, 110, 62, BODY)
    ell(d, cx, cy, brx, bry, BODY)
    ey = cy - 60
    # Translucent shapes go on their own layer: ImageDraw *replaces* pixels,
    # so drawing them on m would punch translucent holes to the background.
    soft = Image.new('RGBA', (S, S), (0, 0, 0, 0)); ds = ImageDraw.Draw(soft)
    ell(ds, cx, cy + 40, int(brx * .72), int(bry * .62), (178, 188, 255, 110))
    ell(ds, cx - 120, cy - bry // 2, 130, 62, (255, 255, 255, 120))
    ell(ds, cx, cy - 40, 250, 220, (255, 255, 255, 55))  # face patch
    for sx in (-1, 1):
        ell(ds, cx + sx * 220, ey + 130, 55 * ch, 32 * ch, BLUSH + (150,))
    m.alpha_composite(soft)
    eye_open = {'neutral': 1, 'happy': .25, 'curious': 1, 'concerned': .85, 'sleepy': .35}[expr]
    for sx in (-1, 1):
        ex = cx + sx * 110
        if expr == 'happy':
            d.arc((ex - 55, ey - 30, ex + 55, ey + 50), 195, 345, fill=INK, width=20)
        else:
            rx, ry = 62 * es, 80 * es * eye_open + 8
            ell(d, ex, ey, rx, ry, (255, 255, 255, 255))
            ell(d, ex, ey + 4, 34 * es, 36 * es * eye_open + 6, IRIS)
            ell(d, ex, ey + 4, 18 * es, 19 * es * eye_open + 4, INK)
            ell(d, ex - 14, ey - 16, 12, 12, (255, 255, 255, 255))
            lid_h = 2 * ry * (1 - eye_open)
            if lid_h > 2:  # curved lid, not a flat bar (flat reads stern)
                ell(d, ex, ey - ry + lid_h * .45, rx * .98, lid_h * .55 + 8, BODY)
    # brows: tapered arcs; inner = toward centre. concerned raises inner.
    brow = {'neutral': (0, 0), 'happy': (-14, -6), 'curious': (-18, 6), 'concerned': (-2, -46), 'sleepy': (10, 6)}[expr]
    for sx in (-1, 1):
        ex = cx + sx * 110
        outer = ey - 130 + brow[0] + (0 if sx > 0 else brow[1] if expr == 'curious' else 0)
        inner = ey - 130 + brow[1] + (-36 if expr == 'curious' and sx > 0 else 0)
        x0, x1 = (ex + 55, ex - 55) if sx > 0 else (ex - 55, ex + 55)
        d.line((x0, outer, (x0 + x1) / 2, (outer + inner) / 2 - 12, x1, inner), fill=INK, width=18, joint='curve')
    # mouth
    my = ey + 170
    if expr == 'happy':
        d.pieslice((cx - 90, my - 60, cx + 90, my + 60), 10, 170, fill=(59, 30, 63, 255))
        ell(d, cx, my + 30, 55, 22, (255, 143, 163, 255))
    elif expr == 'concerned':
        d.arc((cx - 70, my - 30, cx + 70, my + 50), 195, 345, fill=INK, width=18)
    elif expr == 'sleepy':
        d.line((cx - 45, my, cx + 45, my), fill=INK, width=16)
    else:
        d.arc((cx - 80, my - 70, cx + 80, my + 50), 25, 155, fill=INK, width=20)
    # sprout: stem + two leaf pairs
    top = cy - bry - 10
    d.line((cx, top, cx, top - 220 * sl), fill=STEM, width=40)
    m = m.filter(ImageFilter.GaussianBlur(1)); d = ImageDraw.Draw(m)
    for i, yy in enumerate((top - 110 * sl, top - 190 * sl)):
        rot_ell(m, cx - 110, yy, 120, 48, 28, LEAF + (255,))
        rot_ell(m, cx + 110, yy - 30, 120, 48, -28, LEAF + (255,))
    img.alpha_composite(m)
    return img.resize((px, px), Image.LANCZOS) if px != S else img

def contact_sheet():
    """1024/192/96/48 px on light, dark, coloured + squint + greyscale rows."""
    bgs = {'light': (233, 237, 255, 255), 'dark': (20, 23, 51, 255), 'color': (91, 108, 255, 255)}
    sizes = [256, 192, 96, 48]
    rows = []
    for look in 'ABC':
        row = []
        for name, bg in bgs.items():
            strip = Image.new('RGBA', (sum(sizes) + 60, 300), (255, 255, 255, 255))
            x = 10
            for sz in sizes:
                im = milo(look, 'neutral', bg, px=sz)
                strip.alpha_composite(im, (x, 300 - sz - 10)); x += sz + 10
            row.append(strip)
        base = milo(look, 'neutral', bgs['light'], px=256)
        squint = base.resize((32, 32), Image.BILINEAR).resize((256, 256), Image.BILINEAR)
        grey = ImageOps.grayscale(base).convert('RGBA')
        tests = Image.new('RGBA', (256 * 2 + 30, 300), (255, 255, 255, 255))
        tests.alpha_composite(squint, (10, 20)); tests.alpha_composite(grey, (276, 20))
        row.append(tests)
        rows.append(row)
    W = sum(im.width for im in rows[0]) + 50
    sheet = Image.new('RGBA', (W, 300 * 3 + 40), (255, 255, 255, 255)); dd = ImageDraw.Draw(sheet)
    y = 10
    for i, row in enumerate(rows):
        x = 10; dd.text((x, y), 'Concept ' + 'ABC'[i], fill=(0, 0, 0, 255))
        x = 90
        for im in row:
            sheet.alpha_composite(im, (x, y)); x += im.width + 10
        y += 310
    return sheet

def lookdev():
    """3 looks x 5 expressions x 4 sizes (56/96/160/320 dp at 3x)."""
    out = os.path.join(ROOT, 'docs', 'upgrade', 'phase2'); os.makedirs(out, exist_ok=True)
    for look in 'ABC':
        for expr in EXPRS:
            for dp in (56, 96, 160, 320):
                milo(look, expr, (233, 237, 255, 255), px=dp * 3).convert('RGB').save(
                    os.path.join(out, 'lookdev_%s_%s_%d.png' % (look, expr, dp)))
    contact_sheet().convert('RGB').save(os.path.join(out, 'contact_sheet.png'))
    print('lookdev written: 60 + contact sheet')

SVG_MARK = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
<!-- Milo mark master (concept %(look)s lineage). Body <=3 tones + highlight. -->
<ellipse cx="256" cy="290" rx="%(brx)d" ry="%(bry)d" fill="#8E9BFF"/>
<ellipse cx="256" cy="310" rx="%(belly)d" ry="%(bellyry)d" fill="#B2BCFF" opacity="0.45"/>
<ellipse cx="206" cy="220" rx="65" ry="31" fill="#FFFFFF" opacity="0.47"/>
<ellipse cx="256" cy="270" rx="125" ry="110" fill="#FFFFFF" opacity="0.22"/>
<ellipse cx="201" cy="260" rx="31" ry="40" fill="#FFFFFF"/>
<ellipse cx="311" cy="260" rx="31" ry="40" fill="#FFFFFF"/>
<circle cx="201" cy="262" r="17" fill="#3D4BC4"/><circle cx="311" cy="262" r="17" fill="#3D4BC4"/>
<circle cx="201" cy="262" r="9" fill="#1F2340"/><circle cx="311" cy="262" r="9" fill="#1F2340"/>
<circle cx="194" cy="254" r="6" fill="#FFFFFF"/><circle cx="304" cy="254" r="6" fill="#FFFFFF"/>
<ellipse cx="146" cy="325" rx="27" ry="16" fill="#FF7A7A" opacity="0.6"/>
<ellipse cx="366" cy="325" rx="27" ry="16" fill="#FF7A7A" opacity="0.6"/>
<path d="M216 345 Q256 385 296 345" stroke="#1F2340" stroke-width="10" fill="none" stroke-linecap="round"/>
<path d="M256 %(top)d L256 %(tip)d" stroke="#34C38F" stroke-width="20" stroke-linecap="round"/>
<ellipse cx="196" cy="%(leaf1)d" rx="60" ry="24" fill="#2FB584" transform="rotate(28 196 %(leaf1)d)"/>
<ellipse cx="316" cy="%(leaf2)d" rx="60" ry="24" fill="#2FB584" transform="rotate(-28 316 %(leaf2)d)"/>
</svg>
'''
SVG_WORD = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 120">
<!-- Milo wordmark master. Set in Lexend SemiBold; convert to outlines before print. -->
<text x="200" y="82" text-anchor="middle" font-family="Lexend, sans-serif" font-weight="600" font-size="72" fill="#1F2340">milo</text>
<circle cx="352" cy="34" r="10" fill="#34C38F"/>
</svg>
'''

def finals(look):
    b = os.path.join(ROOT, 'assets', 'branding'); src = os.path.join(b, 'src'); os.makedirs(src, exist_ok=True)
    brx, bry = {'A': (150, 140), 'B': (170, 125), 'C': (130, 155)}[look]
    top = 290 - bry - 5
    open(os.path.join(src, 'milo_mark.svg'), 'w').write(SVG_MARK % {'look': look, 'brx': brx, 'bry': bry,
        'belly': int(brx * .72), 'bellyry': int(bry * .62), 'top': top, 'tip': top - 110,
        'leaf1': top - 55, 'leaf2': top - 85})
    open(os.path.join(src, 'milo_wordmark.svg'), 'w').write(SVG_WORD)
    bg = Image.new('RGBA', (S, S))
    for y in range(S):
        t = y / S
        ImageDraw.Draw(bg).line((0, y, S, y), fill=(int(221 + 23 * t), int(226 + 19 * t), 255, 255))
    full = bg.copy(); full.alpha_composite(milo(look, 'neutral', None))
    full.convert('RGB').resize((1024, 1024), Image.LANCZOS).save(os.path.join(b, 'icon.png'))
    fg = milo(look, 'neutral', None); fg.thumbnail((700, 700), Image.LANCZOS)
    canvas = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    canvas.alpha_composite(fg, ((1024 - fg.width) // 2, (1024 - fg.height) // 2))
    canvas.save(os.path.join(b, 'icon_fg.png'))
    mono = fg.convert('L').point(lambda v: 255 if v > 10 else 0).convert('RGBA')
    mono.putalpha(fg.split()[3])  # silhouette alpha from the mark
    white = Image.new('RGBA', (1024, 1024), (255, 255, 255, 0))
    white.paste(Image.new('RGBA', mono.size, (255, 255, 255, 255)), (0, 0), mono.split()[3])
    white.save(os.path.join(b, 'icon_mono.png'))
    noti = white.resize((96, 96), Image.LANCZOS); noti.save(os.path.join(b, 'icon_noti.png'))
    splash = Image.new('RGBA', (1152, 1152), (233, 237, 255, 255))
    sp = milo(look, 'neutral', None, px=640)
    splash.alpha_composite(sp, ((1152 - 640) // 2, (1152 - 640) // 2))
    splash.convert('RGB').save(os.path.join(b, 'splash.png'))
    print('branding finals written (concept %s)' % look)

if __name__ == '__main__':
    look = 'A'
    for i, a in enumerate(sys.argv):
        if a == '--concept' and i + 1 < len(sys.argv) and sys.argv[i + 1] in 'ABC':
            look = sys.argv[i + 1]
    lookdev()
    finals(look)
