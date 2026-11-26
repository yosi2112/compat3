#!/usr/bin/env python3
"""Pack KH-Dot-Dougenzaka (SIL OFL 1.1) into COMPAT3's EX_GETFNT font
data. Glyph set = the genuine card's measured acceptance set: JIS
X 0208 ku 1-7 (symbols/kana) + ku 16-47 (level-1 kanji), ten 1-94,
in ku/ten order (3666 glyphs).

  font16.bin: 3666 x 32 B  (16 rows x 2 B, MSB = leftmost pixel)
  font12.bin: 3666 x 24 B  (12 rows x 2 B, 12 pixels in bits 15-4)

A (ku,ten) slot whose character KH-Dot does not carry (or which JIS
leaves unassigned) packs as all-zero. Coverage is reported on stdout
only; no report file is written.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kh_extract import extract
from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, '..', 'fonts')
OUT = os.path.join(HERE, '..', 'build')

SLOTS = []
for ku in list(range(1, 8)) + list(range(16, 48)):
    for ten in range(1, 95):
        SLOTS.append((ku, ten))
assert len(SLOTS) == 3666

def jis_char(ku, ten):
    try:
        return bytes([ku + 0xA0, ten + 0xA0]).decode('euc_jp')
    except (UnicodeDecodeError, ValueError):
        return None

def place(bitmap, cell, baseline_ref):
    """bitmap = (w,h,bearingX,bearingY,rows) -> cell x cell 0/1 matrix."""
    w, h, bx, by, rows = bitmap
    m = [[0] * cell for _ in range(cell)]
    x0, y0 = bx, baseline_ref - by
    for r in range(h):
        for c in range(w):
            x, y = x0 + c, y0 + r
            if 0 <= x < cell and 0 <= y < cell:
                m[y][x] = rows[r][c]
    return m

def pack(ttf_name, cell, baseline_ref, row_bytes):
    f = TTFont(os.path.join(FONTS, ttf_name))
    cmap = f.getBestCmap()
    order = f.getGlyphOrder()
    glyphs = extract(os.path.join(FONTS, ttf_name))
    out = bytearray()
    present = missing = unassigned = 0
    miss_l1 = []
    for idx, (ku, ten) in enumerate(SLOTS):
        ch = jis_char(ku, ten)
        bm = None
        if ch is None:
            unassigned += 1
        elif ord(ch) in cmap:
            gid = order.index(cmap[ord(ch)])
            if gid in glyphs:
                bm = glyphs[gid]
        if bm is None:
            if ch is not None:
                missing += 1
                if 16 <= ku <= 47:
                    miss_l1.append((ku, ten))
            out += bytes(32 if cell == 16 else 24)
            continue
        present += 1
        m = place(bm, cell, baseline_ref)
        for r in range(cell):
            if cell == 16:
                v = 0
                for c in range(16):
                    v = (v << 1) | m[r][c]
                out += bytes([v >> 8, v & 0xFF])
            else:
                v = 0
                for c in range(12):
                    v = (v << 1) | m[r][c]
                v <<= 4
                out += bytes([v >> 8, v & 0xFF])
    f.close()
    return bytes(out), present, missing, unassigned, miss_l1

def main():
    os.makedirs(OUT, exist_ok=True)
    lines = []
    d16, p16, m16, u16, l1_16 = pack('KH-Dot-Dougenzaka-16.ttf', 16, 14, 2)
    d12, p12, m12, u12, l1_12 = pack('KH-Dot-Dougenzaka-12.ttf', 12, 10, 2)
    open(os.path.join(OUT, 'font16.bin'), 'wb').write(d16)
    open(os.path.join(OUT, 'font12.bin'), 'wb').write(d12)
    lines.append('KH-Dot-Dougenzaka packed font coverage (EX_GETFNT set: '
                 'JIS ku 1-7 + 16-47, 3666 slots)')
    for name, p, m, u in (('16x16', p16, m16, u16), ('12x12', p12, m12, u12)):
        lines.append('  %s: present %d, KH-missing %d, JIS-unassigned %d'
                     % (name, p, m, u))
    lines.append('  level-1 kanji (ku 16-47, 3008 slots): '
                 '16x16 missing %d, 12x12 missing %d'
                 % (len(l1_16), len(l1_12)))
    if l1_16:
        lines.append('  16x16 level-1 missing (ku,ten): %s' % (l1_16,))
    if l1_12:
        lines.append('  12x12 level-1 missing (ku,ten): %s' % (l1_12,))
    lines.append('  font16.bin %d bytes, font12.bin %d bytes'
                 % (len(d16), len(d12)))
    rep = '\n'.join(lines) + '\n'
    sys.stdout.write(rep)

if __name__ == '__main__':
    main()
