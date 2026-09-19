# Plantilla de plan — pase a producción Hasel

Guardar en `.cursor/plans/pase_produccion_YYYY-MM-DD.md` (workspace bookmate). Frontmatter Cursor:

```yaml
---
name: "Pase a producción YYYY-MM-DD"
overview: Delta tag prod → HEAD (aox-dev-sql) y/o main → staging (bookmate). No encender cobro de planes.
todos:
  - id: inventory
    content: Cerrar inventario git + MCP (prod vs repo)
    status: pending
  - id: ddl
    content: Aplicar migraciones pendientes en orden de fecha (excluir las marcadas)
    status: pending
  - id: packages
    content: Recompilar paquetes tocados en orden de install_all.sql
    status: pending
  - id: validate
    content: 0 INVALID, ORDS, jobs; smoke de los flujos tocados
    status: pending
  - id: frontend
    content: Merge staging → main en la misma ventana si el front depende del back
    status: pending
  - id: freeze
    content: Tras cierre, tag prod-YYYYMMDD y git tag -f prod
    status: pending
isProject: false
---
```

## 1. Freeze

- Tag `prod` (SHA):
- Tag histórico anterior:
- HEAD `aox-dev`:
- `bookmate` `main` vs `staging`:

## 2. Backend — qué llevar (`prod..HEAD`)

### Commits
- (pegar `git log prod..HEAD --oneline`)

### Migraciones (orden de fecha)
| # | Script | Acción |
|---|--------|--------|
| 1 | `migrations/YYYYMMDD_….sql` | aplicar / excluir (motivo) |

### Paquetes a recompilar (orden `install_all.sql`)
1. …

### Tablas / jobs / parámetros
- …

### ORDS
- templates nuevos o handlers cambiados:

## 3. Exclusiones (no aplicar)

- `20260711_subscription_recurring_job.sql` (cobro de planes)
- Conveniencias solo DEV
- Encender `BILLING_ENABLED` / `ADDONS_BILLING_LIVE` / keys Pagopar

## 4. Orden de ejecución

1. Backup ADB producción (antes de DDL).
2. Prerrequisitos manuales (APEX Static IDs, URLs, tokens).
3. DDL/migraciones en orden de fecha. **Nunca** recompilar un `.pls` que referencia objetos nuevos antes de ese DDL.
4. Paquetes (núcleo → APIs → IA según `install_all.sql`).
5. `DBMS_UTILITY.compile_schema(USER, compile_all => FALSE)`.
6. Validar: 0 `INVALID`; conteo ORDS; jobs esperados.
7. Smoke de los flujos tocados (JWT en prod, MCP `oracle-aox` o HTTP).
8. Frontend: `staging` → `main` si aplica, misma ventana.
9. Cerrar freeze: `git tag prod-YYYYMMDD` y `git tag -f prod`.

## 5. Riesgos / dependencias de orden

- Si el repo ya referencia tablas/paquetes que prod aún no tiene, recompilar antes del DDL deja objetos `INVALID` y puede romper Cobros/reserva pública.

## 6. Frontend — qué llevar (`main..staging`)

- Commits:
- Superficies (rutas/API) que deben coincidir con el backend de este pase:
