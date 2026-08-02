"""Genera los PNG del ícono de la barra desde la geometría de `brand/tray/`.

El logo de Dilo es el cursor + la onda de tres barras. Antes el estado de
reposo mostraba SÓLO el cursor (`brand/tray/tray_idle.svg`), y entre los demás
íconos de la barra de menú se veía como una barra suelta sin identidad. Ahora
los tres estados usan el logo completo — el mismo dibujo de
`brand/tray/tray_recording.svg`, que ya era la marca entera.

Va monocromo porque macOS los renderiza como template y descarta el color.
"""
import struct, zlib

S = 4                      # supersampling
W = H = 64
# (x, y, ancho, alto, radio) — copiado de brand/tray/tray_recording.svg
RECTS = [
    (8, 14, 12, 36, 3.5),  # cursor
    (28, 24, 7, 16, 3.5),  # onda
    (39, 18, 7, 28, 3.5),
    (50, 26, 7, 12, 3.5),
]

def render():
    w, h = W*S, H*S
    a = bytearray(w*h)
    for (rx, ry, rw, rh, rr) in RECTS:
        x0, y0, bw, bh, r = rx*S, ry*S, rw*S, rh*S, rr*S
        for y in range(y0, y0+bh):
            for x in range(x0, x0+bw):
                # esquinas redondeadas: fuera del círculo del vértice, no pinta
                cx = x0 + r if x < x0 + r else (x0 + bw - r if x > x0 + bw - r else None)
                cy = y0 + r if y < y0 + r else (y0 + bh - r if y > y0 + bh - r else None)
                if cx is not None and cy is not None:
                    if (x+0.5-cx)**2 + (y+0.5-cy)**2 > r*r:
                        continue
                a[y*w + x] = 255
    out = bytearray(W*H)
    for y in range(H):
        for x in range(W):
            s = sum(a[(y*S+dy)*w + (x*S+dx)] for dy in range(S) for dx in range(S))
            out[y*W + x] = s // (S*S)
    return out

def png(alpha, path):
    raw = b''
    for y in range(H):
        raw += b'\x00' + bytes(b for x in range(W) for b in (0, 0, 0, alpha[y*W+x]))
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw, 9))
        + chunk(b'IEND', b''))

a = render()
for n in ('tray_idle', 'tray_idle_dark', 'tray_recording', 'tray_recording_dark',
          'tray_transcribing', 'tray_transcribing_dark'):
    png(a, f'src-tauri/resources/{n}.png')
print('6 PNG generados desde la geometría de brand/tray/')
