---
name: pase-produccion-hasel
description: Inventaria el delta entre el freeze de producción (tag prod en aox-dev-sql, rama main en bookmate) y desarrollo, y genera un plan paso a paso de pase a wksp_aox / hasel.app. Usar cuando el usuario pide pase a producción, deploy a prod, qué hay que llevar a producción, inventario vs prod, o un plan de despliegue Hasel.
---

# Pase a producción Hasel

Cuando el usuario pida un pase a prod, **no improvisar**. Armar un plan con el delta real git + MCP. Plantilla: [plan-template.md](plan-template.md). Detalle de comandos y SQL: [reference.md](reference.md).

## Qué hacer

1. Leer [reference.md](reference.md).
2. Inventario **solo lectura** (git + MCP `oracle-aox`). No aplicar DDL/DML en producción hasta que el usuario apruebe el plan.
3. Escribir el plan en `.cursor/plans/pase_produccion_YYYY-MM-DD.md` usando la plantilla. Preferir Plan mode si el pase es grande.
4. Presentar al usuario: qué se lleva, qué se excluye, orden, riesgos. Esperar confirmación antes de tocar `wksp_aox`.

## Inventario

En `aox-dev/` (repo `aox-dev-sql`):

- Freeze = tag `prod`. Si falta, el `prod-YYYYMMDD` más nuevo, o preguntar.
- `git log prod..HEAD --oneline`
- `git diff --name-only prod..HEAD` clasificado en: `migrations/`, `packages/`, `tables/`, `ords/`, `functions/`, `jobs/`, `triggers/`.

En `bookmate/`: `git log main..staging --oneline` (front). `main` = `hasel.app`.

Cruzar con MCP `oracle-aox`: objetos `INVALID`, jobs, y si hace falta existencia de tablas/paquetes que el delta asume. No usar `oracle-aoxdev` como destino de prod.

Si `prod..HEAD` está vacío y `main..staging` también: decir que no hay nada pendiente. No inventar trabajo.

## Armar el plan

- Migraciones **por fecha de nombre de archivo**. Excluir cobro de planes y solo-DEV (ver reference).
- Paquetes en orden de `aox-dev/install_all.sql`. DDL **antes** de recompilar `.pls` que dependen de objetos nuevos.
- ORDS: templates/handlers nuevos o cambiados en el diff.
- Frontend: misma ventana si hay acoplamiento API/UI.
- Kill switches de billing: listarlos como “no tocar” salvo pedido explícito.

## Después de un pase cerrado

Solo si el usuario confirma que prod quedó al día:

1. `git tag -a prod-YYYYMMDD` y `git tag -f prod` en el commit de `aox-dev` desplegado.
2. No pushear tags ni mergear `staging` → `main` sin pedido explícito.
3. No recrear `aox-dev-bk`.
