import struct, zlib

S = 4           # supersampling
W = H = 64
BARS = [40, 20, 32, 24]      # alturas de las 4 barras de la onda de Dilo
BW, GAP = 8, 6

def render():
    w, h = W*S, H*S
    a = bytearray(w*h)                      # canal alfa
    total = len(BARS)*BW + (len(BARS)-1)*GAP
    x0 = (W - total)//2
    for i, bh in enumerate(BARS):
        bx = (x0 + i*(BW+GAP))*S
        by = ((H - bh)//2)*S
        bw, bhh = BW*S, bh*S
        r = bw/2.0                          # extremos redondeados
        for y in range(by, by+bhh):
            for x in range(bx, bx+bw):
                cy = None
                if y < by + r: cy = by + r
                elif y > by + bhh - r: cy = by + bhh - r
                if cy is not None:
                    cx = bx + bw/2.0
                    if (x+0.5-cx)**2 + (y+0.5-cy)**2 > r*r: continue
                a[y*w + x] = 255
    # bajar a 64x64 promediando
    out = bytearray(W*H)
    for y in range(H):
        for x in range(W):
            s = 0
            for dy in range(S):
                for dx in range(S):
                    s += a[(y*S+dy)*w + (x*S+dx)]
            out[y*W + x] = s // (S*S)
    return out

def png(alpha, path):
    raw = b''
    for y in range(H):
        raw += b'\x00' + bytes(b for x in range(W) for b in (0, 0, 0, alpha[y*W+x]))
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    data = (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9))
            + chunk(b'IEND', b''))
    open(path, 'wb').write(data)

a = render()
for n in ('tray_idle', 'tray_idle_dark', 'tray_recording', 'tray_recording_dark',
          'tray_transcribing', 'tray_transcribing_dark'):
    png(a, f'src-tauri/resources/{n}.png')
print('listo: 6 archivos')
