#!/usr/bin/env bash
#
# Pide escenas al arnés de la muesca de un Dilo **Debug** que ya está abierto.
#
#   ./scripts/muesca.sh mostrar todas --segundos 4
#   ./scripts/muesca.sh mostrar dictando-largo --mantener --texto un texto larguísimo…
#   ./scripts/muesca.sh mostrar hover reposo-datos
#   ./scripts/muesca.sh siguiente
#   ./scripts/muesca.sh cerrar
#   ./scripts/muesca.sh lista
#
# Cada escena se dibuja en la ventana real y en la pantalla real, sin dictar,
# sin pegar y sin sonar (`Dilo/CoreHUD/EscenaDeMuestra.swift`). Ocho segundos
# cada una salvo `--segundos N` (1–30); `--mantener` deja la primera hasta
# `siguiente` o `cerrar`. Un pedido que llega más de diez segundos tarde no
# se obedece.
#
# El pedido va a la copia cuyo bundle id diga `DILO_ID` (de fábrica
# `cl.espaciodigital.dilo`): con dos Debug abiertos —la de prueba de Alfonso es
# `cl.espaciodigital.dilo.prueba`— cada uno escucha sólo lo suyo.
#
# No lanza nada: si no hay un Debug abierto con ese id, el pedido se pierde
# sin error. Lo que la app hizo con él queda en
#   log show --predicate 'subsystem == "cl.espaciodigital.dilo" && category == "muesca"' --last 5m

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -eq 0 ]]; then
  sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 64
fi

if [[ "$1" == "lista" ]]; then
  # Las escenas salen del enum y no de una copia acá: una lista escrita dos
  # veces es la que se desincroniza.
  sed -n '/^enum EscenaDeMuestra/,/var textoDeMuestra/p' "$raiz/Dilo/CoreHUD/EscenaDeMuestra.swift" \
    | sed -n 's/^  case \([a-zA-Z]*\)\( = "\([^"]*\)"\)\{0,1\}$/\1 \3/p' \
    | awk '{ print ($2 != "" ? $2 : $1) }'
  echo "todas"
  exit 0
fi

nombre="${DILO_ID:-cl.espaciodigital.dilo}.debug.muesca"
linea="$*"

osascript -l JavaScript - "$nombre" "$linea" <<'JXA'
function run(argv) {
  ObjC.import("Foundation");
  // `$()` y no `null`: con `null` en userInfo el puente de JXA no manda nada
  // y tampoco falla (medido el 2026-10-13); `$()` es el nil de Objective-C.
  $.NSDistributedNotificationCenter.defaultCenter
    .postNotificationNameObjectUserInfoDeliverImmediately($(argv[0]), $(argv[1]), $(), true);
}
JXA
