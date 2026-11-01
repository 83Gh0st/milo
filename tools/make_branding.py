"""Draws Milo's app icon, adaptive-icon foreground and splash image (no external assets). Run: python tools/make_branding.py

STALE: draws the pre-rebrand lavender identity. The shipped brand (teal
mascot, docs/BRAND.md) comes from assets/branding/ masters + the
flutter_launcher_icons / flutter_native_splash generators. Kept for history;
do not run unless you intend to replace the current brand."""
from PIL import Image, ImageDraw, ImageFilter
import math, os
S = 2048
BODY, BODY_L, BODY_D, INK, LEAF, STEM = (142, 155, 255), (178, 188, 255), (110, 124, 240), (31, 35, 64), (47, 181, 132), (52, 195, 143)

def ell(d, cx, cy, rx, ry, fill): d.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=fill)
def rot_ell(img, cx, cy, rx, ry, ang, fill):
    l = Image.new('RGBA', (rx * 2 + 4, ry * 2 + 4), (0, 0, 0, 0)); ImageDraw.Draw(l).ellipse((2, 2, rx * 2 + 2, ry * 2 + 2), fill=fill)
    l = l.rotate(ang, expand=True, resample=Image.BICUBIC); img.alpha_composite(l, (int(cx - l.width / 2), int(cy - l.height / 2)))

def milo(scale=1.0, bg=None):
    img = Image.new('RGBA', (S, S), bg or (0, 0, 0, 0))
    m = Image.new('RGBA', (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(m)
    cx, cy = S // 2, int(S * .56)
    ell(d, cx, cy + 560, 470, 90, (0, 0, 0, 40))                                  # shadow
    ell(d, cx - 250, cy + 480, 190, 95, BODY_D); ell(d, cx + 250, cy + 480, 190, 95, BODY_D)  # feet
    ell(d, cx - 520, cy + 140, 120, 120, BODY_D); ell(d, cx + 520, cy + 140, 120, 120, BODY_D) # side nubs
    ell(d, cx, cy, 560, 520, BODY)                                                # body
    ell(d, cx, cy + 90, 380, 300, BODY_L + (110,))                                # lighter belly
    ell(d, cx - 230, cy - 250, 200, 105, (255, 255, 255, 120))                    # glossy highlight
    for sx in (-1, 1):
        ell(d, cx + sx * 190, cy - 20, 62, 92, INK); ell(d, cx + sx * 170, cy - 62, 22, 22, (255, 255, 255, 255))  # eyes
        ell(d, cx + sx * 330, cy + 120, 70, 42, (255, 140, 170, 170))             # blush
    d.arc((cx - 120, cy + 70, cx + 120, cy + 230), 20, 160, fill=INK, width=26)   # smile
    d.line((cx, cy - 500, cx, cy - 760), fill=STEM, width=44)                      # sprout stem
    m = m.filter(ImageFilter.GaussianBlur(1))
    rot_ell(m, cx - 130, cy - 790, 150, 62, 28, LEAF + (255,)); rot_ell(m, cx + 130, cy - 830, 150, 62, -28, LEAF + (255,))
    if scale != 1.0:
        m = m.resize((int(S * scale), int(S * scale)), Image.LANCZOS)
        full = Image.new('RGBA', (S, S), (0, 0, 0, 0)); full.alpha_composite(m, ((S - m.width) // 2, (S - m.height) // 2)); m = full
    img.alpha_composite(m); return img

def gradient():
    g = Image.new('RGBA', (S, S)); px = g.load()
    for y in range(S):
        t = y / S; c = (int(221 + 23 * t), int(226 + 19 * t), int(255 - 0 * t), 255)
        for x in range(S): px[x, y] = c
    return g

os.makedirs('assets/branding', exist_ok=True)
bg = gradient()
icon = milo(.78, None); full = bg.copy(); full.alpha_composite(icon)
full.convert('RGB').resize((1024, 1024), Image.LANCZOS).save('assets/branding/icon.png')                  # iOS / legacy Android icon (no alpha)
milo(.62).resize((1024, 1024), Image.LANCZOS).save('assets/branding/icon_fg.png')                         # adaptive foreground (safe zone)
milo(.62).resize((1152, 1152), Image.LANCZOS).save('assets/branding/splash.png')                          # native splash, on #E9EDFF
print('branding written')
