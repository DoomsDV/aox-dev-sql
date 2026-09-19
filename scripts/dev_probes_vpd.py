"""Probes VPD pendientes (dev-probes): pool ORDS, login multi-org, booking por slug,
SELECT hijas B, job expire multi-org.

Credenciales: env DB_USER/DB_PASS/ORACLE_WALLET_PATH o ~/.cursor/oracle-aoxdev.env.
No guarda passwords. Limpia filas VPD-PROBE-* al empezar y al terminar.
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import pathlib
import secrets
import ssl
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any
from urllib.parse import urlencode

import oracledb

ENV_PATH = pathlib.Path.home() / ".cursor" / "oracle-aoxdev.env"
DSN = (
    "(description=(retry_count=1)(retry_delay=1)"
    "(address=(protocol=tcps)(port=1522)(host=adb.sa-saopaulo-1.oraclecloud.com))"
    "(connect_data=(service_name=g9549f707e8ebfa_aoxdevelop_high.adb.oraclecloud.com))"
    "(security=(ssl_server_dn_match=yes)))"
)
ORDS_HOST = "g9549f707e8ebfa-aoxdevelop.adb.sa-saopaulo-1.oraclecloudapps.com"
API_PREFIX = "/ords/aoxdev/api/v1"
PUBLIC_PREFIX = "/ords/aoxdev/public/v1"

ORG_A = 1
ORG_B = 5
SLUG_A = "consultorio-dann"
SLUG_B = "fisio-max"
MARKER = "VPD-PROBE-DEV"
USER_EMAIL = "vpd-probe-dev@invalid.example"
USER_NAME = "VPD_PROBE_DEV"
HASH_ORG_A = "VPD-PROBE-ORG1"
HASH_ORG_B = "VPD-PROBE-ORG5"
JOB_NAME = "HASEL_EXPIRE_PENDING_PAYMENTS"


class ProbeError(RuntimeError):
    pass


@dataclass
class ProbeResult:
    name: str
    ok: bool
    detail: str


@dataclass
class ProbeReport:
    results: list[ProbeResult] = field(default_factory=list)

    def add(self, name: str, ok: bool, detail: str) -> None:
        self.results.append(ProbeResult(name, ok, detail))
        flag = "PASS" if ok else "FAIL"
        print(f"[{flag}] {name}: {detail}", flush=True)

    def failed(self) -> list[ProbeResult]:
        return [r for r in self.results if not r.ok]


def load_env(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        values[key.strip()] = val.strip().strip("'").strip('"')
    return values


def connect() -> oracledb.Connection:
    env = load_env(ENV_PATH)
    user = os.environ.get("DB_USER") or env.get("DB_USER") or env.get("ORACLE_USERNAME") or "aoxdev"
    password = os.environ.get("DB_PASS") or env.get("DB_PASS") or env.get("ORACLE_PASSWORD")
    wallet = (
        os.environ.get("ORACLE_WALLET_PATH")
        or env.get("ORACLE_WALLET_PATH")
        or env.get("ORACLE_WALLET")
        or "/home/dann/Documentos/wallet/Wallet_aoxdevelop"
    )
    wallet_pw = os.environ.get("ORACLE_WALLET_PASSWORD") or env.get("ORACLE_WALLET_PASSWORD") or password
    if not password:
        raise SystemExit("Falta DB_PASS / ORACLE_PASSWORD (env o ~/.cursor/oracle-aoxdev.env)")
    return oracledb.connect(
        user=user,
        password=password,
        dsn=DSN,
        config_dir=wallet,
        wallet_location=wallet,
        wallet_password=wallet_pw,
    )


def fetch_one(cur: oracledb.Cursor, sql: str, binds: dict | None = None) -> Any:
    cur.execute(sql, binds or {})
    row = cur.fetchone()
    return row[0] if row else None


def fetch_all(cur: oracledb.Cursor, sql: str, binds: dict | None = None) -> list[tuple]:
    cur.execute(sql, binds or {})
    return list(cur.fetchall())


def set_org(cur: oracledb.Cursor, org_id: int | None) -> None:
    if org_id is None:
        cur.execute("BEGIN pkg_aox_session.clear; END;")
    else:
        cur.execute("BEGIN pkg_aox_session.set_org(:org_id); END;", {"org_id": org_id})


class OrdsClient:
    def __init__(self) -> None:
        ctx = ssl.create_default_context()
        self.conn = http.client.HTTPSConnection(ORDS_HOST, timeout=90, context=ctx)

    def close(self) -> None:
        try:
            self.conn.close()
        except Exception:
            pass

    def request(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        token: str | None = None,
        extra_headers: dict[str, str] | None = None,
    ) -> tuple[int, Any, str]:
        payload = None if body is None else json.dumps(body).encode("utf-8")
        headers = {
            "Accept": "application/json",
            "Connection": "keep-alive",
        }
        if payload is not None:
            headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = f"Bearer {token}"
        if extra_headers:
            headers.update(extra_headers)
        try:
            self.conn.request(method, path, body=payload, headers=headers)
            resp = self.conn.getresponse()
            raw = resp.read().decode("utf-8", errors="replace")
            status = resp.status
        except (http.client.RemoteDisconnected, ConnectionError, OSError):
            self.conn.close()
            ctx = ssl.create_default_context()
            self.conn = http.client.HTTPSConnection(ORDS_HOST, timeout=90, context=ctx)
            self.conn.request(method, path, body=payload, headers=headers)
            resp = self.conn.getresponse()
            raw = resp.read().decode("utf-8", errors="replace")
            status = resp.status
        parsed: Any = None
        if raw:
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                parsed = raw
        return status, parsed, raw


def encode_jwt(cur: oracledb.Cursor, user_id: int, role_id: int, org_id: int) -> str:
    token_var = cur.var(oracledb.DB_TYPE_VARCHAR, 4000)
    cur.execute(
        """
        DECLARE
            v_secret RAW(2000);
        BEGIN
            v_secret := utl_raw.cast_to_raw(fn_get_parameter('JWT_TOKEN'));
            :token := apex_jwt.encode(
                p_iss           => NVL(fn_get_parameter('JWT_ISSUER'), 'hasel-api'),
                p_sub           => 'aox-vpd-dev-probes',
                p_aud           => NVL(fn_get_parameter('JWT_AUDIENCE'), 'hasel-app'),
                p_exp_sec       => 300,
                p_other_claims  => '"user_id": ' || :user_id
                                   || ', "role_id": ' || :role_id
                                   || ', "organization_id": ' || :org_id,
                p_signature_key => v_secret
            );
        END;
        """,
        {"token": token_var, "user_id": user_id, "role_id": role_id, "org_id": org_id},
    )
    token = token_var.getvalue()
    if not token:
        raise ProbeError("apex_jwt.encode devolvio vacio")
    return str(token)


def member_for_org(cur: oracledb.Cursor, org_id: int) -> tuple[int, int]:
    cur.execute(
        """
        SELECT m.id_org_member, m.rol_id_role
          FROM org_member m
         WHERE m.org_id_organization = :org_id
           AND m.is_active = 1
           AND m.rol_id_role = 1
         FETCH FIRST 1 ROW ONLY
        """,
        {"org_id": org_id},
    )
    row = cur.fetchone()
    if not row:
        raise ProbeError(f"sin org_member admin activo en org {org_id}")
    return int(row[0]), int(row[1])


def customer_ids(payload: Any) -> set[int]:
    if not isinstance(payload, dict):
        return set()
    data = payload.get("data") or []
    if not isinstance(data, list):
        return set()
    ids: set[int] = set()
    for item in data:
        if isinstance(item, dict) and item.get("id_customer") is not None:
            ids.add(int(item["id_customer"]))
    return ids


def cleanup_probe_rows(cur: oracledb.Cursor, conn: oracledb.Connection) -> None:
    """Borra residuos de corridas anteriores. Requiere set_org para tablas VPD."""
    for org_id in (ORG_A, ORG_B):
        set_org(cur, org_id)
        cur.execute(
            """
            DELETE FROM ai_chat_message
             WHERE ses_id_session IN (
                   SELECT id_session FROM ai_chat_session WHERE title = :marker
             )
            """,
            {"marker": MARKER},
        )
        cur.execute("DELETE FROM ai_chat_session WHERE title = :marker", {"marker": MARKER})
        cur.execute(
            "DELETE FROM professional_image WHERE file_name = :fn",
            {"fn": "vpd-probe-dev.png"},
        )

    set_org(cur, None)
    cur.execute(
        """
        DELETE FROM app_user_session
         WHERE use_id_user IN (
               SELECT m.id_org_member
                 FROM org_member m
                 JOIN platform_user pu ON pu.id_platform_user = m.platform_user_id
                WHERE pu.email = :email OR pu.apex_user_name = :uname
         )
        """,
        {"email": USER_EMAIL, "uname": USER_NAME},
    )
    cur.execute(
        """
        DELETE FROM org_member
         WHERE platform_user_id IN (
               SELECT id_platform_user FROM platform_user
                WHERE email = :email OR apex_user_name = :uname
         )
        """,
        {"email": USER_EMAIL, "uname": USER_NAME},
    )
    cur.execute(
        "DELETE FROM platform_user WHERE email = :email OR apex_user_name = :uname",
        {"email": USER_EMAIL, "uname": USER_NAME},
    )

    for org_id, marker_hash in ((ORG_A, HASH_ORG_A), (ORG_B, HASH_ORG_B)):
        set_org(cur, org_id)
        cust_ids = [
            int(r[0])
            for r in fetch_all(
                cur,
                "SELECT id_customer FROM customer WHERE full_name = :n",
                {"n": MARKER},
            )
        ]
        app_ids = [
            int(r[0])
            for r in fetch_all(
                cur,
                "SELECT id_appointment FROM appointment WHERE pagopar_hash = :h",
                {"h": marker_hash},
            )
        ]
        if cust_ids:
            in_cust = ",".join(str(i) for i in cust_ids)
            app_ids.extend(
                int(r[0])
                for r in fetch_all(
                    cur,
                    f"SELECT id_appointment FROM appointment WHERE cus_id_customer IN ({in_cust})",
                )
            )
        app_ids = sorted(set(app_ids))
        if app_ids:
            id_list = ",".join(str(i) for i in app_ids)
            cur.execute(f"DELETE FROM payment_transaction WHERE app_id_appointment IN ({id_list})")
            cur.execute(f"DELETE FROM org_public_token WHERE app_id_appointment IN ({id_list})")
            cur.execute(f"DELETE FROM appointment WHERE id_appointment IN ({id_list})")
        if cust_ids:
            cur.execute(
                "DELETE FROM customer WHERE full_name = :n",
                {"n": MARKER},
            )
    set_org(cur, None)
    conn.commit()


def probe_ords_pool(cur: oracledb.Cursor, ords: OrdsClient, report: ProbeReport) -> None:
    member_a, role_a = member_for_org(cur, ORG_A)
    member_b, role_b = member_for_org(cur, ORG_B)
    token_a = encode_jwt(cur, member_a, role_a, ORG_A)
    token_b = encode_jwt(cur, member_b, role_b, ORG_B)

    set_org(cur, ORG_A)
    db_count_a = int(fetch_one(cur, "SELECT COUNT(*) FROM customer WHERE NVL(is_active,1)=1") or 0)
    set_org(cur, ORG_B)
    db_count_b = int(fetch_one(cur, "SELECT COUNT(*) FROM customer WHERE NVL(is_active,1)=1") or 0)
    set_org(cur, None)

    path = f"{API_PREFIX}/customers?{urlencode({'page': 1, 'limit': 100, 'archived': 0})}"
    ids_last: set[int] | None = None
    bleed = False
    details: list[str] = []

    for i in range(6):
        token = token_a if i % 2 == 0 else token_b
        org_expect = ORG_A if i % 2 == 0 else ORG_B
        db_expect = db_count_a if org_expect == ORG_A else db_count_b
        status, payload, raw = ords.request("GET", path, token=token)
        if status != 200 or not isinstance(payload, dict) or payload.get("status") != "success":
            report.add(
                "ords_pool",
                False,
                f"GET /customers org {org_expect} HTTP {status}: {raw[:300]}",
            )
            return
        meta = payload.get("meta") or {}
        total = int(meta.get("total_records") or 0)
        ids = customer_ids(payload)
        details.append(f"r{i}:org{org_expect}:total={total}:ids={len(ids)}")
        if total != db_expect:
            report.add(
                "ords_pool",
                False,
                f"org {org_expect} total_records={total} DB={db_expect} ({'; '.join(details)})",
            )
            return
        if ids_last is not None and org_expect == ORG_B and ids_last and ids_last & ids:
            bleed = True
            break
        ids_last = ids if org_expect == ORG_A else ids_last

    status_unauth, payload_unauth, _ = ords.request("GET", path)
    if status_unauth in (200,) and isinstance(payload_unauth, dict) and payload_unauth.get("data"):
        report.add(
            "ords_pool",
            False,
            f"GET /customers sin JWT HTTP {status_unauth} devolvio data (leftover de pool)",
        )
        return

    if bleed:
        report.add("ords_pool", False, "IDs de org A aparecieron en org B (bleed de pool)")
        return
    if db_count_a == 0:
        report.add("ords_pool", False, "org 1 no tiene clientes; el pool no es verificable")
        return
    report.add(
        "ords_pool",
        True,
        f"6 GET keep-alive A/B aislados; org1={db_count_a} org5={db_count_b}; "
        f"sin JWT HTTP {status_unauth}; {'; '.join(details)}",
    )


def probe_auth_login(cur: oracledb.Cursor, conn: oracledb.Connection, ords: OrdsClient, report: ProbeReport) -> None:
    password = "Probe-" + secrets.token_urlsafe(12)
    salt_var = cur.var(oracledb.DB_TYPE_VARCHAR, 64)
    hash_var = cur.var(oracledb.DB_TYPE_VARCHAR, 255)
    iter_var = cur.var(oracledb.DB_TYPE_NUMBER)
    cur.execute(
        """
        BEGIN
            :salt := pkg_aox_util.fn_generate_password_salt;
            :iter := pkg_aox_util.fn_param_number('PASSWORD_HASH_ITERATIONS', 100000);
            :hash := pkg_aox_util.fn_hash_password_v2(:pw, :salt, :iter);
        END;
        """,
        {"salt": salt_var, "iter": iter_var, "hash": hash_var, "pw": password},
    )
    salt = salt_var.getvalue()
    pw_hash = hash_var.getvalue()
    iterations = int(iter_var.getvalue())

    cur.execute(
        """
        INSERT INTO platform_user (
            apex_user_name, email, password_hash, first_name, last_name,
            is_active, email_verified_at, password_salt, password_algo, password_iterations
        ) VALUES (
            :uname, :email, :hash, 'VPD', 'Probe',
            1, SYSTIMESTAMP, :salt, 'PBKDF2_HMAC_SHA256_V1', :iter
        )
        """,
        {"uname": USER_NAME, "email": USER_EMAIL, "hash": pw_hash, "salt": salt, "iter": iterations},
    )
    pu_id = int(fetch_one(cur, "SELECT id_platform_user FROM platform_user WHERE email = :e", {"e": USER_EMAIL}))
    cur.execute(
        """
        INSERT INTO org_member (platform_user_id, org_id_organization, rol_id_role, is_active)
        VALUES (:pu, :org, 1, 1)
        """,
        {"pu": pu_id, "org": ORG_A},
    )
    cur.execute(
        """
        INSERT INTO org_member (platform_user_id, org_id_organization, rol_id_role, is_active)
        VALUES (:pu, :org, 1, 1)
        """,
        {"pu": pu_id, "org": ORG_B},
    )
    conn.commit()

    status, payload, raw = ords.request(
        "POST",
        f"{API_PREFIX}/auth/login",
        body={"username": USER_EMAIL, "password": password},
    )
    if status != 200 or not isinstance(payload, dict) or payload.get("status") != "success":
        report.add("auth_login", False, f"login HTTP {status}: {raw[:400]}")
        return
    orgs = payload.get("organizations") or []
    org_ids = sorted(
        int(o["organization_id"]) for o in orgs if isinstance(o, dict) and o.get("organization_id") is not None
    )
    if payload.get("selection_required") not in (1, True) or len(orgs) < 2:
        report.add(
            "auth_login",
            False,
            f"login no listo N orgs: selection_required={payload.get('selection_required')} n={len(orgs)}",
        )
        return
    if ORG_A not in org_ids or ORG_B not in org_ids:
        report.add("auth_login", False, f"login orgs incompletas: {org_ids}")
        return

    member_a = next(int(o["org_member_id"]) for o in orgs if int(o["organization_id"]) == ORG_A)
    status_sel, payload_sel, raw_sel = ords.request(
        "POST",
        f"{API_PREFIX}/auth/select-organization",
        body={"selection_token": payload.get("selection_token"), "org_member_id": member_a},
    )
    if status_sel != 200 or not isinstance(payload_sel, dict) or not payload_sel.get("refresh_token"):
        report.add("auth_login", False, f"select-organization HTTP {status_sel}: {raw_sel[:400]}")
        return

    refresh = payload_sel["refresh_token"]
    status_ref, payload_ref, raw_ref = ords.request(
        "POST",
        f"{API_PREFIX}/auth/refresh",
        body={"refresh_token": refresh},
    )
    if status_ref != 200 or not isinstance(payload_ref, dict) or not payload_ref.get("access_token"):
        report.add("auth_refresh", False, f"refresh HTTP {status_ref}: {raw_ref[:400]}")
        return
    new_refresh = payload_ref.get("refresh_token") or refresh
    report.add("auth_refresh", True, "POST /auth/refresh por token OK (tabla C, sin VPD)")

    status_out, payload_out, raw_out = ords.request(
        "POST",
        f"{API_PREFIX}/auth/logout",
        body={"refresh_token": new_refresh},
    )
    if status_out != 200 or not isinstance(payload_out, dict) or payload_out.get("status") != "success":
        report.add("auth_logout", False, f"logout HTTP {status_out}: {raw_out[:400]}")
        return

    revoked = int(
        fetch_one(
            cur,
            "SELECT COUNT(*) FROM app_user_session WHERE refresh_token = :t AND is_revoked = 1",
            {"t": new_refresh},
        )
        or 0
    )
    status_dead, payload_dead, _ = ords.request(
        "POST",
        f"{API_PREFIX}/auth/refresh",
        body={"refresh_token": new_refresh},
    )
    dead_ok = status_dead >= 400 or (
        isinstance(payload_dead, dict) and payload_dead.get("status") == "error"
    )
    if revoked == 0 or not dead_ok:
        report.add(
            "auth_logout",
            False,
            f"logout no revoco (revoked={revoked}) o refresh post-logout sigue vivo HTTP {status_dead}",
        )
        return
    report.add(
        "auth_logout",
        True,
        "POST /auth/logout revoca refresh; reuso posterior rechazado",
    )
    report.add(
        "auth_login",
        True,
        f"login listo {len(orgs)} orgs {org_ids}; select-org + refresh + logout OK",
    )


def probe_booking_slug(cur: oracledb.Cursor, conn: oracledb.Connection, ords: OrdsClient, report: ProbeReport) -> None:
    set_org(cur, None)
    slug_org = int(
        fetch_one(
            cur,
            "SELECT org_id_organization FROM org_public_directory WHERE profile_slug = :s",
            {"s": SLUG_A},
        )
        or 0
    )
    if slug_org != ORG_A:
        report.add("booking_slug_bind", False, f"directorio slug {SLUG_A} -> org {slug_org}")
        return

    set_org(cur, ORG_B)
    leftover = int(fetch_one(cur, "SELECT NVL(pkg_aox_session.fn_current_org_id, 0) FROM dual") or 0)
    cur.execute(
        "BEGIN pkg_aox_session.pr_bind_tenant_from_public_slug(:slug); END;",
        {"slug": SLUG_A},
    )
    bound = int(fetch_one(cur, "SELECT NVL(pkg_aox_session.fn_current_org_id, 0) FROM dual") or 0)
    set_org(cur, None)
    if leftover != ORG_B or bound != ORG_A:
        report.add(
            "booking_slug_bind",
            False,
            f"bind slug no pisa leftover: leftover={leftover} bound={bound}",
        )
        return
    report.add(
        "booking_slug_bind",
        True,
        f"leftover org {ORG_B} + slug {SLUG_A} -> contexto {ORG_A} (nunca JSON org_id)",
    )

    today = date.today()
    qs = urlencode(
        {
            "pro_id": 1,
            "loc_id": 1,
            "ser_id": 4,
            "from_date": today.isoformat(),
            "to_date": (today + timedelta(days=21)).isoformat(),
        }
    )
    status_d, payload_d, raw_d = ords.request("GET", f"{PUBLIC_PREFIX}/available-dates?{qs}")
    dates = []
    if isinstance(payload_d, dict):
        dates = payload_d.get("data") or []
    if status_d != 200 or not dates:
        report.add(
            "booking_slug_insert",
            False,
            f"sin fechas libres HTTP {status_d}: {raw_d[:300]}",
        )
        return
    target = dates[0]
    qs_slots = urlencode({"pro_id": 1, "loc_id": 1, "ser_id": 4, "target_date": target})
    status_s, payload_s, raw_s = ords.request("GET", f"{PUBLIC_PREFIX}/available-slots?{qs_slots}")
    slots = []
    if isinstance(payload_s, dict):
        slots = payload_s.get("data") or []
    if status_s != 200 or not slots:
        report.add(
            "booking_slug_insert",
            False,
            f"sin slots HTTP {status_s} fecha {target}: {raw_s[:300]}",
        )
        return
    hhmm = slots[0]
    start_time = f"{target}T{hhmm}:00"
    phone = "0981990" + str(int(time.time()) % 10000).zfill(4)
    body = {
        "organization_slug": SLUG_A,
        "org_id_organization": ORG_B,
        "pro_id_professional": 1,
        "loc_id_location": 1,
        "ser_id_service": 4,
        "start_time": start_time,
        "customer_name": MARKER,
        "customer_phone": phone,
    }
    idem = f"vpd-probe-{uuid.uuid4()}"
    status_c, payload_c, raw_c = ords.request(
        "POST",
        f"{PUBLIC_PREFIX}/appointments",
        body=body,
        extra_headers={"Idempotency-Key": idem},
    )
    if status_c not in (200, 201) or not isinstance(payload_c, dict):
        report.add("booking_slug_insert", False, f"POST /public/appointments HTTP {status_c}: {raw_c[:500]}")
        return
    app_id = payload_c.get("appointment_id")
    if not app_id:
        report.add("booking_slug_insert", False, f"respuesta sin appointment_id: {raw_c[:400]}")
        return
    set_org(cur, ORG_A)
    row = fetch_all(
        cur,
        """
        SELECT org_id_organization, cus_id_customer, public_manage_token
          FROM appointment
         WHERE id_appointment = :id
        """,
        {"id": int(app_id)},
    )
    set_org(cur, ORG_B)
    seen_in_b = int(
        fetch_one(cur, "SELECT COUNT(*) FROM appointment WHERE id_appointment = :id", {"id": int(app_id)}) or 0
    )
    set_org(cur, None)
    if not row:
        report.add("booking_slug_insert", False, f"cita {app_id} no visible en org A tras INSERT")
        return
    org_written, cus_id, token = row[0]
    if int(org_written) != ORG_A or seen_in_b != 0:
        report.add(
            "booking_slug_insert",
            False,
            f"JSON org_id={ORG_B} desvio el contexto: escrito org={org_written} visible_en_B={seen_in_b}",
        )
        return

    # Limpieza inmediata de la reserva de probe (canario VPD).
    set_org(cur, ORG_A)
    cur.execute("DELETE FROM payment_transaction WHERE app_id_appointment = :id", {"id": int(app_id)})
    cur.execute("DELETE FROM org_public_token WHERE app_id_appointment = :id", {"id": int(app_id)})
    cur.execute("DELETE FROM appointment WHERE id_appointment = :id", {"id": int(app_id)})
    if cus_id:
        leftover_apps = int(
            fetch_one(cur, "SELECT COUNT(*) FROM appointment WHERE cus_id_customer = :id", {"id": int(cus_id)}) or 0
        )
        if leftover_apps == 0:
            cur.execute("DELETE FROM customer WHERE id_customer = :id AND full_name = :n", {"id": int(cus_id), "n": MARKER})
    conn.commit()
    set_org(cur, None)
    report.add(
        "booking_slug_insert",
        True,
        f"POST slug={SLUG_A} + org_id JSON={ORG_B} inserto cita {app_id} en org {ORG_A}; "
        f"token_len={len(str(token or ''))}; no visible en org B",
    )


def probe_child_select(cur: oracledb.Cursor, conn: oracledb.Connection, report: ProbeReport) -> None:
    enabled = int(
        fetch_one(
            cur,
            """
            SELECT COUNT(*)
              FROM user_policies
             WHERE policy_name = 'AOX_TENANT_VPD'
               AND object_name IN ('PROFESSIONAL_IMAGE', 'AI_CHAT_MESSAGE')
               AND enable = 'YES'
            """,
        )
        or 0
    )
    # usr_id_user tiene FK dual (ORG_MEMBER + APP_USER_LEGACY). LEGACY solo
    # tiene ids de org 1; usamos uno de esos para ambas sesiones. Lo que
    # importa al probe es org_id denormalizado en la hija.
    chat_user = int(
        fetch_one(
            cur,
            """
            SELECT m.id_org_member
              FROM org_member m
              JOIN app_user_legacy u ON u.id_user = m.id_org_member
             WHERE m.is_active = 1
             FETCH FIRST 1 ROW ONLY
            """,
        )
        or 0
    )
    set_org(cur, ORG_B)
    pro_b = int(
        fetch_one(
            cur,
            "SELECT id_professional FROM professional WHERE org_id_organization = :org AND is_active = 1 FETCH FIRST 1 ROW ONLY",
            {"org": ORG_B},
        )
        or 0
    )
    set_org(cur, None)
    if not chat_user or not pro_b:
        report.add("child_select", False, "faltan padre (APP_USER_LEGACY/professional) para seed hijas")
        return

    set_org(cur, ORG_A)
    cur.execute(
        """
        INSERT INTO ai_chat_session (org_id_organization, usr_id_user, title, is_active)
        VALUES (:org, :usr, :title, 1)
        """,
        {"org": ORG_A, "usr": chat_user, "title": MARKER},
    )
    ses_a = int(fetch_one(cur, "SELECT MAX(id_session) FROM ai_chat_session WHERE title = :t AND org_id_organization = :o", {"t": MARKER, "o": ORG_A}))
    cur.execute(
        """
        INSERT INTO ai_chat_message (ses_id_session, org_id_organization, sender_role, content)
        VALUES (:ses, :org, 'user', :c)
        """,
        {"ses": ses_a, "org": ORG_A, "c": MARKER},
    )

    set_org(cur, ORG_B)
    cur.execute(
        """
        INSERT INTO ai_chat_session (org_id_organization, usr_id_user, title, is_active)
        VALUES (:org, :usr, :title, 1)
        """,
        {"org": ORG_B, "usr": chat_user, "title": MARKER},
    )
    ses_b = int(fetch_one(cur, "SELECT MAX(id_session) FROM ai_chat_session WHERE title = :t AND org_id_organization = :o", {"t": MARKER, "o": ORG_B}))
    cur.execute(
        """
        INSERT INTO ai_chat_message (ses_id_session, org_id_organization, sender_role, content)
        VALUES (:ses, :org, 'user', :c)
        """,
        {"ses": ses_b, "org": ORG_B, "c": MARKER},
    )
    already = int(
        fetch_one(
            cur,
            "SELECT COUNT(*) FROM professional_image WHERE pro_id_professional = :p AND org_id_organization = :o",
            {"p": pro_b, "o": ORG_B},
        )
        or 0
    )
    if already == 0:
        cur.execute(
            """
            INSERT INTO professional_image (pro_id_professional, org_id_organization, file_name, mime_type)
            VALUES (:p, :o, 'vpd-probe-dev.png', 'image/png')
            """,
            {"p": pro_b, "o": ORG_B},
        )
    conn.commit()

    set_org(cur, ORG_A)
    img_b = int(
        fetch_one(
            cur,
            "SELECT COUNT(*) FROM professional_image WHERE org_id_organization = :o",
            {"o": ORG_B},
        )
        or 0
    )
    msg_b = int(
        fetch_one(
            cur,
            "SELECT COUNT(*) FROM ai_chat_message WHERE org_id_organization = :o AND DBMS_LOB.SUBSTR(content, 40, 1) = :c",
            {"o": ORG_B, "c": MARKER},
        )
        or 0
    )
    img_all = int(fetch_one(cur, "SELECT COUNT(*) FROM professional_image") or 0)
    msg_all = int(fetch_one(cur, "SELECT COUNT(*) FROM ai_chat_message") or 0)
    set_org(cur, None)

    if enabled > 0:
        ok = img_b == 0 and msg_b == 0
        report.add(
            "child_select",
            ok,
            f"VPD hijas ON: set_org({ORG_A}) image_orgB={img_b} msg_orgB={msg_b} "
            f"(total image={img_all} msg={msg_all})",
        )
        return

    ok = img_b > 0 and msg_b > 0
    report.add(
        "child_select",
        ok,
        f"VPD hijas OFF (esperado): set_org({ORG_A}) todavia ve org {ORG_B} "
        f"(image={img_b} msg={msg_b}; totales image={img_all} msg={msg_all}). "
        f"Gap de aislamiento hasta ENABLE en hijas B.",
    )


def _expire_candidates(cur: oracledb.Cursor, org_id: int) -> list[tuple[int, Any]]:
    set_org(cur, org_id)
    rows = fetch_all(
        cur,
        """
        SELECT id_appointment, payment_expires_at
          FROM appointment
         WHERE payment_status = 'PENDING'
           AND payment_expires_at IS NOT NULL
           AND payment_expires_at < CURRENT_TIMESTAMP
           AND status = 'PENDIENTE'
           AND NVL(pagopar_hash, ' ') NOT IN (:h1, :h2)
        """,
        {"h1": HASH_ORG_A, "h2": HASH_ORG_B},
    )
    return [(int(r[0]), r[1]) for r in rows]


def wait_job_run(cur: oracledb.Cursor, min_log_id: int) -> tuple[str, str]:
    deadline = time.time() + 180
    while time.time() < deadline:
        cur.execute(
            """
            SELECT status, SUBSTR(NVL(additional_info, TO_CHAR(error#)), 1, 500)
              FROM user_scheduler_job_run_details
             WHERE job_name = :job
               AND log_id > :min_id
             ORDER BY log_date DESC
             FETCH FIRST 1 ROW ONLY
            """,
            {"job": JOB_NAME, "min_id": min_log_id},
        )
        row = cur.fetchone()
        if row:
            return str(row[0]), str(row[1] if row[1] is not None else "")
        time.sleep(2)
    return "TIMEOUT", "sin user_scheduler_job_run_details"


def probe_expire_job(cur: oracledb.Cursor, conn: oracledb.Connection, report: ProbeReport) -> None:
    shielded: list[tuple[int, int, Any]] = []
    try:
        for org_id in (ORG_A, ORG_B):
            for app_id, expires_at in _expire_candidates(cur, org_id):
                shielded.append((org_id, app_id, expires_at))
                set_org(cur, org_id)
                cur.execute(
                    """
                    UPDATE appointment
                       SET payment_expires_at = CURRENT_TIMESTAMP + NUMTODSINTERVAL(7, 'DAY')
                     WHERE id_appointment = :id
                    """,
                    {"id": app_id},
                )
        conn.commit()

        created: list[tuple[int, int]] = []
        for org_id, loc_id, pro_id, ser_id, marker_hash in (
            (ORG_A, 1, 1, 4, HASH_ORG_A),
            (ORG_B, 3, 34, 3, HASH_ORG_B),
        ):
            set_org(cur, org_id)
            phone = f"098199{org_id}{int(time.time()) % 100000:05d}"
            existing = fetch_one(
                cur,
                "SELECT id_customer FROM customer WHERE full_name = :n AND org_id_organization = :o FETCH FIRST 1 ROW ONLY",
                {"n": MARKER, "o": org_id},
            )
            if existing:
                cus_id = int(existing)
            else:
                cur.execute(
                    """
                    INSERT INTO customer (org_id_organization, full_name, phone_number, is_active)
                    VALUES (:org, :n, :p, 1)
                    """,
                    {"org": org_id, "n": MARKER, "p": phone},
                )
                cus_id = int(
                    fetch_one(
                        cur,
                        "SELECT id_customer FROM customer WHERE phone_number = :p AND org_id_organization = :o",
                        {"p": phone, "o": org_id},
                    )
                )
            token = secrets.token_hex(32)
            cur.execute(
                """
                INSERT INTO appointment (
                    org_id_organization, loc_id_location, pro_id_professional, ser_id_service,
                    cus_id_customer, start_time, end_time, status, payment_status,
                    payment_expires_at, pagopar_hash, public_manage_token, deposit_amount
                ) VALUES (
                    :org, :loc, :pro, :ser, :cus,
                    SYSTIMESTAMP - NUMTODSINTERVAL(2, 'HOUR'),
                    SYSTIMESTAMP - NUMTODSINTERVAL(1, 'HOUR'),
                    'PENDIENTE', 'PENDING',
                    SYSTIMESTAMP - NUMTODSINTERVAL(30, 'MINUTE'),
                    :h, :tok, 10000
                )
                """,
                {
                    "org": org_id,
                    "loc": loc_id,
                    "pro": pro_id,
                    "ser": ser_id,
                    "cus": cus_id,
                    "h": marker_hash,
                    "tok": token,
                },
            )
            app_id = int(
                fetch_one(
                    cur,
                    "SELECT id_appointment FROM appointment WHERE pagopar_hash = :h",
                    {"h": marker_hash},
                )
            )
            created.append((org_id, app_id))
        conn.commit()
        set_org(cur, None)

        min_log_id = int(
            fetch_one(
                cur,
                "SELECT NVL(MAX(log_id), 0) FROM user_scheduler_job_run_details WHERE job_name = :job",
                {"job": JOB_NAME},
            )
            or 0
        )
        conn.commit()
        cur.execute(
            "BEGIN DBMS_SCHEDULER.RUN_JOB(:job, use_current_session => FALSE); END;",
            {"job": JOB_NAME},
        )
        conn.commit()
        status, info = wait_job_run(cur, min_log_id)
        if status not in ("SUCCEEDED", "SUCCESS"):
            report.add("expire_job", False, f"job {JOB_NAME} status={status} info={info[:400]}")
            return

        expired_ok = True
        seen = []
        for org_id, app_id in created:
            set_org(cur, org_id)
            row = fetch_all(
                cur,
                """
                SELECT status, payment_status, cancel_reason
                  FROM appointment
                 WHERE id_appointment = :id
                """,
                {"id": app_id},
            )
            if not row:
                expired_ok = False
                seen.append(f"org{org_id}:id{app_id}=MISSING")
                continue
            st, pay, reason = row[0]
            seen.append(f"org{org_id}:id{app_id}={st}/{pay}/{reason}")
            if st != "CANCELADO" or pay != "EXPIRED" or reason != "DEPOSIT_EXPIRED":
                expired_ok = False
        set_org(cur, None)
        report.add(
            "expire_job",
            expired_ok,
            f"RUN_JOB BG_JOB_ID procesó orgs {ORG_A} y {ORG_B}: {', '.join(seen)}",
        )
    finally:
        for org_id, app_id, expires_at in shielded:
            try:
                set_org(cur, org_id)
                cur.execute(
                    """
                    UPDATE appointment
                       SET payment_expires_at = :exp
                     WHERE id_appointment = :id
                       AND payment_status = 'PENDING'
                    """,
                    {"exp": expires_at, "id": app_id},
                )
            except Exception:
                pass
        conn.commit()
        set_org(cur, None)


def _read_out_clob(var: Any) -> str:
    val = var.getvalue()
    if val is None:
        return ""
    if hasattr(val, "read"):
        data = val.read()
        return data if isinstance(data, str) else data.decode("utf-8", errors="replace")
    return str(val)


def probe_public_surface(
    cur: oracledb.Cursor,
    report: ProbeReport,
    ords: OrdsClient | None = None,
) -> None:
    """Directorio, hub y fechas publicas. SQL primero; HTTP si hay cliente ORDS."""
    st = cur.var(oracledb.DB_TYPE_NUMBER)
    body = cur.var(oracledb.DB_TYPE_CLOB)
    set_org(cur, None)
    cur.execute(
        """
        BEGIN
            pkg_aox_public_booking_api.pr_search_org_directory(
                pi_query         => NULL,
                pi_specialty     => NULL,
                pi_city_id       => NULL,
                pi_department_id => NULL,
                pi_offset        => 0,
                po_status_code   => :st,
                po_response_body => :body
            );
        END;
        """,
        {"st": st, "body": body},
    )
    status = int(st.getvalue() or 0)
    raw = _read_out_clob(body)
    parsed: Any = None
    try:
        parsed = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        parsed = raw
    slugs: list[str] = []
    if isinstance(parsed, dict):
        items = ((parsed.get("data") or {}) if isinstance(parsed.get("data"), dict) else {}) .get("items") or []
        if isinstance(items, list):
            slugs = [str(i.get("slug")) for i in items if isinstance(i, dict) and i.get("slug")]
    ok_dir = status == 200 and SLUG_A in slugs
    report.add(
        "public_directory_sql",
        ok_dir,
        f"status={status} n={len(slugs)} has_{SLUG_A}={SLUG_A in slugs}",
    )

    cur.execute(
        """
        BEGIN
            pkg_aox_public_booking_api.pr_get_org_hub(
                pi_org_slug      => :slug,
                po_status_code   => :st,
                po_response_body => :body
            );
        END;
        """,
        {"slug": SLUG_A, "st": st, "body": body},
    )
    status_h = int(st.getvalue() or 0)
    raw_h = _read_out_clob(body)
    parsed_h: Any = None
    try:
        parsed_h = json.loads(raw_h) if raw_h else {}
    except json.JSONDecodeError:
        parsed_h = raw_h
    loc_n = 0
    if isinstance(parsed_h, dict):
        data = parsed_h.get("data") if isinstance(parsed_h.get("data"), dict) else parsed_h
        locs = data.get("locations") if isinstance(data, dict) else []
        loc_n = len(locs) if isinstance(locs, list) else 0
    ok_hub = status_h == 200 and loc_n > 0
    report.add(
        "public_hub_sql",
        ok_hub,
        f"status={status_h} locations={loc_n} slug={SLUG_A}",
    )

    if ords is None:
        return

    status_d, payload_d, raw_d = ords.request("GET", f"{PUBLIC_PREFIX}/directory")
    http_slugs: list[str] = []
    if isinstance(payload_d, dict):
        data = payload_d.get("data") or {}
        items = data.get("items") if isinstance(data, dict) else []
        if isinstance(items, list):
            http_slugs = [str(i.get("slug")) for i in items if isinstance(i, dict) and i.get("slug")]
    report.add(
        "public_directory_http",
        status_d == 200 and SLUG_A in http_slugs,
        f"HTTP {status_d} n={len(http_slugs)} has_{SLUG_A}={SLUG_A in http_slugs}",
    )

    status_o, payload_o, raw_o = ords.request("GET", f"{PUBLIC_PREFIX}/org/{SLUG_A}")
    http_locs = 0
    if isinstance(payload_o, dict):
        data = payload_o.get("data") if isinstance(payload_o.get("data"), dict) else payload_o
        locs = data.get("locations") if isinstance(data, dict) else []
        http_locs = len(locs) if isinstance(locs, list) else 0
    report.add(
        "public_hub_http",
        status_o == 200 and http_locs > 0,
        f"HTTP {status_o} locations={http_locs}",
    )

    today = date.today()
    qs = urlencode(
        {
            "pro_id": 1,
            "loc_id": 1,
            "ser_id": 4,
            "from_date": today.isoformat(),
            "to_date": (today + timedelta(days=21)).isoformat(),
        }
    )
    status_dates, payload_dates, _ = ords.request("GET", f"{PUBLIC_PREFIX}/available-dates?{qs}")
    dates = []
    if isinstance(payload_dates, dict):
        dates = payload_dates.get("data") or []
    report.add(
        "public_available_dates_http",
        status_dates == 200 and bool(dates),
        f"HTTP {status_dates} dates={len(dates) if isinstance(dates, list) else 0}",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Probes VPD DEV (ORDS + SQL)")
    parser.add_argument(
        "--only",
        default="all",
        help="all | comma: ords_pool,auth_login,booking_slug_insert,child_select,expire_job,public_surface",
    )
    args = parser.parse_args()
    wanted = {p.strip() for p in args.only.split(",") if p.strip()}
    run_all = "all" in wanted

    report = ProbeReport()
    conn = connect()
    ords = OrdsClient()
    try:
        cur = conn.cursor()
        cur.execute("ALTER SESSION DISABLE PARALLEL DML")
        try:
            cleanup_probe_rows(cur, conn)
        except Exception as exc:
            print(f"WARN cleanup inicial: {exc}", flush=True)
        if run_all or "ords_pool" in wanted:
            try:
                probe_ords_pool(cur, ords, report)
            except Exception as exc:
                report.add("ords_pool", False, f"excepcion: {exc}")
        if run_all or "auth_login" in wanted:
            try:
                probe_auth_login(cur, conn, ords, report)
            except Exception as exc:
                report.add("auth_login", False, f"excepcion: {exc}")
        if run_all or "booking_slug_insert" in wanted:
            try:
                probe_booking_slug(cur, conn, ords, report)
            except Exception as exc:
                report.add("booking_slug_insert", False, f"excepcion: {exc}")
        if run_all or "public_surface" in wanted:
            try:
                probe_public_surface(cur, report, ords)
            except Exception as exc:
                report.add("public_surface", False, f"excepcion: {exc}")
        if run_all or "child_select" in wanted:
            try:
                probe_child_select(cur, conn, report)
            except Exception as exc:
                report.add("child_select", False, f"excepcion: {exc}")
        if run_all or "expire_job" in wanted:
            try:
                probe_expire_job(cur, conn, report)
            except Exception as exc:
                report.add("expire_job", False, f"excepcion: {exc}")
        try:
            cleanup_probe_rows(cur, conn)
        except Exception as exc:
            print(f"WARN cleanup final: {exc}", flush=True)
    finally:
        ords.close()
        conn.close()

    failed = report.failed()
    print("", flush=True)
    print(f"Probes: {len(report.results) - len(failed)}/{len(report.results)} OK", flush=True)
    if failed:
        for item in failed:
            print(f"  FAIL {item.name}: {item.detail}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
