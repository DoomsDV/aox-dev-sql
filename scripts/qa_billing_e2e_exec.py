"""Ejecuta scripts qa_billing_e2e_*.sql contra aoxdev. Credenciales desde ~/.cursor/oracle-aoxdev.env."""
from __future__ import annotations

import pathlib
import re
import sys

import oracledb

ENV_PATH = pathlib.Path.home() / ".cursor" / "oracle-aoxdev.env"
SCRIPTS_DIR = pathlib.Path(__file__).resolve().parent
DSN = (
    "(description=(retry_count=1)(retry_delay=1)"
    "(address=(protocol=tcps)(port=1522)(host=adb.sa-saopaulo-1.oraclecloud.com))"
    "(connect_data=(service_name=g9549f707e8ebfa_aoxdev_high.adb.oraclecloud.com))"
    "(security=(ssl_server_dn_match=yes)))"
)


def load_env(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        values[key.strip()] = val.strip().strip("'").strip('"')
    return values


def extract_plsql(sql_text: str) -> str:
    text = re.sub(r"(?im)^\s*SET\s+.*$", "", sql_text)
    text = re.sub(r"(?im)^\s*@@.*$", "", text)
    text = re.sub(r"(?m)^\s*/\s*$", "", text)
    match = re.search(r"\bDECLARE\b", text, flags=re.IGNORECASE)
    if not match:
        raise SystemExit("No se encontró bloque DECLARE en el SQL")
    block = text[match.start():].strip()
    if not re.search(r"END\s*;\s*$", block, flags=re.IGNORECASE):
        raise SystemExit("El bloque PL/SQL no termina en END;")
    return block


def drain_dbms_output(cursor) -> list[str]:
    lines: list[str] = []
    status = cursor.var(oracledb.DB_TYPE_NUMBER)
    line = cursor.var(oracledb.DB_TYPE_VARCHAR, 32767)
    while True:
        cursor.callproc("dbms_output.get_line", [line, status])
        if int(status.getvalue() or 0) != 0:
            break
        value = line.getvalue()
        if value is not None:
            lines.append(value)
    return lines


def run_script(conn, name: str) -> None:
    path = SCRIPTS_DIR / name
    block = extract_plsql(path.read_text(encoding="utf-8"))
    print(f"\n===== {name} =====", flush=True)
    cursor = conn.cursor()
    cursor.callproc("dbms_output.enable", [1000000])
    try:
        cursor.execute(block)
        conn.commit()
    except Exception:
        for out_line in drain_dbms_output(cursor):
            print(out_line)
        raise
    for out_line in drain_dbms_output(cursor):
        print(out_line)


def main() -> int:
    env = load_env(ENV_PATH)
    user = env.get("DB_USER") or env.get("ORACLE_USERNAME")
    password = env.get("DB_PASS") or env.get("ORACLE_PASSWORD")
    wallet = env.get("ORACLE_WALLET_PATH") or env.get("ORACLE_WALLET")
    wallet_pw = env.get("ORACLE_WALLET_PASSWORD") or password
    conn = oracledb.connect(
        user=user,
        password=password,
        dsn=DSN,
        config_dir=wallet,
        wallet_location=wallet,
        wallet_password=wallet_pw,
    )
    try:
        scripts = sys.argv[1:] or [
            "qa_billing_e2e_seed.sql",
            "qa_billing_e2e_modules.sql",
        ]
        for name in scripts:
            run_script(conn, name)
        cur = conn.cursor()
        cur.execute(
            """
            SELECT param_key, param_value
              FROM app_parameter
             WHERE param_key IN ('ADDONS_BILLING_LIVE', 'BILLING_ENABLED')
             ORDER BY param_key
            """
        )
        print("\n===== flags app_parameter =====", flush=True)
        for key, value in cur.fetchall():
            print(f"{key}={value}")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
