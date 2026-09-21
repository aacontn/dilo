#!/usr/bin/env bash
#
# Los cinco números del spec §3, medidos contra un .app ya compilado.
#
#   ./scripts/metrics.sh [ruta/al/Dilo.app] [opciones]
#
# Opciones que se pasan tal cual a dilo-metrics:
#   --sin-latencia      no mide "soltar → texto" (no necesita el gancho Debug)
#   --reposo <s>        ventana de reposo, por defecto 60
#   --arranques <n>     lanzamientos para la mediana de arranque, por defecto 5
#
# Deja el reporte en docs/metricas/ultima-medicion.json —que se versiona— e
# imprime la tabla. **Termina con código ≠ 0 si un umbral no se cumple o si una
# métrica no se pudo medir**, para poder colgarlo de CI sin más cañería.
#
# Para medir la latencia el .app tiene que ser un build **Debug**: el gancho
# DILO_METRICS_WAV no existe en release. Y el terminal desde el que corres esto
# necesita Accesibilidad, porque la sesión se dispara apretando el menú de la
# barra. La app siempre se lanza con `open`, nunca ejecutando el binario: TCC
# atribuye los permisos al proceso responsable.
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-/Volumes/SSD2/scratch/dilo-mac/Dilo.app}"
if [[ $# -gt 0 ]]; then shift; fi

if [[ ! -d "$app" ]]; then
  echo "No existe $app. Compílalo primero o pásame la ruta." >&2
  exit 2
fi

# El taller es SSD2: nada de artefactos de compilación en el disco interno.
# En CI no existe SSD2 y la carpeta por defecto no se puede crear: ahí se usa
# el temporal del runner. `DILO_TALLER` manda si está definido.
if [[ -n "${DILO_TALLER:-}" ]]; then
  taller="$DILO_TALLER/dilo-metrics"
elif [[ -d /Volumes/SSD2/derived-data ]]; then
  taller="/Volumes/SSD2/derived-data/dilo-metrics"
else
  taller="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dilo-metrics"
fi

echo "→ construyendo dilo-metrics"
swift build \
  --package-path "$raiz/DiloCore" \
  --scratch-path "$taller" \
  --configuration release \
  --product dilo-metrics >/dev/null

binario="$(swift build \
  --package-path "$raiz/DiloCore" \
  --scratch-path "$taller" \
  --configuration release \
  --product dilo-metrics \
  --show-bin-path)/dilo-metrics"

exec "$binario" \
  --app "$app" \
  --salida "$raiz/docs/metricas/ultima-medicion.json" \
  "$@"
