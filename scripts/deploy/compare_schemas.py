"""Compara un esquema contra aoxdevelop (DEV): objetos, INVALID, columnas, codigo
fuente (normalizando el nombre de esquema), handlers ORDS, politicas VPD, grants y jobs.

Solo lectura. Credenciales desde ~/.claude.json (mcpServers) y, para hasel_admin,
desde AOX_ADMIN_ENV (default ~/.config/aox_rehearsal.env); nunca se imprimen.
Cada base se lee en un proceso aparte (el modo thick fija el wallet por proceso):

  python compare_schemas.py dump aoxdev AOXDEV dev_saas.json
  python compare_schemas.py dump aox_clone WKSP_AOX clon_saas.json
  python compare_schemas.py dump hasel_admin AOXDEV dev_admin.json
  python compare_schemas.py dump aox_clone WKSP_AOX clon_admin.json hasel_admin HASEL_ADMIN_PASSWORD
  python compare_schemas.py diff dev_saas.json clon_saas.json

Requiere python-oracledb (p. ej. el venv de aoxdev-mcp) y LD_LIBRARY_PATH al Instant Client.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

import oracledb

IC = os.path.expanduser("~/.local/opt/instantclient_23_26")

cfg = json.load(open(os.path.expanduser("~/.claude.json")))["mcpServers"]


def env_file(key):
    path = os.path.expanduser(os.environ.get("AOX_ADMIN_ENV", "~/.config/aox_rehearsal.env"))
    return subprocess.run(["bash", "-c", f'source "$0"; printf %s "${key}"', path],
                          check=True, capture_output=True, text=True).stdout


def connect(server, user=None, password=None):
    env = cfg[server]["env"]
    wallet = env["ORACLE_WALLET_DIR"]
    os.environ["TNS_ADMIN"] = wallet
    kw = dict(user=user or env["ORACLE_USER"],
              password=password or env["ORACLE_PASSWORD"],
              dsn=env["ORACLE_TNS_ALIAS"], config_dir=wallet)
    if env.get("ORACLE_THICK", "").lower() == "true":
        oracledb.init_oracle_client(lib_dir=IC, config_dir=wallet)
    else:  # igual que el MCP: thin con wallet PEM
        kw.update(wallet_location=wallet, wallet_password=env.get("ORACLE_WALLET_PASSWORD"))
    return oracledb.connect(**kw)


def rows(conn, sql):
    cur = conn.cursor()
    cur.execute(sql)
    out = []
    for r in cur:
        out.append(tuple(x.read() if hasattr(x, "read") else x for x in r))
    return out


def norm(text, schema):
    t = re.sub(schema, "@S", text or "", flags=re.I)
    return "\n".join(l.rstrip() for l in t.splitlines()).strip()


def h(text):
    return hashlib.md5(text.encode()).hexdigest()[:10]


IGNORE_OBJ = re.compile(r"^(SYS_|ISEQ\$\$|BIN\$|DR\$|VECTOR\$|SEQ_)")


def snapshot(conn, schema):
    snap = {}
    snap["objects"] = {
        f"{t}:{n}"
        for t, n in rows(conn, "select object_type, object_name from user_objects "
                               "where object_type in ('TABLE','VIEW','PACKAGE','FUNCTION','PROCEDURE',"
                               "'TRIGGER','TYPE','JOB','SEQUENCE')")
        if not IGNORE_OBJ.match(n)
    }
    snap["invalid"] = {f"{t}:{n}" for t, n in rows(conn, "select object_type, object_name from user_objects where status='INVALID'")}
    cols = {}
    for t, c, dt, ln, nl in rows(conn, "select table_name, column_name, data_type, data_length, nullable "
                                       "from user_tab_columns where table_name in (select table_name from user_tables)"):
        if IGNORE_OBJ.match(t):
            continue
        cols.setdefault(t, set()).add(f"{c} {dt}({ln}) {nl}")
    snap["columns"] = cols
    src = {}
    for n, t, line, text in rows(conn, "select name, type, line, text from user_source "
                                       "where type in ('PACKAGE','PACKAGE BODY','FUNCTION','TRIGGER','PROCEDURE') order by name, type, line"):
        src.setdefault(f"{t}:{n}", []).append(text)
    snap["source"] = {k: h(norm("".join(v), schema)) for k, v in src.items()}
    snap["ords"] = {
        f"{m} {u} {meth}": h(norm(s, schema))
        for m, u, meth, s in rows(conn, "select m.name, t.uri_template, h.method, h.source from user_ords_handlers h "
                                        "join user_ords_templates t on t.id = h.template_id "
                                        "join user_ords_modules m on m.id = t.module_id")
    }
    snap["policies"] = {f"{o}:{e}" for o, e in rows(conn, "select object_name, enable from user_policies")}
    snap["grants_made"] = {f"{g}:{t}:{p}" for g, t, p in rows(conn, "select grantee, table_name, privilege from user_tab_privs_made where grantee <> 'PUBLIC'")}
    snap["jobs"] = {n for (n,) in rows(conn, "select job_name from user_scheduler_jobs")}
    return snap


def diff_sets(title, a, b, la, lb):
    only_a, only_b = sorted(a - b), sorted(b - a)
    print(f"\n## {title}: {la}={len(a)} {lb}={len(b)}  solo {la}: {len(only_a)}  solo {lb}: {len(only_b)}")
    for x in only_a:
        print(f"   - solo {la}: {x}")
    for x in only_b:
        print(f"   + solo {lb}: {x}")


def diff_maps(title, a, b, la, lb):
    keys = set(a) & set(b)
    changed = sorted(k for k in keys if a[k] != b[k])
    print(f"\n## {title}: comunes={len(keys)} distintos={len(changed)}  solo {la}={len(set(a) - set(b))}  solo {lb}={len(set(b) - set(a))}")
    for k in changed:
        print(f"   ~ {k}")
    for k in sorted(set(a) - set(b)):
        print(f"   - solo {la}: {k}")
    for k in sorted(set(b) - set(a)):
        print(f"   + solo {lb}: {k}")


def dump(server, schema, out, user=None, pw_key=None):
    pw = env_file(pw_key) if pw_key else None
    snap = snapshot(connect(server, user, pw), schema)
    ser = {k: (sorted(v) if isinstance(v, set) else
               {kk: sorted(vv) if isinstance(vv, set) else vv for kk, vv in v.items()})
           for k, v in snap.items()}
    json.dump(ser, open(out, "w"))


def compare(fa, fb):
    a, b = json.load(open(fa)), json.load(open(fb))
    la, lb = "DEV", "CLON"
    S = lambda x: set(x)
    diff_sets("Objetos", S(a["objects"]), S(b["objects"]), la, lb)
    diff_sets("INVALID", S(a["invalid"]), S(b["invalid"]), la, lb)
    ca = {f"{t}.{c}" for t, cs in a["columns"].items() for c in cs}
    cb = {f"{t}.{c}" for t, cs in b["columns"].items() for c in cs}
    diff_sets("Columnas (tabla.columna tipo nullable)", ca, cb, la, lb)
    diff_maps("Codigo fuente (normalizado)", a["source"], b["source"], la, lb)
    diff_maps("Handlers ORDS (codigo completo)", a["ords"], b["ords"], la, lb)
    diff_sets("Politicas VPD (tabla:enabled)", S(a["policies"]), S(b["policies"]), la, lb)
    diff_sets("Grants otorgados", S(a["grants_made"]), S(b["grants_made"]), la, lb)
    diff_sets("Jobs", S(a["jobs"]), S(b["jobs"]), la, lb)


def main():
    if sys.argv[1] == "dump":
        # dump <server> <schema> <out> [user pw_key]
        dump(sys.argv[2], sys.argv[3], sys.argv[4], *sys.argv[5:7])
    else:
        compare(sys.argv[2], sys.argv[3])


if __name__ == "__main__":
    main()
