"""Extract EBDT bitmaps from a KH-Dot TTF (manual EBLC/EBDT parse;
fontTools 4.46 cannot decompile these strikes). Returns
{glyphID: (width, height, bearingX, bearingY, rows)} where rows is
a list of lists of 0/1, top row first."""
import struct

def _tables(d):
    num = struct.unpack('>H', d[4:6])[0]
    tabs = {}
    for i in range(num):
        off = 12 + i * 16
        tag = d[off:off + 4].decode('latin1')
        toff, tlen = struct.unpack('>II', d[off + 8:off + 16])
        tabs[tag] = d[toff:toff + tlen]
    return tabs

def _bits(raw, nbits):
    out = []
    for byte in raw:
        for k in range(7, -1, -1):
            out.append((byte >> k) & 1)
    return out[:nbits]

def _rows(raw, w, h, byte_aligned):
    if byte_aligned:
        stride = (w + 7) // 8
        rows = []
        for r in range(h):
            row = []
            for c in range(w):
                byte = raw[r * stride + c // 8]
                row.append((byte >> (7 - c % 8)) & 1)
            rows.append(row)
        return rows
    bits = _bits(raw, w * h)
    return [bits[r * w:(r + 1) * w] for r in range(h)]

# EBDT image formats: (metrics kind, data alignment)
# 1 small/byte, 2 small/bit, 5 none-in-EBLC/bit, 6 big/byte, 7 big/bit
_FMT = {1: ('small', True), 2: ('small', False), 5: ('eblc', False),
        6: ('big', True), 7: ('big', False)}

def extract(path):
    d = open(path, 'rb').read()
    tabs = _tables(d)
    eblc, ebdt = tabs['EBLC'], tabs['EBDT']
    bst = eblc[8:8 + 48]
    subArrOff = struct.unpack('>I', bst[0:4])[0]
    nSub = struct.unpack('>I', bst[8:12])[0]
    glyphs = {}
    for si in range(nSub):
        first, last, subOff = struct.unpack(
            '>HHI', eblc[subArrOff + si * 8: subArrOff + si * 8 + 8])
        base = subArrOff + subOff
        indexFormat, imageFormat, imgDataOff = struct.unpack(
            '>HHI', eblc[base:base + 8])
        mkind, byte_aligned = _FMT[imageFormat]
        if indexFormat == 2:
            imageSize = struct.unpack('>I', eblc[base + 8:base + 12])[0]
            m = eblc[base + 12:base + 20]
            metrics = (m[1], m[0], m[2], m[3])  # w, h, bearingX, bearingY
            for gi in range(last - first + 1):
                start = imgDataOff + gi * imageSize
                raw = ebdt[start:start + imageSize]
                w, h, bx, by = metrics
                glyphs[first + gi] = (w, h, bx, by,
                                      _rows(raw, w, h, byte_aligned))
        elif indexFormat == 1:
            n = last - first + 1
            offs = struct.unpack('>%dI' % (n + 1),
                                 eblc[base + 8: base + 8 + 4 * (n + 1)])
            for gi in range(n):
                start = imgDataOff + offs[gi]
                end = imgDataOff + offs[gi + 1]
                if mkind == 'big':
                    h, w = ebdt[start], ebdt[start + 1]
                    bx, by = ebdt[start + 2], ebdt[start + 3]
                    if bx > 127: bx -= 256
                    if by > 127: by -= 256
                    raw = ebdt[start + 8:end]
                elif mkind == 'small':
                    h, w = ebdt[start], ebdt[start + 1]
                    bx, by = ebdt[start + 2], ebdt[start + 3]
                    if bx > 127: bx -= 256
                    if by > 127: by -= 256
                    raw = ebdt[start + 5:end]
                else:
                    raise ValueError('format %d in offset subtable' % imageFormat)
                glyphs[first + gi] = (w, h, bx, by,
                                      _rows(raw, w, h, byte_aligned))
        else:
            raise ValueError('indexFormat %d not handled' % indexFormat)
    return glyphs
