import os, zlib, struct
from datetime import datetime

stamp = datetime.now().strftime("%Y-%m-%d_%H-%M")

try:
    import numpy as np
except ImportError:
    print("Run: py -m pip install numpy")
    raise SystemExit(1)

W = H = 1024
SS = 2  # supersample for smooth edges

# ---- Seed aus dem Zeitstempel ableiten → jeder Lauf ergibt ein anderes Muster ----
seed = abs(hash(stamp)) % (2**32)
print(f"Pattern seed: {seed}  (stamp {stamp})")

# ---- Harte Farbbänder (kein Verlauf) ----
BANDS = [
    (255,  59,  48),   # rot
    (255, 149,   0),   # orange
    (255, 255,   0),   # gelb
    ( 52, 199,  89),   # grün
    (  0, 199, 190),   # türkis
    (  0, 122, 255),   # blau
    ( 88,  86, 214),   # indigo
    (175,  82, 222),   # lila
    (255,  45,  85),   # pink
]

WHITE  = (255, 255, 255)
ACCENT = (79, 70, 229)   # #4F46E5 — Farbe des Pfeils

# Farben der Untertitel-Zeilen (eine pro Sprache)
LINE_COLORS = [
    (255, 149,   0),   # orange
    (  0, 122, 255),   # blau
    ( 52, 199,  89),   # grün
]

# ---- Zufallsgenerator aus dem Seed ----
rng = np.random.default_rng(seed)

# Optional: Reihenfolge der Farbbänder zufällig mischen
_band_rng = np.random.default_rng(seed + 1)
BANDS = list(BANDS)
_band_rng.shuffle(BANDS)


def smooth(v, w):
    k = np.ones(w, dtype=np.float32) / w
    return np.convolve(v, k, mode='same')


def handdrawn(n, amp):
    """
    Unregelmäßige, handgezeichnete Linie mit viel Zufall:
      - mehrere Wellenlängen (grob / mittel / fein)
      - zufällige Anzahl Sinuswellen
      - zufällige Anzahl scharfer Knicke
      - zufällige Plateaus (flache Stellen)
    """
    t = np.linspace(0, 1, n, dtype=np.float32)

    # Anzahl der Sinuswellen selbst zufällig (3–6)
    n_sines = int(rng.integers(3, 7))
    sine = np.zeros(n, dtype=np.float32)
    for _ in range(n_sines):
        f = rng.uniform(1.5, 9.0)          # Frequenz
        p = rng.uniform(0, 2 * np.pi)      # Phase
        a = rng.uniform(0.2, 1.0)          # Amplitude
        sine += a * np.sin(2 * np.pi * f * t + p)

    # Drei geglättete Rauschanteile mit zufälligen Glättungsbreiten
    w_coarse = int(rng.integers(80, 200))
    w_medium = int(rng.integers(20, 60))
    w_fine   = int(rng.integers(4, 14))

    coarse = smooth(rng.normal(0, 1, n).astype(np.float32), w_coarse)
    medium = smooth(rng.normal(0, 1, n).astype(np.float32), w_medium)
    fine   = smooth(rng.normal(0, 1, n).astype(np.float32), w_fine)

    def norm(a):
        return a / (np.abs(a).max() + 1e-6)

    coarse, medium, fine, sine = norm(coarse), norm(medium), norm(fine), norm(sine)

    # Gewichte zufällig mischen
    wc = rng.uniform(0.4, 0.8)
    wm = rng.uniform(0.15, 0.35)
    wf = rng.uniform(0.05, 0.25)
    ws = rng.uniform(0.3, 0.7)

    v = wc * coarse + wm * medium + wf * fine + ws * sine

    # Zufällige Anzahl scharfer Knicke (3–10)
    n_kinks = int(rng.integers(3, 11))
    for _ in range(n_kinks):
        k = int(rng.integers(20, n - 20))
        width = int(rng.integers(1, 6))
        jump = rng.uniform(-0.9, 0.9)
        v[k:k + width] += jump

    # Zufällige Plateaus (flache Stellen)
    n_plateaus = int(rng.integers(0, 4))
    for _ in range(n_plateaus):
        k = int(rng.integers(20, n - 60))
        length = int(rng.integers(15, 60))
        v[k:k + length] = v[k]

    return (norm(v) * amp).astype(np.float32)


