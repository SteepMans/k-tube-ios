"""Renders the app icon (1024x1024, no transparency): the K-Tube mark from the desktop logo.svg,
a lavender gradient #bcaaf7 -> #8470de with a white rounded play sign."""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096
a, b = (0xbc, 0xaa, 0xf7), (0x84, 0x70, 0xde)
grad = Image.new("RGB", (S, S))
px = grad.load()
for y in range(S):
    for x in range(0, S):
        t = (x + y) / (2 * (S - 1))
        px[x, y] = tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))
img = grad
# soft highlight at the top left, like the circle's light side
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).ellipse((-S * 0.3, -S * 0.3, S * 0.7, S * 0.7), fill=60)
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.12))
img = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), img, glow)
# the play sign from logo.svg: M38.5 30.5 L38.5 69.5 L74 50 Z with a round 9px stroke, scaled to the square
k = S / 100
z = 0.82  # a little smaller than in the circle: the square icon has no rim
tri = [((50 + (x - 52) * z) * k, (50 + (y - 50) * z) * k) for x, y in [(38.5, 30.5), (38.5, 69.5), (74, 50)]]
shadow = Image.new("L", (S, S), 0)
d = ImageDraw.Draw(shadow)
off = S * 0.012
d.polygon([(x, y + off) for x, y in tri], fill=70)
d.line([(x, y + off) for x, y in tri + tri[:1]], fill=70, width=int(9 * z * k), joint="curve")
shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.015))
img = Image.composite(Image.new("RGB", (S, S), (0x4b, 0x3c, 0x9a)), img, shadow)
d = ImageDraw.Draw(img)
d.polygon(tri, fill="white")
d.line(tri + tri[:1], fill="white", width=int(9 * z * k), joint="curve")
r = 4.5 * z * k
for x, y in tri:
    d.ellipse((x - r, y - r, x + r, y + r), fill="white")
img.resize((1024, 1024), Image.LANCZOS).save(sys.argv[1] if len(sys.argv) > 1 else "icon-1024.png")
