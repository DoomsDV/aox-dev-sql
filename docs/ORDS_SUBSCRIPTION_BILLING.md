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
      "status": "ACTIVE", "effective_status": "ACTIVE",
      "can_write": 1, "is_founder": 0, "billing_exempt": 0,
      "trial_ends_at": null, "current_period_end": "2026-08-15T...",
      "storage_used_bytes": 0, "storage_limit_bytes": 5368709120,
      "supports_storage_addons": 1, "billing_configured": 1,
      "plan_monthly_amount": 229000,
      "addons_monthly_amount": 30000,
      "monthly_total": 259000,
      "days_remaining_in_period": 12,
      "period_days": 31,
      "account_balance": 15000,
      "pending_plan_code": "BASE",
      "pending_plan_name": "Base",
      "pending_plan_change_at": "2026-08-15T...",
      "active_storage_addons": [{
        "code": "STORAGE_5GB", "quantity": 1, "line_total": 30000,
        "cancel_credit_amount": 11613, "cancelable": 1
      }]
    },
    "plans": [
      { "code": "PREMIUM", "price_amount": 229000, "checkout_price_amount": 229000,
        "monthly_total": 259000, "features": ["..."], "is_current": 1 }
    ],
    "storage_addons": [
      { "code": "STORAGE_5GB", "extra_bytes": 5368709120, "price_amount": 30000,
        "prorate_amount": 11613, "days_remaining": 12, "period_days": 31 }
    ]
  }
}
```

`monthly_total` = precio del plan (con 50% fundador si aplica) + Σ addons ACTIVE.  
Los precios de catálogo (`ref_plan.price_amount`) **no** cambian.

### POST /workspace/subscription/activate  (solo ADMIN)
Cobro con tarjeta catastrada (uPay). Request:
```json
{ "target_type": "PLAN", "plan_code": "PREMIUM" }
{ "target_type": "STORAGE_ADDON", "addon_code": "STORAGE_5GB" }
```

- **PLAN**: cobra el mes del plan.
- **STORAGE_ADDON** mid-cycle: cobra `ceil(precio × días_restantes / días_periodo)` (mín. 1000 Gs si hay días).  
  `period_end` del invoice = `current_period_end` del plan (alineación).  
  Si `days_remaining <= 0`: activa sin cobro mid-cycle (`requires_polling: 0`); entra en la renovación.
- Guarda `sad_id_storage_addon` en la factura (no resolver por monto).

### POST /workspace/subscription/checkout  (solo ADMIN)
Misma lógica que `activate` (cobro recurrente con tarjeta). Preferir `activate` desde el panel.

### Renovación — `pr_run_billing_cycle`
1. Aplica `pending_pln_id_plan` si el periodo venció.  
2. Un cargo **CONSOLIDATED**: `gross = plan (+50% fundador) + Σ addons`;  
   `amount = max(0, gross - account_balance)` (mín. Pagopar 1000 si `0 < net < 1000`).  
3. Si `net = 0`: factura `PAID` con `payment_provider=credit`, sin Pagopar.  
Excluye `billing_exempt` y Base **sin** addons ACTIVE.

### POST /workspace/subscription/change-plan  (solo ADMIN)
- **Downgrade** (p.ej. Premium→Base): agenda `pending_plan_*` = fin de ciclo. Sigue Premium hasta entonces. **Sin crédito de plan.**
- **Cancelar agenda:** `plan_code` = plan actual.
- **Upgrade:** requiere `activate` (pago), salvo `billing_exempt`.

### POST /workspace/subscription/addon/cancel  (solo ADMIN)
Cancela 1 unidad ACTIVE de inmediato, acredita `fn_unused_credit_amount` a `account_balance` (`CANCEL_ADDON` en ledger).  
Request `{ "addon_code": "STORAGE_5GB" }`. Response: `credit_granted`, `account_balance`.

### GET /workspace/subscription/invoice/:hash
Estado de una factura por el hash Pagopar (para la pantalla de retorno del checkout).

### GET /workspace/subscription/invoices
Historial + resumen de facturación de la org. Response `data`:
```json
{
  "next_billing_at": "2026-07-26T...",
  "plan_monthly_amount": 114500,
  "addons_monthly_amount": 0,
  "monthly_total": 114500,
  "account_balance": 10000,
  "next_charge_estimate": 104500,
  "invoices": [
    { "invoice_id": 1, "status": "PAID|FAILED|PENDING|VOID",
      "amount": 1000, "gross_amount": 11000, "credit_applied": 10000,
      "description": "...", "paid_at": "...", "created_at": "..." }
  ]
}
```
`next_billing_at` = `org_subscription.current_period_end` (editable desde APEX para definir desde cuándo se cobra).

### POST /pagopar/subscription/webhook
Marca `PAID`, **consume** `credit_applied` (idempotente vía ledger), y:
- **SUBSCRIPTION** → extiende periodo + limpia pending.
- **STORAGE_ADDON** → alta/incrementa addon por `sad_id_storage_addon`.
FAILED no consume crédito.

### Prueba manual (DEV)
1. Premium + addon → cancelar +5 GB → `account_balance ≈ prorrateo`, storage baja.
2. Agendar Base → `pending_*` set; Premium sigue activo.
3. Forzar `period_end` + `pr_run_billing_cycle` → aplica Base, cargo `gross − credit`.
4. Crédito ≥ factura → PAID sin Pagopar; webhook reenvío idempotente.

## Configuración requerida (DEV/PROD)
1. Cargar `SUBSCRIPTION_PAGOPAR_PUBLIC_KEY` y `SUBSCRIPTION_PAGOPAR_PRIVATE_KEY` en `app_parameter`
   (claves del comercio Pagopar de Hasel). Mientras estén vacías, el checkout responde
   `VALIDATION_ERROR` (“La facturación de suscripción no está configurada”) y el frontend
   muestra el aviso correspondiente.
2. Registrar en el panel de Pagopar la URL de webhook: `.../pagopar/v1/subscription/webhook`.
3. (Opcional) `SUBSCRIPTION_PAYMENT_PENDING_MINUTES` (default 1440) para la vigencia del checkout.
```
