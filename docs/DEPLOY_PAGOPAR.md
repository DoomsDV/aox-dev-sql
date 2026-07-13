## Deploy: Pagopar (solo suscripción Hasel)

> **Checklist maestro de producción:**  
> [DEPLOY_PRODUCTION_CHECKLIST.md](./DEPLOY_PRODUCTION_CHECKLIST.md)

### Estado (Fase E — julio 2026)

**Pagopar ya no se usa para señas de citas.** Las señas del comercio van por **transferencia SIPAP** (`Ajustes → Pagos`, menú **Cobros**, OCR de comprobante).

Pagopar queda **solo** para facturación de la plataforma Hasel (planes / add-ons de storage).

| Flujo | Canal | Package |
|-------|--------|---------|
| Señas de citas | SIPAP / transferencia | `PKG_AOX_PAYMENTS_API`, `PKG_AOX_PAYMENT_SETTINGS_API`, `PKG_AOX_PUBLIC_BOOKING_API` |
| Suscripción Hasel | Pagopar (claves plataforma) | `PKG_AOX_SUBSCRIPTION_BILLING_API` |

### Endpoints Pagopar de señas (deprecados → HTTP 410)

Estos handlers pueden seguir registrados en ORDS, pero el PL/SQL responde **410 Gone**:

- `POST /public/payments` → `PKG_AOX_PAGOPAR_API.PR_CREATE_PAYMENT_ORDER`
- `GET /public/payments/:hash` → `PKG_AOX_PAGOPAR_API.PR_GET_PAYMENT_BY_HASH`
- `POST /pagopar/respuesta` → `PKG_AOX_PAGOPAR_API.PR_WEBHOOK_NOTIFICATION`
- `GET/PUT/DELETE /org-integrations/pagopar` → `PKG_AOX_ORG_INTEGRATION_API` (rechaza provider `pagopar`)

Migración: `aox-dev/migrations/20260710_deprecate_pagopar_deposits_phase_e.sql`

### Pagopar suscripción (activo — no tocar en cleanup de señas)

Ver [ORDS_SUBSCRIPTION_BILLING.md](./ORDS_SUBSCRIPTION_BILLING.md):

- `POST /api/v1/workspace/subscription/checkout`
- `POST /pagopar/v1/subscription/webhook`
- Parámetros: `SUBSCRIPTION_PAGOPAR_PUBLIC_KEY` / `SUBSCRIPTION_PAGOPAR_PRIVATE_KEY`
- Util compartido: `pkg_aox_pagopar_api.fn_pagopar_sha1_token`

### Suscripción con pago recurrente (uPay, catastro de tarjeta) — julio 2026

Modelo **solo recurrente**: para suscribirse hay que **catastrar una tarjeta** (proveedor uPay, API `pago-recurrente/3.0`) y el cobro mensual es **automático** (job). Se eliminó el redirect manual a `pagopar.com/pagos`.

Migraciones (aplicar en orden):
1. `migrations/20260711_subscription_recurring.sql` — tabla `org_payment_card`, columnas nuevas en `org_subscription` (`auto_renew`, `last_charge_at`, `charge_retry_count`), seeds de `app_parameter` (`PAGOPAR_RECURRENTE_BASE_URL`, `PAGOPAR_UPAY_IFRAME_URL`, `PAGOPAR_UPAY_RETURN_URL`, `SUBSCRIPTION_CARD_PROVIDER`, `SUBSCRIPTION_MAX_CHARGE_RETRIES`) y recompilación de `PKG_AOX_PAGOPAR_API` + `PKG_AOX_SUBSCRIPTION_BILLING_API`.
2. `migrations/20260711_subscription_recurring_ords.sql` — handlers ORDS (módulo `hasel`):
   - `POST   /api/v1/workspace/subscription/card/add`     → `pr_add_card`
   - `POST   /api/v1/workspace/subscription/card/confirm` → `pr_confirm_card`
   - `GET    /api/v1/workspace/subscription/cards`         → `pr_list_cards`
   - `DELETE /api/v1/workspace/subscription/card/:id`      → `pr_delete_card`
   - `POST   /api/v1/workspace/subscription/activate`      → `pr_activate_subscription`
   - Webhook reutilizado: `POST /pagopar/v1/subscription/webhook` (el `pagar` dispara la misma notificación).
3. `migrations/20260711_subscription_recurring_job.sql` — **SOLO PRODUCCIÓN**. Job `HASEL_SUBSCRIPTION_BILLING_CYCLE` (diario 03:00 America/Asunción) → `pr_run_billing_cycle` (cobro + dunning). NO ejecutar en DEV.

**Prerrequisito Pagopar:** solicitar a `administracion@pagopar.com` habilitar `pago-recurrente/3.0` para HASEL (RUC 6038964-8) en dev y prod. Sin la habilitación, `agregar-cliente`/`listar-tarjeta` devuelven `El comercio no tiene permisos. CF`. El token de estos endpoints es `sha1(private_key + "PAGO-RECURRENTE")` (distinto del de `iniciar-transaccion`). El `url` de `agregar-tarjeta` debe ser el dominio HTTPS donde se incrusta el iframe (`PAGOPAR_UPAY_RETURN_URL`).

### Job de expiración de holds

`HASEL_EXPIRE_PENDING_PAYMENTS` (cada 2 min) → `PKG_AOX_PAYMENTS_API.PR_EXPIRE_PENDING_PAYMENTS`  
(expira holds SIPAP con `payment_expires_at` vencido; también limpia legacy Pagopar si quedara alguno).

### Frontend

- Reserva pública: solo SIPAP (`public-deposit-sipap`, código `HASEL-*`).
- Ajustes → **Pagos** (no Integraciones Pagopar).
- Panel → **Cobros**.
- Plan / checkout Pagopar: solo en `/panel/plan` (suscripción).
- `/reserva-exitosa/[hash]`: página legacy 410 (post-checkout Pagopar de señas).

### Histórico

La integración original de señas Pagopar está documentada en `integracion-pagopar.md` (obsoleta para producto). DDL histórico: `migrations/20260526_pagopar_deposit_integration.sql`.
