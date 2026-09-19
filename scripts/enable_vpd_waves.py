"""Enable VPD restante en oleadas de 3-5 tablas A, probe, luego hijas B.

Si una oleada sangra: DISABLE solo esa oleada (no las anteriores).
Kill switch total: pkg_aox_tenant_vpd.pr_disable_all / policies/03.
"""
from __future__ import annotations

import pathlib
import sys

import oracledb

SCRIPTS = pathlib.Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

from dev_probes_vpd import (  # noqa: E402
    ORG_A,
    ORG_B,
    ProbeReport,
    connect,
    fetch_one,
    probe_booking_slug,
    probe_child_select,
    probe_ords_pool,
    probe_public_surface,
    set_org,
    cleanup_probe_rows,
    OrdsClient,
)

PLS_FILES = [
    ROOT / "packages" / "PKG_AOX_TENANT_VPD.pls",
    ROOT / "packages" / "PKG_AOX_PUBLIC_DIRECTORY.pls",
    ROOT / "packages" / "PKG_AOX_PUBLIC_BOOKING_API.pls",
]

WAVES: list[tuple[str, list[str], str]] = [
    (
        "A1-booking-core",
        [
            "LOCATION",
            "SERVICE",
            "PROFESSIONAL",
            "PROFESSIONAL_SERVICE",
            "PROFESSIONAL_SCHEDULE",
        ],
        "surface",
    ),
    (
        "A2-workspace-hours",
        [
            "WORKSPACE_SETTING",
            "SPECIALTY",
            "ORGANIZATION_SPECIALTY",
            "PROFESSIONAL_SCHEDULE_EXCEPTION",
            "LOCATION_CLOSURE",
        ],
        "surface",
    ),
    (
        "A3-customer-ext",
        [
            "APPOINTMENT_ATTACHMENT",
            "APPOINTMENT_SERIES",
            "APPOINTMENT_SESSION_RECORD",
            "CUSTOMER_PHONE_AUDIT",
            "CUSTOMER_ODONTOGRAM_EVENT",
        ],
        "",
    ),
    (
        "A4-payments-gallery",
        [
            "CUSTOMER_BODY_SNAPSHOT",
            "PAYMENT_TRANSACTION",
            "ORG_PAYMENT_SETTINGS",
            "ORG_PAYMENT_CARD",
            "ORG_GALLERY_IMAGE",
        ],
        "surface",
    ),
    (
        "A5-subscription",
        [
            "ORG_SUBSCRIPTION",
            "ORG_SUBSCRIPTION_INVOICE",
            "ORG_SUBSCRIPTION_ACCESS_AUDIT",
            "ORG_ADDON",
            "ORG_STORAGE_ADDON",
        ],
        "",
    ),
    (
        "A6-billing",
        [
            "ORG_BILLING_PROFILE",
            "ORG_BILLING_CREDIT_LEDGER",
            "SUBSCRIPTION_CREDIT_NOTE",
            "SUBSCRIPTION_EINVOICE_OUTBOX",
            "ORG_ROLE_CAPABILITY",
        ],
        "",
    ),
    (
        "A7-refunds",
        [
            "ORG_REFUND_CLAIM",
            "ORG_REFUND_DISPUTE",
            "ORG_REFUND_DISPUTE_COMPENSATION",
            "ORG_REFUND_DISPUTE_LEDGER",
            "ORG_REFUND_STRIKE",
        ],
        "",
    ),
    (
        "A8-ops-chat",
        [
            "ORG_REFUND_ENFORCEMENT_AUDIT",
            "ORG_REFUND_NOTIFY_OUTBOX",
            "ORG_INTEGRATION",
            "USER_NOTIFICATION",
            "AI_CHAT_SESSION",
        ],
        "",
    ),
    (
        "A9-embeddings",
        ["EMBEDDING_SYNC_OUTBOX", "ORG_ENTITY_EMBEDDING"],
        "ords",
    ),
    (
        "B-children",
        [
            "AI_CHAT_MESSAGE",
            "ORG_REFUND_DISPUTE_EVIDENCE",
            "PROFESSIONAL_IMAGE",
            "PROFESSIONAL_SCHEDULE_EXCEPTION_SLOT",
            "USER_INTEGRATION",
        ],
        "child",
    ),
]


def odci(tables: list[str]) -> str:
    inner = ", ".join("'" + t.replace("'", "''") + "'" for t in tables)
    return f"SYS.ODCIVARCHAR2LIST({inner})"


