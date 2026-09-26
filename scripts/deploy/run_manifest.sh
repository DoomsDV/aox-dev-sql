#!/usr/bin/env bash
# Recorre pase_2026-09.manifest con run_sql.sh.
#   AOX_TARGET=clone|prod ADMIN_COPY=<copia preparada de aox-admin-dev-sql> \
#     run_manifest.sh [--from N] [manifiesto]
# Se detiene en el primer FAIL o en una linea STOP (paso manual) e indica con que
# --from retomar. N es el numero de linea del manifiesto.
# DRY_RUN=1: recorre el manifiesto y resuelve las rutas sin conectarse a la base.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SAAS="$(cd "$DIR/../.." && pwd)"
from=1
if [ "${1:-}" = "--from" ]; then from="$2"; shift 2; fi
manifest="${1:-$DIR/pase_2026-09.manifest}"
: "${AOX_TARGET:?Definir AOX_TARGET=clone|prod}"

resolve() {
  case "$1" in
    saas:*)  echo "$SAAS/${1#saas:}" ;;
    admin:*) echo "${ADMIN_COPY:?Definir ADMIN_COPY (aox-admin-dev-sql/scripts/prepare_deploy_copy.sh)}/${1#admin:}" ;;
    *) echo "ruta sin prefijo saas:/admin: $1" >&2; exit 2 ;;
  esac
}

lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  [ "$lineno" -lt "$from" ] && continue
  case "$line" in
    ''|'#'*) continue ;;
    STOP\ *)
      echo ">>> PASO MANUAL (linea $lineno): ${line#STOP }"
      echo ">>> Al terminar: $0 --from $((lineno + 1))"
      exit 3 ;;
    CLONE_DISABLE_JOBS\ *)
      if [ "$AOX_TARGET" = "clone" ]; then
        if [ "${DRY_RUN:-0}" = "1" ]; then
          echo "   [dry-run] (clon) apagar jobs en ${line#CLONE_DISABLE_JOBS }"
        elif ! "$DIR/run_sql.sh" "${line#CLONE_DISABLE_JOBS }" "$DIR/disable_jobs_clone.sql" </dev/null >/dev/null; then
          # Un clon con jobs encendidos manda WhatsApp/push reales: no seguir.
          echo ">>> FALLO al apagar jobs del clon (linea $lineno). Revisar antes de seguir: $0 --from $lineno"
          exit 1
        else
          echo "   (clon) jobs deshabilitados en ${line#CLONE_DISABLE_JOBS }"
        fi
      fi
      continue ;;
  esac
  IFS='|' read -r user mode path <<<"$line"
  target="$(resolve "$path")"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    [ -f "$target" ] || { echo ">>> FALTA (linea $lineno): $target"; exit 1; }
    echo "   [dry-run] $lineno $user ${mode:-} ${target#$SAAS/}"
    continue
  fi
  # </dev/null: que run_sql.sh no consuma lineas del manifiesto (lo lee este while).
  if ! "$DIR/run_sql.sh" "$user" "$target" $mode </dev/null; then
    echo ">>> DETENIDO en la linea $lineno ($path). Corregir y retomar: $0 --from $lineno"
    exit 1
  fi
done <"$manifest"
echo ">>> Manifiesto completo ($AOX_TARGET)."
