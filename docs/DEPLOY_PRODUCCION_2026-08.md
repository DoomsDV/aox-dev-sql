# Pase a producción — agosto 2026 (objetos de base de datos)

Esquema de producción: `wksp_aox` (ADB **AOX**). Alias ORDS: `bookmate`.
Esquema de desarrollo: `aoxdev` (ADB **AOXDEV**). Alias ORDS: `aoxdev`.

Base URL de la API en producción:

```
https://g9549f707e8ebfa-aox.adb.sa-saopaulo-1.oraclecloudapps.com/ords/bookmate/api/v1/
https://g9549f707e8ebfa-aox.adb.sa-saopaulo-1.oraclecloudapps.com/ords/bookmate/public/v1/
```

Este pase cubre **solo base de datos y ORDS**. El pase del frontend (`bookmate`, `staging` → `main`) queda pendiente.

## Qué se desplegó

Producción venía del baseline `20260617` (el mismo estado que refleja `aox-dev-bk`) y quedó en el HEAD del repo, `20260823`.

| | Antes | Después |
|---|---|---|
| Tablas | 50 (incluye 7 legacy) | 84 |
| Paquetes | 31 | 45 |
| Templates ORDS | 69 | 126 |
| Claves en `APP_PARAMETER` | 51 | 93 |
| Objetos inválidos | 0 | 0 |

Se ejecutaron 103 scripts: 101 de las 102 migraciones del delta `20260709` → `20260822`, más `20260823_billing_enabled_flag.sql` y `20260823_workspace_subscription_ords.sql`. La única excluida a propósito fue `20260711_subscription_recurring_job.sql`.

Bloques funcionales que entraron: suscripción y planes (infraestructura), cobros SIPAP fases A a E, historial de citas y adjuntos, ATC KB, hub público y buscadores, media de perfil, horarios de negocio, cierre de sucursal, hardening de autenticación, outbox transaccional, idempotencia, e-factura SIFEN (infraestructura), inbox y feriados, complementos y odontograma.

## Jobs

Activos en producción:

`HASEL_SYNC_ORG_EMBEDDINGS`, `HASEL_PROCESS_EMBEDDING_OUTBOX`, `HASEL_EXPIRE_PENDING_PAYMENTS`, `HASEL_DISPATCH_PUSH_CAMPAIGNS`, `HASEL_REFUND_SLA_CHECK`, `HASEL_HOLIDAY_REMINDERS`, `JOB_HASEL_MORNING_DIGEST`, `JOB_PROCESS_ATTENDANCE_REMINDERS`, `JOB_PROCESS_ATTENDANCE_TIMEOUTS`.

`HASEL_AGENDA_TEAM_TASK_0` sigue deshabilitado, igual que antes del pase.

`HASEL_SYNC_ORG_EMBEDDINGS` nunca había llegado a producción pese a ser del baseline; se creó en este pase.

## Lo que quedó apagado

El cobro de suscripción **no** está activo. Cinco interruptores lo sostienen:

| Interruptor | Estado | Dónde |
|---|---|---|
| Job de cobro `HASEL_SUBSCRIPTION_BILLING_CYCLE` | no existe | `user_scheduler_jobs` |
| `SUBSCRIPTION_PAGOPAR_PUBLIC_KEY` / `_PRIVATE_KEY` | vacías | `APP_PARAMETER` |
| `BILLING_ENABLED` | `0` | `APP_PARAMETER` |
| `ADDONS_BILLING_LIVE` | `0` | `APP_PARAMETER` |
| Señas SIPAP por organización | sin configurar (tabla vacía) | `ORG_PAYMENT_SETTINGS` |

Las 9 organizaciones existentes quedaron en `FOUNDER`, plan Premium, con `can_write = 1` y el entitlement `DEPOSIT_COLLECTION` activo.

Con `BILLING_ENABLED = 0`, `pkg_aox_subscription_api.pr_ensure_trial_subscription` da de alta las organizaciones **nuevas** también como `FOUNDER` en vez de `TRIAL` de 14 días. Sin ese interruptor, a los 14 días se les bloquearía la escritura y la reserva pública sin tener dónde pagar.

### Sobre `billing_exempt = 0` en los fundadores

Es intencional, no un error del backfill. `20260709_subscription_plans_phase1.sql` los deja exentos y `20260711_premium_price_229k_founder_50.sql` les quita la exención a cambio de **50% de descuento permanente** sobre Premium. No hay riesgo de cobro: `pr_run_billing_cycle` solo toma organizaciones en `ACTIVE` o `PAST_DUE`, y estas están en `FOUNDER`.

