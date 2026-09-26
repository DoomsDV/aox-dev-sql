#!/usr/bin/env bash
# Ejecuta un .sql/.pls con SQL*Plus contra el clon de ensayo o produccion.
#   AOX_TARGET=clone|prod run_sql.sh <wksp_aox|hasel_admin> <archivo> [--define|--tolerate]
#
# - Aborta si la base no es la esperada para AOX_TARGET (guard de DB_NAME).
# - WHENEVER SQLERROR EXIT: cualquier ORA- corta el archivo.
# - --tolerate: no corta; al final solo se aceptan errores de "ya existe"
#   (aox-admin-dev-sql reaplica tables/*.sql que install_all ya creo).
# - "created with compilation errors" no corta (SQL*Plus lo trata como warning): se reporta WARN.
# - Corre desde la carpeta del archivo para que los @@ relativos resuelvan.
# - Passwords (nunca se imprimen):
#     wksp_aox    -> ~/.claude.json mcpServers.<aox_clone|aox>.env.ORACLE_PASSWORD
#     hasel_admin -> ~/.config/aox_rehearsal.env (clone) | ~/.config/aox_prod.env (prod), HASEL_ADMIN_PASSWORD
# Requiere Instant Client + SQL*Plus en ~/.local/opt/instantclient_23_26.
set -euo pipefail

case "${AOX_TARGET:-}" in
  clone)
    EXPECTED_DB="G9549F707E8EBFA_AOXREHEARSAL"; WALLET="$HOME/Documentos/wallet/Wallet_AOXREHEARSAL"
    ALIAS="aoxrehearsal_high"; MCP="aox_clone"; ADMIN_ENV="$HOME/.config/aox_rehearsal.env" ;;
  prod)
    EXPECTED_DB="G9549F707E8EBFA_AOX"; WALLET="$HOME/Documentos/wallet/Wallet_aox"
    ALIAS="aox_high"; MCP="aox"; ADMIN_ENV="$HOME/.config/aox_prod.env" ;;
  *) echo "Definir AOX_TARGET=clone|prod"; exit 2 ;;
esac

IC="${AOX_INSTANT_CLIENT:-$HOME/.local/opt/instantclient_23_26}"
export LD_LIBRARY_PATH="$IC" TNS_ADMIN="$WALLET" NLS_LANG=AMERICAN_AMERICA.AL32UTF8
LOGDIR="${AOX_DEPLOY_LOGDIR:-$HOME/.cache/hasel-deploy/$AOX_TARGET/logs}"
mkdir -p "$LOGDIR"

user="${1:?usuario}"; file="${2:?archivo}"; mode="${3:-}"
file="$(realpath "$file")"
[ -f "$file" ] || { echo "No existe: $file"; exit 2; }

TOLERATED='ORA-(00955|01430|01442|02260|02261|02264|02275|01408|40664)'
defset="SET DEFINE OFF"; [ "$mode" = "--define" ] && defset="SET DEFINE ON"
onerr="WHENEVER SQLERROR EXIT FAILURE ROLLBACK"; [ "$mode" = "--tolerate" ] && onerr="WHENEVER SQLERROR CONTINUE"

case "$user" in
  wksp_aox)
    pw="$(MCP="$MCP" python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.claude.json")))["mcpServers"][os.environ["MCP"]]["env"]["ORACLE_PASSWORD"])')" ;;
  hasel_admin)
    # shellcheck disable=SC1090
    source "$ADMIN_ENV"
    pw="${HASEL_ADMIN_PASSWORD:?falta HASEL_ADMIN_PASSWORD en $ADMIN_ENV}" ;;
  *) echo "usuario no soportado: $user"; exit 2 ;;
esac

n=$(( $(ls "$LOGDIR" | wc -l) + 1 ))
log="$LOGDIR/$(printf '%03d' "$n")_${user}_$(basename "$file").log"

start=$(date +%s)
set +e
{
  printf 'CONNECT %s/"%s"@%s\n' "$user" "$pw" "$ALIAS"
  cat <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET ECHO OFF FEEDBACK ON HEADING ON PAGESIZE 200 LINESIZE 250 TRIMSPOOL ON
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED
$defset
BEGIN
    IF SYS_CONTEXT('USERENV','DB_NAME') <> '$EXPECTED_DB' THEN
        RAISE_APPLICATION_ERROR(-20999, 'BASE INESPERADA: ' || SYS_CONTEXT('USERENV','DB_NAME'));
    END IF;
END;
/
ALTER SESSION DISABLE PARALLEL DML;
$onerr
PROMPT >>> $(basename "$file") como $user en $EXPECTED_DB
@$(basename "$file")
PROMPT >>> FIN OK
EXIT SUCCESS
SQL
} | ( cd "$(dirname "$file")" && "$IC/sqlplus" -L -S /nolog ) >"$log" 2>&1
rc=$?
set -e
secs=$(( $(date +%s) - start ))

warn=$(grep -cE "created with compilation errors|SP2-[0-9]+" "$log" || true)
if [ "$mode" = "--tolerate" ]; then
  tolerated=$( (grep -oE "$TOLERATED" "$log" || true) | wc -l)
  other=$(grep -E "^ORA-[0-9]+" "$log" | grep -vE "$TOLERATED" | grep -vE "^ORA-06512" || true)
  if [ -n "$other" ]; then
    echo "FAIL (tolerate) ${secs}s $(basename "$file") -> $log"
    echo "$other" | head -10
    exit 1
  fi
  [ "$tolerated" -gt 0 ] && echo "   (tolerados ya-existe: $tolerated)"
fi
if [ $rc -ne 0 ] || ! grep -q ">>> FIN OK" "$log"; then
  echo "FAIL rc=$rc ${secs}s $(basename "$file") -> $log"
  grep -nE "ORA-|PLS-|SP2-|ERROR" "$log" | head -15
  exit 1
fi
echo "OK ${secs}s warn=$warn $(basename "$file") -> $log"
[ "$warn" -gt 0 ] && grep -nE "created with compilation errors|SP2-[0-9]+" "$log" | head -10
exit 0
