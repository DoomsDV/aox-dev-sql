# Referencia — pase a producción Hasel

## Repos y freeze

| Pieza | Repo (carpeta) | Freeze = ya está en prod | Pendiente |
|-------|----------------|--------------------------|-----------|
| BD / ORDS | `aox-dev/` (`aox-dev-sql`) | tag `prod` | `prod..HEAD` |
| Frontend | `bookmate/` | rama `main` (`hasel.app`) | `main..staging` |

`aox-dev-bk` está eliminado a propósito. No recrearlo.

## Comandos git

```text
# aox-dev
git -C aox-dev fetch --tags
git -C aox-dev log prod..HEAD --oneline
git -C aox-dev diff --stat prod..HEAD -- migrations/ packages/ tables/ ords/ functions/ jobs/ triggers/
git -C aox-dev diff --name-only prod..HEAD

# bookmate
git -C bookmate log main..staging --oneline
git -C bookmate diff --stat main..staging
```

Si no existe el tag `prod`, usar el `prod-YYYYMMDD` más reciente o preguntar al usuario. No inventar el freeze.

Tras un pase **cerrado y confirmado**:

```text
git -C aox-dev tag -a prod-YYYYMMDD -m "Pase a producción YYYY-MM-DD"
git -C aox-dev tag -f prod
```

No pushear tags salvo que el usuario lo pida.

## MCP

- Inventario y deploy BD: `oracle-aox` (`wksp_aox`). Wallet `Wallet_aox`.
- Comparar con DEV: `oracle-aoxdev` (`aoxdev`). No mezclar wallets.
- Preferir `execute_sql` del Toolbox. No scripts Python temporales con password.

Consultas típicas en `wksp_aox`:

```sql
SELECT object_type, object_name
  FROM user_objects
 WHERE status = 'INVALID'
 ORDER BY 1, 2;

SELECT job_name, enabled, state
  FROM user_scheduler_jobs
 ORDER BY job_name;

SELECT param_key, CASE WHEN param_key LIKE '%KEY%' THEN '(oculto)' ELSE param_value END
  FROM app_parameter
 WHERE param_key IN (
   'BILLING_ENABLED', 'ADDONS_BILLING_LIVE',
   'SUBSCRIPTION_PAGOPAR_PUBLIC_KEY', 'SUBSCRIPTION_PAGOPAR_PRIVATE_KEY'
 );
```

## Orden de paquetes (`install_all.sql`)

Núcleo (antes que APIs): `PKG_AOX_UTIL` → `JWT` → `AUTH` → `SUBSCRIPTION_API` → `PAYMENT_SETTINGS_API` → `BILLING_PROFILE_API` → `PAYMENTS_API` → `REFUND_CLAIMS_API` → `REFUND_COMPENSATION_API` → `REFUND_DISPUTES_API` → `BUCKET` → `META_API` → `FCM_API` → `INBOX_API` → `FCM_API` (otra vez) → `PUSH_CAMPAIGN`.

APIs: `AUTH_API` … `CUSTOMER_API` … `PAGOPAR_API` → `SUBSCRIPTION_BILLING_API` → … → `APPOINTMENT_API` → `PUBLIC_BOOKING_API`.

Si el delta toca un paquete de más abajo que depende de uno nuevo de más arriba, recompilar **ambos**, el de arriba primero. Detalle: `aox-dev/install_all.sql` fases 3–5.

## Exclusiones habituales

| Ítem | Por qué |
|------|---------|
| `migrations/20260711_subscription_recurring_job.sql` | Crea el job de cobro de planes. Solo al encender billing. |
| CORS loopback / scripts solo local | No pertenecen a prod. |
| `BILLING_ENABLED=1`, `ADDONS_BILLING_LIVE=1`, keys Pagopar | Kill switches. Runbook en `aox-dev/docs/DEPLOY_PRODUCCION_2026-08.md`. |

## Orden frágil (lección 2026-09)

Un `.pls` en HEAD puede referenciar tablas/paquetes que el tag `prod` aún no tiene. Secuencia obligatoria: **DDL de esas tablas → crear paquete nuevo → recompilar dependientes**. Al revés: `INVALID` y se rompe Cobros / reserva pública.

## Frontend

Misma ventana que el backend si el UI nuevo llama endpoints/ORDS que este pase instala, o si el UI viejo queda incompatible (p. ej. 410 en flujo legacy). Merge `staging` → `main`; no desplegar front contra BD vieja ni al revés si hay acoplamiento.

## Documentos previos (contexto, no copiar ciego)

- `aox-dev/docs/DEPLOY_PRODUCCION_2026-08.md` — primer gran pase y kill switches.
- `.cursor/plans/pase_a_producción_cobros,_disputas_y_e-factura_1768a990.plan.md` — ejemplo de inventario + orden.
