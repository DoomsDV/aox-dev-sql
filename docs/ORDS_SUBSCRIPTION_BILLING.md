# ORDS — Facturación de suscripción (Fase 5)

Endpoints comerciales del roadmap **Premium + Planes + Historial**. La facturación de
plan/addons usa las claves Pagopar **de la plataforma Hasel** (parámetros
`SUBSCRIPTION_PAGOPAR_PUBLIC_KEY` / `SUBSCRIPTION_PAGOPAR_PRIVATE_KEY`), separadas de
las claves por-organización que se usan para las señas de citas.

## Endpoints

| Método | Ruta ORDS | Módulo | Procedimiento |
|--------|-----------|--------|----------------|
| GET  | `/api/v1/workspace/plans` | `hasel` | `pkg_aox_subscription_billing_api.pr_get_plans` |
| POST | `/api/v1/workspace/subscription/checkout` | `hasel` | `pkg_aox_subscription_billing_api.pr_create_checkout` |
| POST | `/api/v1/workspace/subscription/change-plan` | `hasel` | `pkg_aox_subscription_billing_api.pr_change_plan` |
| GET  | `/api/v1/workspace/subscription/invoice/:hash` | `hasel` | `pkg_aox_subscription_billing_api.pr_get_invoice_by_hash` |
| POST | `/pagopar/v1/subscription/webhook` | `pagopar` | `pkg_aox_subscription_billing_api.pr_subscription_webhook` |

Registro reproducible: `migrations/20260710_subscription_billing_ords.sql`
(`ords.define_template` + `ords.define_handler`, bind de estado `:status`, cuerpo `:body_text`).

## Contratos

### GET /workspace/plans
```json
{
  "status": "success",
  "data": {
    "current": {
      "plan_code": "PREMIUM", "plan_name": "Premium",
      "status": "TRIAL", "effective_status": "TRIAL",
      "can_write": 1, "is_founder": 0, "billing_exempt": 0,
      "trial_ends_at": "2026-07-24T...", "current_period_end": null, "grace_ends_at": null,
      "storage_used_bytes": 0, "storage_limit_bytes": 5368709120,
      "supports_storage_addons": 1, "billing_configured": 0
    },
    "plans": [ { "code": "BASE", "price_amount": 99000, "features": ["..."], "is_current": 0 } ],
    "storage_addons": [ { "code": "STORAGE_5GB", "extra_bytes": 5368709120, "price_amount": 30000 } ]
  }
}
```

### POST /workspace/subscription/checkout  (solo ADMIN)
Request:
```json
{ "target_type": "PLAN", "plan_code": "PREMIUM", "forma_pago": 9 }
{ "target_type": "STORAGE_ADDON", "addon_code": "STORAGE_5GB", "forma_pago": 24 }
```
`forma_pago`: 9 = tarjeta (Bancard), 24 = QR. Response `data`: `{ hash, checkout_url, invoice_id, amount, currency, target_type, forma_pago }`.
Crea `org_subscription_invoice` en estado `PENDING` y una orden Pagopar (`id_pedido_comercio = SUB-<invoice_id>`).

### POST /workspace/subscription/change-plan  (solo ADMIN)
Cambio **sin pago**. Solo permitido a `is_founder`/`billing_exempt`; el resto recibe 403
(“necesitás completar el pago”). Request `{ "plan_code": "BASE" }`.

### GET /workspace/subscription/invoice/:hash
Estado de una factura por el hash Pagopar (para la pantalla de retorno del checkout).

### POST /pagopar/subscription/webhook
Notificación de Pagopar. Valida el token `sha1(private_key || hash_pedido)`, marca la
factura `PAID` e:
- **SUBSCRIPTION** → activa `org_subscription` (`ACTIVE`, período del mes, recalcula storage).
- **STORAGE_ADDON** → alta/incrementa `org_storage_addon` (ACTIVE) y recalcula `storage_limit_bytes`.
Responde con el `echo` del `resultado` que Pagopar espera. Idempotente (si ya está `PAID`, sólo hace echo).

## Configuración requerida (DEV/PROD)
1. Cargar `SUBSCRIPTION_PAGOPAR_PUBLIC_KEY` y `SUBSCRIPTION_PAGOPAR_PRIVATE_KEY` en `app_parameter`
   (claves del comercio Pagopar de Hasel). Mientras estén vacías, el checkout responde
   `VALIDATION_ERROR` (“La facturación de suscripción no está configurada”) y el frontend
   muestra el aviso correspondiente.
2. Registrar en el panel de Pagopar la URL de webhook: `.../pagopar/v1/subscription/webhook`.
3. (Opcional) `SUBSCRIPTION_PAYMENT_PENDING_MINUTES` (default 1440) para la vigencia del checkout.
```