def compile_pls(conn: oracledb.Connection, path: pathlib.Path) -> None:
    text = path.read_text(encoding="utf-8")
    statements: list[str] = []
    buf: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.upper().startswith("PROMPT "):
            continue
        if stripped == "/":
            stmt = "\n".join(buf).strip()
            if stmt:
                statements.append(stmt)
            buf = []
        else:
            buf.append(line)
    leftover = "\n".join(buf).strip()
    if leftover:
        statements.append(leftover)
    if not statements:
        raise RuntimeError(f"sin statements en {path}")
    for stmt in statements:
        with conn.cursor() as cur:
            cur.execute(stmt)
    print(f"COMPILE OK {path.name} ({len(statements)} statements)", flush=True)


def policy_enabled(cur: oracledb.Cursor, table: str) -> bool:
    n = fetch_one(
        cur,
        """
        SELECT COUNT(*)
          FROM user_policies
         WHERE policy_name = 'AOX_TENANT_VPD'
           AND object_name = :t
           AND enable = 'YES'
        """,
        {"t": table},
    )
    return int(n or 0) == 1


def count_table(cur: oracledb.Cursor, table: str, where: str = "") -> int:
    sql = f"SELECT COUNT(*) FROM {table}"
    if where:
        sql += " WHERE " + where
    return int(fetch_one(cur, sql) or 0)


def snapshot_before(cur: oracledb.Cursor, tables: list[str]) -> dict[str, dict[str, int]]:
    """Cuenta por org mientras la policy sigue DISABLE (sin contexto = todas las filas)."""
    set_org(cur, None)
    out: dict[str, dict[str, int]] = {}
    for table in tables:
        already = policy_enabled(cur, table)
        total = count_table(cur, table)
        n_a = count_table(cur, table, f"org_id_organization = {ORG_A}")
        n_b = count_table(cur, table, f"org_id_organization = {ORG_B}")
        out[table] = {
            "already": int(already),
            "total": total,
            "a": n_a,
            "b": n_b,
        }
    return out


def probe_wave_sql(
    cur: oracledb.Cursor,
    wave: str,
    tables: list[str],
    snap: dict[str, dict[str, int]],
) -> None:
    for table in tables:
        if not policy_enabled(cur, table):
            raise RuntimeError(f"{wave}: {table} ENABLE=NO")

        set_org(cur, None)
        n_clear = count_table(cur, table)
        if n_clear != 0:
            raise RuntimeError(f"{wave}: {table} sin contexto vio {n_clear} filas")

        pre = snap[table]
        if pre["already"]:
            # Idempotente: no comparamos snapshot pre-enable (era 0 por VPD).
            set_org(cur, ORG_A)
            other_a = count_table(cur, table, f"org_id_organization <> {ORG_A}")
            set_org(cur, ORG_B)
            other_b = count_table(cur, table, f"org_id_organization <> {ORG_B}")
            if other_a or other_b:
                raise RuntimeError(
                    f"{wave}: {table} cross-org visible A_other={other_a} B_other={other_b}"
                )
            continue

        set_org(cur, ORG_A)
        n_a = count_table(cur, table)
        other_a = count_table(cur, table, f"org_id_organization <> {ORG_A}")
        if n_a != pre["a"] or other_a:
            raise RuntimeError(
                f"{wave}: {table} set_org({ORG_A}) n={n_a} esperado {pre['a']} other={other_a}"
            )

        set_org(cur, ORG_B)
        n_b = count_table(cur, table)
        other_b = count_table(cur, table, f"org_id_organization <> {ORG_B}")
        if n_b != pre["b"] or other_b:
            raise RuntimeError(
                f"{wave}: {table} set_org({ORG_B}) n={n_b} esperado {pre['b']} other={other_b}"
            )
    set_org(cur, None)


def enable_tables(cur: oracledb.Cursor, tables: list[str]) -> None:
    cur.execute(f"BEGIN pkg_aox_tenant_vpd.pr_enable_tables({odci(tables)}); END;")


def disable_tables(cur: oracledb.Cursor, conn: oracledb.Connection, tables: list[str]) -> None:
    cur.execute(f"BEGIN pkg_aox_tenant_vpd.pr_disable_tables({odci(tables)}); END;")
    conn.commit()


def kill_switch_hint(wave: str, tables: list[str]) -> str:
    return (
        f"Kill switch oleada {wave}: "
        f"BEGIN pkg_aox_tenant_vpd.pr_disable_tables({odci(tables)}); END;\n"
        "Kill switch total: BEGIN pkg_aox_tenant_vpd.pr_disable_all; END; "
        "(o @@policies/03_aox_tenant_vpd_kill_switch.sql)"
    )


