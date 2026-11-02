#!/usr/bin/env python3
"""Genera el juego de sonidos "Synth3Grave" de Dilo, el de fábrica.

Por qué existe: Alfonso, 2026-11-02, «marimba no me gusta, Click tampoco; el
Synth3 es como el que más sería agradable». De dos tandas de candidatos eligió
éste: el mismo gesto de Synth3 —un golpe grave y uno agudo casi encima— una
quinta más abajo y con más cuerpo. Synth3 se queda como estaba.

Modelo: cada golpe son parciales armónicos con decaimiento exponencial, un
ataque corto en coseno alzado y, en el golpe grave, un soplo de ruido de
1,5 ms que le da el «toc». El ruido sale de un generador congruencial con
semilla fija, así que el script regenera los archivos byte a byte.

Begin  toc grave (mi4) y, 30 ms después, tic agudo (mi5 algo alto)
End    tic corto (mi5) y toc grave (mi4) que canta un poco más
Paste  el tic solo

Uso:
    python3 scripts/generar-sonidos-synth3-grave.py [carpeta-destino]

Sin argumento escribe en Dilo/Resources/Sounds/.
"""

import math
import struct
import sys
import wave
from pathlib import Path

FRECUENCIA_DE_MUESTREO = 48_000
# El mismo pico que Marimba (ver generar-sonidos-marimba.py): un aviso que se
# nota al 50 % de volumen sin ser una alarma.
PICO_OBJETIVO_DBFS = -6.0

LA3 = 220.0
LA4 = 440.0
MI5 = 659.25
LA5 = 880.0

TOC = LA3 * 1.5   # mi4
TIC = MI5 * 1.06  # mi5 un semitono arriba: más claro sin llegar a la octava
DESVANECIDO = 0.010


def golpe(frecuencia, duracion, parciales, ataque, ruido=0.0, tau_ruido=0.004):
  """Un golpe: parciales (múltiplo, amplitud, tau) más un soplo de ruido opcional."""
  total = int(duracion * FRECUENCIA_DE_MUESTREO)
  muestras_de_ataque = max(1, int(ataque * FRECUENCIA_DE_MUESTREO))
  muestras_de_cierre = max(1, int(DESVANECIDO * FRECUENCIA_DE_MUESTREO))
  fases = [0.0] * len(parciales)
  semilla = 12345
  salida = []

  for n in range(total):
    t = n / FRECUENCIA_DE_MUESTREO
    valor = 0.0
    for i, (multiplo, amplitud, tau) in enumerate(parciales):
      fases[i] += 2 * math.pi * frecuencia * multiplo / FRECUENCIA_DE_MUESTREO
      valor += amplitud * math.exp(-t / tau) * math.sin(fases[i])

    if ruido:
      semilla = (1103515245 * semilla + 12345) & 0x7FFFFFFF
      valor += ruido * math.exp(-t / tau_ruido) * (semilla / 0x3FFFFFFF - 1.0)

    # Ataque en coseno alzado: un corte seco en la muestra cero es un clic.
    if n < muestras_de_ataque:
      valor *= 0.5 - 0.5 * math.cos(math.pi * n / muestras_de_ataque)

    # La exponencial nunca llega a cero: sin este cierre el archivo termina en
    # un escalón audible.
    restantes = total - n
    if restantes <= muestras_de_cierre:
      valor *= 0.5 - 0.5 * math.cos(math.pi * restantes / muestras_de_cierre)

    salida.append(valor)

  return salida


def mezclar(eventos):
  """Suma golpes (inicio en segundos, muestras, ganancia) en una sola pista."""
  pista = []
  for inicio, voz, ganancia in eventos:
    desfase = int(inicio * FRECUENCIA_DE_MUESTREO)
    if len(pista) < desfase + len(voz):
      pista.extend([0.0] * (desfase + len(voz) - len(pista)))
    for i, valor in enumerate(voz):
      pista[desfase + i] += valor * ganancia
  return pista


def escribir(ruta, pista):
  """Normaliza al pico objetivo y escribe un WAV mono de 16 bits."""
  pico = max(abs(valor) for valor in pista)
  ganancia = 10 ** (PICO_OBJETIVO_DBFS / 20) / pico
  enteros = [int(round(max(-1.0, min(1.0, valor * ganancia)) * 32767)) for valor in pista]

  with wave.open(str(ruta), "wb") as archivo:
    archivo.setnchannels(1)
    archivo.setsampwidth(2)
    archivo.setframerate(FRECUENCIA_DE_MUESTREO)
    archivo.writeframes(struct.pack(f"<{len(enteros)}h", *enteros))

  medido = max(abs(v) for v in enteros)
  dbfs = 20 * math.log10(medido / 32768)
  print(f"{ruta.name}: {len(enteros) / FRECUENCIA_DE_MUESTREO:.3f} s, pico {medido} ({dbfs:.2f} dBFS)")


def toc(duracion=0.18):
  return golpe(TOC, duracion, [(1, 1.0, 0.025), (2, 0.2, 0.010)], 0.003, ruido=0.15)


def tic(duracion=0.24, tau=0.050, tau_del_brillo=0.015):
  return golpe(TIC, duracion, [(1, 1.0, tau), (2, 0.08, tau_del_brillo)], 0.003)


JUEGO = {
  "Synth3GraveBegin.wav": [(0.0, toc(), 0.9), (0.03, tic(), 1.0)],
  "Synth3GraveEnd.wav": [
    (0.0, golpe(LA5 * 0.75, 0.10, [(1, 1.0, 0.020)], 0.003, ruido=0.1), 0.7),
    (0.045, golpe(LA4 * 0.75, 0.40, [(1, 1.0, 0.090), (2, 0.15, 0.030)], 0.004), 1.0),
  ],
  "Synth3GravePaste.wav": [(0.0, tic(0.16, 0.030, 0.010), 1.0)],
}


def main():
  if len(sys.argv) > 1:
    destino = Path(sys.argv[1])
  else:
    destino = Path(__file__).resolve().parent.parent / "Dilo" / "Resources" / "Sounds"
  destino.mkdir(parents=True, exist_ok=True)

  for nombre, eventos in JUEGO.items():
    escribir(destino / nombre, mezclar(eventos))


if __name__ == "__main__":
  main()