## Runbook para encender el cobro

1. Cargar `SUBSCRIPTION_PAGOPAR_PUBLIC_KEY` y `SUBSCRIPTION_PAGOPAR_PRIVATE_KEY` con las credenciales reales de Pagopar plataforma.
2. Probar el checkout de punta a punta antes de tocar nada más.
3. `UPDATE app_parameter SET param_value = '1' WHERE param_key = 'BILLING_ENABLED';` — a partir de ahí las altas nuevas entran en `TRIAL` de 14 días.
4. Ejecutar `20260711_subscription_recurring_job.sql` para crear el job diario de las 03:00 (hora Paraguay).
5. Decidir qué pasa con las 9 organizaciones `FOUNDER`: hoy no entran al ciclo. Para que empiecen a pagar el 50% hay que moverlas a `ACTIVE` con `current_period_end` cargado.
6. En el frontend, mostrar `/panel/plan` y los CTA de cobro.
7. Para complementos, aparte: `ADDONS_BILLING_LIVE = 1`.

## Arreglos hechos durante el pase

Al replayar la cadena completa sobre un esquema que venía del baseline aparecieron defectos que en desarrollo no se notaban porque los objetos ya existían:

- `20260714_push_campaign.sql` y `20260812_inbox_and_holidays.sql`: comillas duplicadas dentro de literales `q'[...]'`, que generaban DDL inválido.
- `20260822_odontogram_catalog_clinical_phase.sql`: ruta relativa `@@tables/` corregida a `@@../tables/`.
- `20260822_odontogram_catalog_ords.sql`: el handler usaba los binds `:auth_header` y `:response_body`, que ORDS no provee. La convención de la casa es `owa_util.get_cgi_env('AUTHORIZATION')` y escribir la respuesta con `htp.prn`. Era el único handler de los 160 con ese patrón; devolvía 401 siempre.
- `20260823_workspace_subscription_ords.sql`: `GET /workspace/subscription` estaba anotado en `20260710_subscription_phase2.sql` como "registrado aparte" y nunca quedó versionado. Ahora sí.

## Smoke ejecutado

Solo lecturas, con un JWT generado en la propia base (`apex_jwt.encode` firmando con `fn_get_parameter('JWT_TOKEN')`).

Respondieron 200: `workspace`, `dashboard`, `dashboard/profitability`, `appointments/calendar`, `customers`, `services`, `professionals`, `locations`, `specialties`, `roles`, `workspace/payments`, `workspace/payments/pending-count`, `workspace/subscription`, `workspace/plans`, `workspace/payment-settings`, `workspace/billing-profile`, `workspace/odontogram/catalog`, `inbox`, `inbox/unread-count`, `closures/motives`, y los públicos `public/v1/org/:slug`, `public/v1/profile/:org_slug/:prof_slug`, `public/v1/profile/resolve/:prof_slug`, `public/v1/user/:slug`.

Dos respuestas que no son 200 y no son defectos del pase:

- `GET /workspace/gallery` devuelve 405 porque el template solo define POST y PUT. La galería se lee por `public/v1/org/:slug`.
- `GET public/v1/profile/:slug` devuelve 555 para cualquier slug. Es la ruta legacy `/p/{slug}`; desarrollo se comporta igual, así que es pre-existente. La ruta canónica es `public/v1/profile/:org_slug/:prof_slug`.

## Drift conocido entre entornos

No hay que intentar "corregirlo": son objetos fuera del repo.

**Solo en desarrollo** (no están en `aox-dev/`): columna `PROFESSIONAL.DELETED_AT`, paquete `PKG_OCI_BRIDGE`, job `JOB_REVOKE_EXPIRED_SESSIONS_JOB`, job `JOB_EXPIRE_PAGOPAR_PAYMENTS` (reemplazado por `HASEL_EXPIRE_PENDING_PAYMENTS`).

**Solo en producción** (legacy anterior a Hasel): tablas `DEPT`, `EMP`, `EMPLEADOS`, `DEPARTAMENTOS`, `DEPARTAMENTOS_ERR$`, `TMP_HASEL_MAINT_PKG_BACKUP`; función `JS_GET_IVA`; módulo MLE y perfiles de traducción SQL. `AOX_LOG_WEBHOOK_META` pasó a versionarse en `aox-dev/` (`20260826_webhook_meta_log.sql`).

Descontando eso, la huella MD5 de columnas por tabla coincide entre ambos entornos en todo el esquema del repo, y los dos tienen 126 templates ORDS.

## Rollback

No hay reversa incremental. La única vuelta atrás es restaurar el backup de la ADB tomado antes de la ventana.