def report_failed(report: ProbeReport) -> bool:
    failed = report.failed()
    return bool(failed)


def main() -> int:
    conn = connect()
    ords = OrdsClient()
    try:
        cur = conn.cursor()
        cur.execute("ALTER SESSION DISABLE PARALLEL DML")

        for path in PLS_FILES:
            compile_pls(conn, path)
        conn.commit()
        inv = int(
            fetch_one(
                cur,
                """
                SELECT COUNT(*)
                  FROM user_objects
                 WHERE object_name IN (
                       'PKG_AOX_TENANT_VPD',
                       'PKG_AOX_PUBLIC_DIRECTORY',
                       'PKG_AOX_PUBLIC_BOOKING_API'
                 )
                   AND status = 'INVALID'
                """,
            )
            or 0
        )
        if inv:
            print("FAIL compile: objetos INVALID", flush=True)
            return 1

        baseline = ProbeReport()
        probe_public_surface(cur, baseline, ords)
        if report_failed(baseline):
            print("FAIL superficie publica ANTES de enable A. No se habilita nada.", flush=True)
            return 1
        print("Baseline public surface OK", flush=True)

        for wave, tables, extra in WAVES:
            print(f"\n=== Oleada {wave}: {', '.join(tables)} ===", flush=True)
            snap = snapshot_before(cur, tables)
            for table, info in snap.items():
                print(
                    f"  snap {table}: already={info['already']} total={info['total']} "
                    f"org{ORG_A}={info['a']} org{ORG_B}={info['b']}",
                    flush=True,
                )
            try:
                enable_tables(cur, tables)
                conn.commit()
                probe_wave_sql(cur, wave, tables, snap)
                print(f"  SQL isolation OK {wave}", flush=True)
            except Exception as exc:
                print(f"FAIL {wave}: {exc}", flush=True)
                disable_tables(cur, conn, tables)
                print(kill_switch_hint(wave, tables), flush=True)
                return 1

            if extra == "surface":
                report = ProbeReport()
                probe_public_surface(cur, report, ords)
                if report_failed(report):
                    disable_tables(cur, conn, tables)
                    print(f"FAIL superficie publica tras {wave}", flush=True)
                    print(kill_switch_hint(wave, tables), flush=True)
                    return 1
                print(f"  public surface OK {wave}", flush=True)
            elif extra == "ords":
                report = ProbeReport()
                probe_public_surface(cur, report, ords)
                probe_ords_pool(cur, ords, report)
                probe_booking_slug(cur, conn, ords, report)
                if report_failed(report):
                    print(f"FAIL HTTP/booking tras {wave} (no se deshabilita A9 automatico)", flush=True)
                    print(kill_switch_hint(wave, tables), flush=True)
                    return 1
                print(f"  public+ords+booking OK {wave}", flush=True)
            elif extra == "child":
                report = ProbeReport()
                try:
                    cleanup_probe_rows(cur, conn)
                except Exception as exc:
                    print(f"WARN cleanup pre-child: {exc}", flush=True)
                probe_child_select(cur, conn, report)
                try:
                    cleanup_probe_rows(cur, conn)
                except Exception as exc:
                    print(f"WARN cleanup post-child: {exc}", flush=True)
                if report_failed(report):
                    disable_tables(cur, conn, tables)
                    print(f"FAIL child SELECT tras {wave}", flush=True)
                    print(kill_switch_hint(wave, tables), flush=True)
                    return 1
                child = next((r for r in report.results if r.name == "child_select"), None)
                if child and "VPD hijas ON" not in child.detail:
                    disable_tables(cur, conn, tables)
                    print(f"FAIL {wave}: se esperaba aislamiento ON, detail={child.detail}", flush=True)
                    print(kill_switch_hint(wave, tables), flush=True)
                    return 1
                print(f"  child SELECT OK {wave} (sin cross-org)", flush=True)

        enabled = int(
            fetch_one(cur, "SELECT pkg_aox_tenant_vpd.fn_enabled_count FROM dual") or 0
        )
        targets = int(
            fetch_one(cur, "SELECT pkg_aox_tenant_vpd.fn_target_count FROM dual") or 0
        )
        print(f"\nVPD enabled={enabled}/{targets} (canario + A + B)", flush=True)
        if enabled != targets:
            print("FAIL enabled_count != target_count", flush=True)
            return 1
        print("Oleadas A+B OK. Kill switch no disparado.", flush=True)
        return 0
    finally:
        ords.close()
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
