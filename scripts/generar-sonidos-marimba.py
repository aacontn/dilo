#!/usr/bin/env python3
"""Genera el juego de sonidos "Marimba" de Dilo.

Por qué existe: los WAV de marimba que traía el repo Tauri llegaron ahí desde
un PR de terceros sin ninguna declaración de origen, así que no se pueden
publicar. Este script sintetiza un juego propio con el mismo carácter —madera,
redondo, cálido— y deja la receta versionada para que cualquiera pueda
regenerar los archivos byte a byte.

Modelo: síntesis aditiva de una barra de marimba. Tres parciales inarmónicos
(1x, 3.9x, 9.2x, los de una barra afinada con arco) con decaimientos cada vez
más cortos, ataque de 3 ms y cola de 300 ms. Los agudos van bajos a propósito:
esto es un aviso, no una alarma.

Begin  sol4 → do5 (dos notas ascendentes)
End    do5 → sol4 (las mismas, al revés)
Paste  una sola nota corta

Uso:
    python3 scripts/generar-sonidos-marimba.py [carpeta-destino]

Sin argumento escribe en Dilo/Resources/Sounds/.
"""

import math
import struct
import sys
import wave
from pathlib import Path

FRECUENCIA_DE_MUESTREO = 48_000
PICO_OBJETIVO_DBFS = -14.0

SOL4 = 392.00
DO5 = 523.25

# (múltiplo de la fundamental, amplitud, constante de decaimiento en segundos)
# La barra de marimba afinada tiene su primer sobretono cerca de 4x y el
# segundo cerca de 9x; ambos se apagan mucho antes que la fundamental, que es
# lo que la hace sonar a madera y no a campana.
PARCIALES = (
  (1.00, 1.00, 0.090),
  (3.90, 0.20, 0.045),
  (9.20, 0.06, 0.022),
)

ATAQUE = 0.003
DESVANECIDO = 0.012


def nota(frecuencia: float, duracion: float) -> list[float]:
  """Una sola nota de marimba, en flotantes, ya sin clics en sus dos puntas."""
  total = int(round(duracion * FRECUENCIA_DE_MUESTREO))
  muestras_de_ataque = max(1, int(round(ATAQUE * FRECUENCIA_DE_MUESTREO)))
  muestras_de_cierre = max(1, int(round(DESVANECIDO * FRECUENCIA_DE_MUESTREO)))
  salida = []

  for n in range(total):
    t = n / FRECUENCIA_DE_MUESTREO
    valor = 0.0
    for multiplo, amplitud, tau in PARCIALES:
      valor += amplitud * math.exp(-t / tau) * math.sin(2 * math.pi * frecuencia * multiplo * t)

    # Ataque de 3 ms en coseno alzado: un corte seco en la muestra cero es un
    # clic, y un ataque más largo deja de sonar a mazo.
    if n < muestras_de_ataque:
      valor *= 0.5 - 0.5 * math.cos(math.pi * n / muestras_de_ataque)

    # La exponencial nunca llega a cero: sin este cierre el archivo termina en
    # un escalón audible.
    restantes = total - n
    if restantes <= muestras_de_cierre:
      valor *= 0.5 - 0.5 * math.cos(math.pi * restantes / muestras_de_cierre)

    salida.append(valor)

  return salida


def mezclar(eventos: list[tuple[float, float, float]]) -> list[float]:
  """Suma notas (inicio en segundos, frecuencia, duración) en una sola pista."""
  pista: list[float] = []
  for inicio, frecuencia, duracion in eventos:
    desfase = int(round(inicio * FRECUENCIA_DE_MUESTREO))
    voz = nota(frecuencia, duracion)
    if len(pista) < desfase + len(voz):
      pista.extend([0.0] * (desfase + len(voz) - len(pista)))
    for i, valor in enumerate(voz):
      pista[desfase + i] += valor
  return pista


def escribir(ruta: Path, pista: list[float]) -> None:
  """Normaliza al pico objetivo y escribe un WAV mono de 16 bits."""
  pico = max(abs(valor) for valor in pista)
  objetivo = 32767 * (10 ** (PICO_OBJETIVO_DBFS / 20))
  ganancia = objetivo / pico
  enteros = [int(round(valor * ganancia)) for valor in pista]

  with wave.open(str(ruta), "wb") as archivo:
    archivo.setnchannels(1)
    archivo.setsampwidth(2)
    archivo.setframerate(FRECUENCIA_DE_MUESTREO)
    archivo.writeframes(struct.pack(f"<{len(enteros)}h", *enteros))

  medido = max(abs(v) for v in enteros)
  dbfs = 20 * math.log10(medido / 32768)
  print(f"{ruta.name}: {len(enteros) / FRECUENCIA_DE_MUESTREO:.3f} s, pico {medido} ({dbfs:.2f} dBFS)")


# El segundo golpe entra a 110 ms: lo justo para oír dos notas y no dos avisos.
SEPARACION = 0.110
LARGO = 0.300

JUEGO = {
  "MarimbaBegin.wav": [(0.0, SOL4, LARGO), (SEPARACION, DO5, LARGO)],
  "MarimbaEnd.wav": [(0.0, DO5, LARGO), (SEPARACION, SOL4, LARGO)],
  "MarimbaPaste.wav": [(0.0, DO5, 0.170)],
}


def main() -> None:
  if len(sys.argv) > 1:
    destino = Path(sys.argv[1])
  else:
    destino = Path(__file__).resolve().parent.parent / "Dilo" / "Resources" / "Sounds"
  destino.mkdir(parents=True, exist_ok=True)

  for nombre, eventos in JUEGO.items():
    escribir(destino / nombre, mezclar(eventos))


if __name__ == "__main__":
  main()
