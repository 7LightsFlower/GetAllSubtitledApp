import os, zlib, struct
from datetime import datetime
stamp = datetime.now().strftime("%Y-%m-%d_%H-%M")
# → app_icon_2026-09-17_14-32.png

try:
    import numpy as np
except ImportError:
    print("Run: py -m pip install numpy")
    raise SystemExit(1)

W = H = 1024
SS = 2  # supersample for smooth edges

# ---- Rainbow gradient (Apple palette, diagonal) ----
RAINBOW_T = np.array([0.00, 0.15, 0.30, 0.45, 0.60, 0.75, 0.90, 1.00], dtype=np.float32)
RAINBOW_R = np.array([255, 255, 255,  52,   0,  88, 175, 255], dtype=np.float32)
RAINBOW_G = np.array([ 59, 149, 204, 199, 122,  86,  82,  45], dtype=np.float32)
RAINBOW_B = np.array([ 48,   0,   0,  89, 255, 214, 222,  85], dtype=np.float32)

def rainbow(t):
    t = np.clip(t, 0.0, 1.0)
    return (np.interp(t, RAINBOW_T, RAINBOW_R),
            np.interp(t, RAINBOW_T, RAINBOW_G),
            np.interp(t, RAINBOW_T, RAINBOW_B))

WHITE  = (255, 255, 255)
ACCENT = (79, 70, 229)   # #4F46E5 — arrow color

# Subtitle line colors (one per language)
LINE_COLORS = [
    (255, 149,   0),   # orange
    (  0, 122, 255),   # blue
    ( 52, 199,  89),   # green
]

def rrect(x, y, rx, ry, rw, rh, rr):
    inside = (x >= rx) & (x <= rx+rw) & (y >= ry) & (y <= ry+rh)
    cx = np.clip(x, rx+rr, rx+rw-rr)
    cy = np.clip(y, ry+rr, ry+rh-rr)
    return inside & ((x-cx)**2 + (y-cy)**2 <= rr*rr)

def circle(x, y, cx0, cy0, r):
    return (x-cx0)**2 + (y-cy0)**2 <= r*r

def seg(x, y, x1, y1, x2, y2, hw):
    dx = x2 - x1; dy = y2 - y1
    L2v = dx*dx + dy*dy
    if L2v == 0:
        return (x-x1)**2 + (y-y1)**2 <= hw*hw
    t = np.clip(((x-x1)*dx + (y-y1)*dy) / L2v, 0, 1)
    nx = x1 + t*dx; ny = y1 + t*dy
    return (x-nx)**2 + (y-ny)**2 <= hw*hw

acc = np.zeros((H, W, 3), dtype=np.float32)

for sy in range(SS):
    for sx in range(SS):
        yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
        x = (xx + (sx + 0.5) / SS) * (512.0 / W)
        y = (yy + (sy + 0.5) / SS) * (512.0 / H)

        # ---- Rainbow background (diagonal) ----
        t = (x + y) / 1024.0
        r, g, b = rainbow(t)

        # ---- White subtitle card ----
        card = rrect(x, y, 84, 112, 344, 232, 44)
        r[card] = 255.0; g[card] = 255.0; b[card] = 255.0

        # ---- Subtitle lines with "signs" (glyph marks) ----
        lines = [
            # (x, y, width, color, number_of_glyphs)
            (132, 172, 248, LINE_COLORS[0], 6),
            (132, 222, 176, LINE_COLORS[1], 4),
            (132, 272, 212, LINE_COLORS[2], 5),
        ]
        for (lx, ly, lw, col, ng) in lines:
            bar = rrect(x, y, lx, ly, lw, 26, 13)
            r[bar] = float(col[0]); g[bar] = float(col[1]); b[bar] = float(col[2])

            # little white glyph marks inside the bar — looks like text
            glyph_w, gap = 12, 7
            start_x = lx + 16
            for i in range(ng):
                gx = start_x + i * (glyph_w + gap)
                if gx + glyph_w > lx + lw - 12:
                    break
                mark = rrect(x, y, gx, ly + 8, glyph_w, 10, 3)
                r[mark] = 255.0; g[mark] = 255.0; b[mark] = 255.0

        # ---- White badge circle ----
        badge = circle(x, y, 384, 384, 76)
        r[badge] = 255.0; g[badge] = 255.0; b[badge] = 255.0

        # ---- Accent arrow (download) ----
        hw = 9.0
        for (x1, y1, x2, y2) in [
            (384, 336, 384, 408),   # vertical stem
            (356, 380, 384, 408),   # left arrowhead
            (384, 408, 412, 380),   # right arrowhead
            (344, 416, 424, 416),   # underline
        ]:
            m = seg(x, y, x1, y1, x2, y2, hw)
            r[m] = float(ACCENT[0]); g[m] = float(ACCENT[1]); b[m] = float(ACCENT[2])

        acc[..., 0] += r
        acc[..., 1] += g
        acc[..., 2] += b

acc /= (SS * SS)
acc = np.clip(acc, 0, 255)

img = np.zeros((H, W, 4), dtype=np.uint8)
img[..., :3] = acc.astype(np.uint8)
img[..., 3] = 255

# ---- PNG encoding ----
def chunk(typ, data):
    return (struct.pack(">I", len(data)) + typ + data +
            struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))

rows = img.tobytes()
stride = W * 4
raw = bytearray()
for y in range(H):
    raw.append(0)
    raw += rows[y*stride:(y+1)*stride]

png = (b"\x89PNG\r\n\x1a\n" +
       chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)) +
       chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
       chunk(b"IEND", b""))

dated = f"../assets/icon/app_icon_rainbow_colors_lines_{stamp}.png"
stable = "../assets/icon/app_icon.png"    # feste Datei für flutter_launcher_icons

with open(dated, "wb") as f:
    f.write(png)
with open(stable, "wb") as f:             # identische Kopie, stabiler Name
    f.write(png)

print(f"Wrote {dated} ({len(png):,} bytes, {W}x{H})")
print(f"Wrote {stable} (copy of {dated})")
