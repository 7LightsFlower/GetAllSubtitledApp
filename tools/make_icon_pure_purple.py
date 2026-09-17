import os, zlib, struct
try:
    import numpy as np
except ImportError:
    print("Run: py -m pip install numpy")
    raise SystemExit(1)

W = H = 1024
SS = 2  # supersample factor for smooth edges

BG    = (0x4F, 0x46, 0xE5)
WHITE = (255, 255, 255)
L1    = (0x4F, 0x46, 0xE5)
L2    = (0x64, 0x74, 0x8B)
L3    = (0x94, 0xA3, 0xB8)

def rrect(x, y, rx, ry, rw, rh, rr):
    inside = (x >= rx) & (x <= rx+rw) & (y >= ry) & (y <= ry+rh)
    cx = np.clip(x, rx+rr, rx+rw-rr)
    cy = np.clip(y, ry+rr, ry+rh-rr)
    return inside & ((x-cx)**2 + (y-cy)**2 <= rr*rr)

def circle(x, y, cx0, cy0, r):
    return (x-cx0)**2 + (y-cy0)**2 <= r*r

def seg(x, y, x1, y1, x2, y2, hw):
    dx = x2 - x1; dy = y2 - y1
    L2 = dx*dx + dy*dy
    if L2 == 0:
        return (x-x1)**2 + (y-y1)**2 <= hw*hw
    t = np.clip(((x-x1)*dx + (y-y1)*dy) / L2, 0, 1)
    nx = x1 + t*dx; ny = y1 + t*dy
    return (x-nx)**2 + (y-ny)**2 <= hw*hw

acc = np.zeros((H, W, 3), dtype=np.float32)

for sy in range(SS):
    for sx in range(SS):
        yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
        x = (xx + (sx + 0.5) / SS) * (512.0 / W)
        y = (yy + (sy + 0.5) / SS) * (512.0 / H)

        r = np.full((H, W), BG[0], dtype=np.float32)
        g = np.full((H, W), BG[1], dtype=np.float32)
        b = np.full((H, W), BG[2], dtype=np.float32)

        # Subtitle card
        m = rrect(x, y, 84, 112, 344, 232, 44)
        r[m], g[m], b[m] = WHITE

        # Subtitle lines
        for (lx, ly, lw, col) in [
            (132, 172, 248, L1),
            (132, 222, 176, L2),
            (132, 272, 212, L3),
        ]:
            m = rrect(x, y, lx, ly, lw, 26, 13)
            r[m], g[m], b[m] = col

        # Badge circle
        m = circle(x, y, 384, 384, 76)
        r[m], g[m], b[m] = BG

        # White arrow + underline strokes
        hw = 9.0
        for (x1, y1, x2, y2) in [
            (384, 336, 384, 408),
            (356, 380, 384, 408),
            (384, 408, 412, 380),
            (344, 416, 424, 416),
        ]:
            m = seg(x, y, x1, y1, x2, y2, hw)
            r[m], g[m], b[m] = WHITE

        acc[..., 0] += r
        acc[..., 1] += g
        acc[..., 2] += b

acc /= (SS * SS)

img = np.zeros((H, W, 4), dtype=np.uint8)
img[..., :3] = acc.astype(np.uint8)
img[..., 3] = 255

# --- Encode PNG ---
def chunk(typ, data):
    return (struct.pack(">I", len(data)) + typ + data +
            struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))

rows = img.tobytes()
stride = W * 4
raw = bytearray()
for y in range(H):
    raw.append(0)                       # filter byte 0
    raw += rows[y*stride:(y+1)*stride]  # RGBA

png = (b"\x89PNG\r\n\x1a\n" +
       chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)) +
       chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
       chunk(b"IEND", b""))

os.makedirs("assets/icon", exist_ok=True)
out = "../assets/icon/app_icon.png"
with open(out, "wb") as f:
    f.write(png)

print(f"Wrote {out} ({len(png):,} bytes, {W}x{H})")