# ---- Zufällige Amplituden ----
amp_y = rng.uniform(50.0, 110.0)
amp_x = rng.uniform(50.0, 110.0)
OFFSET_Y = handdrawn(H, amp_y)[:, None]   # Form (H, 1)
OFFSET_X = handdrawn(W, amp_x)[None, :]   # Form (1, W)
print(f"Amplitudes: Y={amp_y:.1f}, X={amp_x:.1f}")


# ---- Geometrie-Helfer ----
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

        # ---- Zufällig gewellte Farbbänder ----
        t = (x + y + OFFSET_Y + OFFSET_X) / 1024.0
        idx = np.clip((t * len(BANDS)).astype(np.int32), 0, len(BANDS) - 1)
        r = np.zeros_like(x); g = np.zeros_like(x); b = np.zeros_like(x)
        for i, col in enumerate(BANDS):
            m = (idx == i)
            r[m] = float(col[0]); g[m] = float(col[1]); b[m] = float(col[2])

        # ---- Weiße Untertitel-Karte ----
        card = rrect(x, y, 84, 112, 344, 232, 44)
        r[card] = 255.0; g[card] = 255.0; b[card] = 255.0

        # ---- Untertitel-Zeilen mit "Schriftzeichen" ----
        lines = [
            # (x, y, Breite, Farbe, Anzahl Glyphen)
            (132, 172, 248, LINE_COLORS[0], 6),
            (132, 222, 176, LINE_COLORS[1], 4),
            (132, 272, 212, LINE_COLORS[2], 5),
        ]
        for (lx, ly, lw, col, ng) in lines:
            bar = rrect(x, y, lx, ly, lw, 26, 13)
            r[bar] = float(col[0]); g[bar] = float(col[1]); b[bar] = float(col[2])

            glyph_w, gap = 12, 7
            start_x = lx + 16
            for i in range(ng):
                gx = start_x + i * (glyph_w + gap)
                if gx + glyph_w > lx + lw - 12:
                    break
                mark = rrect(x, y, gx, ly + 8, glyph_w, 10, 3)
                r[mark] = 255.0; g[mark] = 255.0; b[mark] = 255.0

        # ---- Weißer Badge-Kreis ----
        badge = circle(x, y, 384, 384, 76)
        r[badge] = 255.0; g[badge] = 255.0; b[badge] = 255.0

        # ---- Akzent-Pfeil (Download) ----
        hw = 9.0
        for (x1, y1, x2, y2) in [
            (384, 336, 384, 408),   # senkrechter Stiel
            (356, 380, 384, 408),   # linker Pfeilkopf
            (384, 408, 412, 380),   # rechter Pfeilkopf
            (344, 416, 424, 416),   # Unterstrich
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


# ---- PNG-Kodierung ----
def chunk(typ, data):
    return (struct.pack(">I", len(data)) + typ + data +
            struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))


rows = img.tobytes()
stride = W * 4
raw = bytearray()
for y in range(H):
    raw.append(0)                       # Filter-Byte 0
    raw += rows[y*stride:(y+1)*stride]  # RGBA

png = (b"\x89PNG\r\n\x1a\n" +
       chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)) +
       chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
       chunk(b"IEND", b""))


# ---- Dateien schreiben (Seed im Namen) ----
os.makedirs("../assets/icon", exist_ok=True)

dated = f"../assets/icon/app_icon_rainbow_colors_art_changing_{stamp}_seed{seed}.png"
stable = "../assets/icon/app_icon.png"    # fester Name für flutter_launcher_icons

with open(dated, "wb") as f:
    f.write(png)
with open(stable, "wb") as f:             # identische Kopie, stabiler Name
    f.write(png)

print(f"Wrote {dated} ({len(png):,} bytes, {W}x{H})")
print(f"Wrote {stable} (copy of {dated})")