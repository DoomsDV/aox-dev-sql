# QA staging — complementos (módulo) + almacenamiento (storage add-ons)

Runbook para un agente con acceso a:

- Frontend: `bookmate/` (rama de staging)
- Backend SQL: `aox-dev/`
- Base **aoxdev** (Oracle ADB, esquema `aoxdev`)
- UI: `https://staging.hasel.app`

Continúa a `docs/QA_SUSCRIPCION_HAPPY_PATH_STAGING.md` (ya probado: alta de plan, cobro automático, FE+correo, cancelar, bajar de plan). **Este** pase cubre lo que quedó fuera de alcance ahí: **complementos de módulo** (Odontograma 3D, Cuerpo/BODY_MAP) y **paquetes de almacenamiento** (storage add-ons, solo Premium).

---

## 0. Cómo está armado (no improvisar)

### Dos sistemas distintos, no confundir

| | **Complementos (módulo)** | **Almacenamiento (storage)** |
|---|---|---|
| UI | `/panel/complementos` | `/panel/plan` → sección "Almacenamiento adicional" |
| Tabla catálogo | `ref_addon` | `ref_storage_addon` |
| Tabla org | `org_addon` (1 fila por org+addon, `UNIQUE(org_id,rad_id_addon)`) | `org_storage_addon` (permite `quantity` > 1) |
| Estado org | `status` ACTIVE\|CANCELED\|EXPIRED + `grant_type` PREVIEW\|PAID | `status` ACTIVE\|CANCELED\|EXPIRED (sin grant_type) |
| Flag que gatea el cobro | **`ADDONS_BILLING_LIVE`** (app_parameter, **global**, no por org) | Ninguno — storage **siempre** cobra si `v_gross > 0` |
| Requiere plan Premium | No (elegibilidad es por **rubro**, no por plan) | **Sí**, feature `APPOINTMENT_HISTORY` (solo Premium `id_plan=2`) |
| Procedimiento de cobro | `pr_charge_target(pi_target_type='MODULE_ADDON')` — **falla si `ADDONS_BILLING_LIVE=0`** | `pr_charge_target(pi_target_type='STORAGE_ADDON')` — cobra siempre |
| Endpoint real que usa la UI | `POST /api/v1/workspace/addons` (`pkg_aox_addon_api.pr_activate_module_addon`) | `POST /api/v1/workspace/subscription/activate` con `{"target_type":"STORAGE_ADDON",...}` (`pr_activate_subscription`) |
| Cancelar | `POST /api/v1/workspace/addons/cancel` (`pr_cancel_module_addon`) | `POST /api/v1/workspace/subscription/addon/cancel` (`pr_cancel_storage_addon`) |

⚠️ **`ADDONS_BILLING_LIVE` es un flag GLOBAL de `app_parameter`, no scoped por org** (a diferencia del acelerador de ciclo `pr_run_billing_cycle_for_org`, que sí valida `org_id`). Mientras esté en `1`, **cualquier** organización de `aoxdev` que intente activar un complemento de módulo pasará por el cobro real (Pagopar) en vez del modo preview gratuito. `aoxdev` es una base compartida de desarrollo: **prender→probar→apagar lo más rápido posible**, e idealmente avisar antes de tocarlo si alguien más puede estar probando algo de complementos en paralelo.

### Catálogo real vigente (verificado en `aoxdev`, no en seeds viejos)

**Complementos (`ref_addon`):**

| code | name | price_amount | feature_code | rubros elegibles (`ref_addon_specialty`) |
|---|---|---|---|---|
| `ODONTOGRAM_3D` | Odontograma 3D | **69.000** Gs/mes | `ODONTOGRAM_3D` | `HEALTH` (4) + `DENTAL` (13) |
| `BODY_MAP` | Cuerpo | **59.000** Gs/mes | `BODY_MAP` | `HEALTH` (4) + `PHYSIO_REHAB` (6) |

**Almacenamiento (`ref_storage_addon`):**

| code | name | extra_bytes | price_amount |
|---|---|---|---|
| `STORAGE_5GB` | +5 GB de almacenamiento | 5.368.709.120 (5 GB) | **15.000** Gs/mes |
| `STORAGE_15GB` | +15 GB de almacenamiento | 16.106.127.360 (15 GB) | **35.000** Gs/mes |

Storage base por plan (`ref_plan.storage_limit_bytes`): Base (`id_plan=1`) = 1 GB; Premium (`id_plan=2`) = 5 GB.

### Fixture — estado que deja `qa_billing_e2e_seed.sql`

- Org **29** (`QA Billing E2E`), rubro **HEALTH** (`organization_specialty` → `org_specialty.id=4`) → elegible para **ambos** complementos.
- `org_addon`: **ODONTOGRAM_3D** en `ACTIVE`/`PREVIEW`; **BODY_MAP** en `ACTIVE`/`PAID` con una factura `MODULE_ADDON` `PAID` simulada con FE **0260** (para poder probar cancelación con NCE sin depender del firmador real).
- `org_storage_addon`: el seed **no** inserta nada (empieza limpio).
- Plan: Premium `ACTIVE` (cumple el requisito de storage add-ons).
- Si vas a correr esto después del pase anterior (suscripción), **re-ejecutar el seed primero** (es idempotente) para volver a este estado conocido, sin importar en qué quedó la org (Base, READ_ONLY, etc. del pase anterior).

### Script QA ya validado (referencia, no "caja negra")

`scripts/qa_billing_e2e_modules.sql` ya ejercita el flujo completo end-to-end con asserts (`DBMS_OUTPUT`, sube `ADDONS_BILLING_LIVE=1` y lo restaura a `0` **siempre**, incluso en `EXCEPTION`). Corre solo, sin BILLING_ENABLED, y valida:

1. `GET /workspace/addons` (via `pr_list_addons`) — prorrateo, días restantes, `cancel_refund_type` por ítem.
2. Cancelar el `PREVIEW` (Odontograma) → sin crédito.
3. Activar con `account_balance=500.000` → cubierto 100% por saldo → `PAID` sin Pagopar.
4. Activar + webhook Pagopar mockeado (hash + token real, `pagado:true`) → `PENDING` → `PAID`.
5. Cancelar el `PAID` (Cuerpo, con FE 0260 del seed) → **NCE** (no crédito).
6. Ciclo de renovación (`pr_run_billing_cycle_for_org`) con ambos en `PREVIEW` y saldo suficiente → los dos pasan a `PAID`.

Este documento reproduce esos mismos 6 casos pero **vía UI donde es razonable** (para validar el front, no solo el backend), y agrega el flujo de **storage** que el script de módulos no cubre.

---

## 1. Prohibido / cuidado

| Acción | Por qué |
|---|---|
| Dejar `ADDONS_BILLING_LIVE=1` sin acotar la ventana | Afecta **toda** `aoxdev`, no solo la fixture. Restaurar a `0` apenas termines cada caso con cobro real. |
| `UPDATE app_parameter SET param_value='1' WHERE param_key='BILLING_ENABLED'` | Fuera de alcance de este pase; prende cobro global de **todas** las orgs. |
| Tocar `organization`/`org_subscription`/`org_addon` de **org_id=1** | Consultorio General (real). |
| Inventar un PAN de tarjeta | Igual que en el pase de suscripción: usar la tarjeta de prueba real de Pagopar para el comercio HASEL, o reusar la tarjeta ya catastrada de la sesión anterior en la fixture. |
| Downgradear la org a Base para "probar" que storage da 403 | No hace falta arriesgar el estado de la fixture; el chequeo de plan está en el código (`fn_org_has_feature(..., 'APPOINTMENT_HISTORY')`), alcanza con confirmarlo por lectura, no por ensayo-error en la fixture Premium. |
| Correr `qa_billing_e2e_cleanup.sql` a mitad de este pase | Borra la org 29 entera. |

---

## 2. Preflight (solo lectura)

```sql
SELECT param_key, param_value
  FROM app_parameter
 WHERE param_key IN ('ADDONS_BILLING_LIVE', 'BILLING_ENABLED', 'QA_BILLING_E2E_ORG_ID')
 ORDER BY param_key;

SELECT s.org_id_organization, p.code AS plan_code, s.status, s.account_balance
  FROM org_subscription s
  JOIN ref_plan p ON p.id_plan = s.pln_id_plan
 WHERE s.org_id_organization = 29;

SELECT oa.rad_id_addon, ra.code, oa.status, oa.grant_type, oa.price_snapshot_amount
  FROM org_addon oa JOIN ref_addon ra ON ra.id_addon = oa.rad_id_addon
 WHERE oa.org_id_organization = 29;

SELECT osa.sad_id_storage_addon, rsa.code, osa.status, osa.quantity
  FROM org_storage_addon osa JOIN ref_storage_addon rsa ON rsa.id_storage_addon = osa.sad_id_storage_addon
 WHERE osa.org_id_organization = 29;
```

**Abortar si:** `ADDONS_BILLING_LIVE <> 0` (alguien lo dejó prendido — no es tuyo el problema, avisar antes de seguir) o `BILLING_ENABLED <> 0`.

Si `org_addon` no tiene las 2 filas esperadas (o el plan no es Premium ACTIVE), correr el reset de la sección 3 antes de continuar.

---

## 3. Reset al estado conocido de la fixture

```sql
ALTER SESSION DISABLE PARALLEL DML;
@@scripts/qa_billing_e2e_seed.sql
```

Es idempotente: reordena la org 29 a Premium `ACTIVE`, rubro HEALTH, Odontograma `PREVIEW`, Cuerpo `PAID` con FE 0260 simulada, sin storage add-ons. No importa en qué quedó la org por el pase de suscripción.

Si además querés partir con storage completamente limpio (por si quedó algo de una corrida anterior de este mismo pase):

```sql
DELETE FROM org_storage_addon WHERE org_id_organization = 29;
COMMIT;
```

---

## 4. Caso A — Complementos de módulo (`/panel/complementos`)

### A1. Ver catálogo (UI, sin tocar flags)

1. Login `mike.sdk83@gmail.com`, org **QA Billing E2E**.
2. Ir a `/panel/complementos`.
3. Tab **Mis módulos**: debe verse **Odontograma 3D** con badge tipo "Activo · vista previa" (o "sin cargo", según `ADDONS_BILLING_LIVE` actual) y **Cuerpo** como "Activo".
4. Tab **Explorar**: ambos módulos deben aparecer elegibles (rubro HEALTH los habilita).

Con `ADDONS_BILLING_LIVE=0` (estado normal) la UI muestra precio tachado + "Gratis" y botón **Activar**; con `=1` muestra precio real y botón **Suscribirse**.

SQL de referencia (equivalente a lo que devuelve `GET /workspace/addons`):

```sql
SELECT ra.code, oa.status, oa.grant_type
  FROM org_addon oa JOIN ref_addon ra ON ra.id_addon = oa.rad_id_addon
 WHERE oa.org_id_organization = 29;
```

Esperado: `ODONTOGRAM_3D` → `ACTIVE`/`PREVIEW`; `BODY_MAP` → `ACTIVE`/`PAID`.

### A2. Cancelar un `PREVIEW` (sin cobro, sin crédito)

1. En `/panel/complementos` → tab **Mis módulos** → **Odontograma 3D** → botón **Desactivar**.
2. Confirmar.

SQL:

```sql
SELECT status, grant_type, canceled_at FROM org_addon
 WHERE org_id_organization = 29 AND rad_id_addon = (SELECT id_addon FROM ref_addon WHERE code='ODONTOGRAM_3D');

SELECT account_balance FROM org_subscription WHERE org_id_organization = 29;
```

**Esperado:** `status='CANCELED'`, `canceled_at` NOT NULL. `account_balance` **sin cambios** (un `PREVIEW` cancelado no genera crédito ni NCE — `pr_cancel_module_addon` corta antes de calcular reembolso cuando `grant_type='PREVIEW'`).

### A3. Activar con `ADDONS_BILLING_LIVE=1`, cubierto 100% por saldo (sin Pagopar)

Ventana de flag acotada — hacer esto de una sola vez, sin dejar el flag prendido mientras se navega otra cosa.

```sql
DECLARE
    v_org NUMBER := 29;
BEGIN
    UPDATE app_parameter SET param_value = '1' WHERE param_key = 'ADDONS_BILLING_LIVE';
    UPDATE org_subscription SET account_balance = 500000 WHERE org_id_organization = v_org;
    COMMIT;
END;
/
```

UI: recargar `/panel/complementos` → ahora debería mostrar precio real (69.000 Gs) y botón **Suscribirse** para Odontograma. Click → confirmar.

SQL de verificación:

```sql
SELECT status, grant_type, billing_started_at FROM org_addon
 WHERE org_id_organization = 29 AND rad_id_addon = (SELECT id_addon FROM ref_addon WHERE code='ODONTOGRAM_3D');

SELECT id_invoice, invoice_type, status, amount, gross_amount, credit_applied, payment_provider
  FROM org_subscription_invoice
 WHERE org_id_organization = 29 AND rad_id_addon = (SELECT id_addon FROM ref_addon WHERE code='ODONTOGRAM_3D')
 ORDER BY created_at DESC FETCH FIRST 1 ROW ONLY;

SELECT account_balance FROM org_subscription WHERE org_id_organization = 29;
```

**Esperado:** invoice `MODULE_ADDON` `PAID`, `amount=0`, `gross_amount=69000`, `credit_applied=69000`, `payment_provider='credit'` (sin Pagopar). `org_addon` → `ACTIVE`/`PAID`. `account_balance` bajó a `431000`. La UI no debería pedir polling (respuesta 200 directa, no 201).

### A4. Activar con cobro real por Pagopar (sin saldo, con tarjeta)

Repetir sin crédito disponible, para forzar el camino con tarjeta:

```sql
DECLARE
    v_org NUMBER := 29;
BEGIN
    UPDATE app_parameter SET param_value = '1' WHERE param_key = 'ADDONS_BILLING_LIVE'; -- si ya estaba en 1, no-op
    UPDATE org_subscription SET account_balance = 0 WHERE org_id_organization = v_org;
    COMMIT;
END;
/
```

1. En `/panel/complementos`, cancelar Odontograma otra vez (queda `CANCELED`).
2. **Suscribirse** de nuevo. Como `account_balance=0`, esto **cobra de verdad** con la tarjeta default catastrada en el pase de suscripción (si no hay tarjeta, agregar una primero desde `/panel/plan`, igual que en `QA_SUSCRIPCION_HAPPY_PATH_STAGING.md` A1).
3. La respuesta debería ser `201` con `requires_polling:1`; la UI hace polling de `GET /api/subscription/invoice/:hash`.

SQL:

```sql
SELECT id_invoice, status, amount, gross_amount, external_reference
  FROM org_subscription_invoice
 WHERE org_id_organization = 29 AND rad_id_addon = (SELECT id_addon FROM ref_addon WHERE code='ODONTOGRAM_3D')
 ORDER BY created_at DESC FETCH FIRST 1 ROW ONLY;
```

**Esperado (30-120 s):** `status` pasa de `PENDING` a `PAID` vía el mismo webhook `POST .../ords/aoxdev/pagopar/v1/subscription/webhook` que ya se validó para el plan (mismo `pr_subscription_webhook`, mismo `fn_pay`). `amount=gross_amount=69000` (sin saldo que descuente).

Si el webhook no llega, el fallback es idéntico al del pase de suscripción (simular con `hash_pedido` + `fn_pagopar_sha1_token` + `pr_subscription_webhook`) — ver esa sección si hace falta.

**Al terminar A3+A4, apagar el flag:**

```sql
UPDATE app_parameter SET param_value = '0' WHERE param_key = 'ADDONS_BILLING_LIVE';
COMMIT;
```

### A5. Cancelar un `PAID` con FE 0260 aprobada → NCE (no crédito)

Usar **Cuerpo** (`BODY_MAP`), que el seed dejó `PAID` con una FE 0260 simulada (no depende del firmador real para este caso puntual).

1. En `/panel/complementos` → **Cuerpo** → **Desactivar**.

SQL:

```sql
SELECT n.id_credit_note, n.status, n.org_id_organization
  FROM subscription_credit_note n
  JOIN org_subscription_invoice i ON i.id_invoice = n.source_invoice_id
 WHERE n.org_id_organization = 29
   AND i.invoice_type = 'MODULE_ADDON'
   AND i.rad_id_addon = (SELECT id_addon FROM ref_addon WHERE code='BODY_MAP')
 ORDER BY n.id_credit_note DESC FETCH FIRST 1 ROW ONLY;

SELECT status, canceled_at FROM org_addon
 WHERE org_id_organization = 29 AND rad_id_addon = (SELECT id_addon FROM ref_addon WHERE code='BODY_MAP');

SELECT account_balance FROM org_subscription WHERE org_id_organization = 29;
```

**Esperado:** fila nueva en `subscription_credit_note` (NCE encolada). `org_addon` → `CANCELED`. `account_balance` **no sube** (es NCE, no crédito — son mutuamente excluyentes: si hay FE 0260 aprobada se hace NCE; solo si NO hay FE aprobada se usa crédito en cuenta).

Si la UI muestra error "Facturación en curso...": significa que hay una FE `MODULE_ADDON` pendiente sin CDC todavía — esperar a que el ciclo/outbox la resuelva antes de cancelar.

### A6. Renovación en el ciclo — `PREVIEW` → `PAID` para ambos

Reusa el mismo acelerador que el pase de suscripción (`pr_run_billing_cycle_for_org`, scoped a la org — a diferencia de `ADDONS_BILLING_LIVE` esto sí es seguro dejar correr sin afectar otras orgs).

```sql
DECLARE
    v_org NUMBER := 29;
BEGIN
    UPDATE app_parameter SET param_value = '1' WHERE param_key = 'ADDONS_BILLING_LIVE';

    UPDATE org_addon
       SET status = 'ACTIVE', grant_type = 'PREVIEW', canceled_at = NULL,
           billing_started_at = NULL, updated_at = systimestamp
     WHERE org_id_organization = v_org;

    UPDATE org_subscription
       SET account_balance    = 400000,
           current_period_end = systimestamp - INTERVAL '1' SECOND,
           charge_retry_count = 0,
           status              = 'ACTIVE',
           auto_renew          = 1
     WHERE org_id_organization = v_org;

    DELETE FROM api_idempotency_key
     WHERE scope_code = 'SUBSCRIPTION_CHARGE_TARGET'
       AND idem_key LIKE 'CYCLE:' || v_org || ':%';

    COMMIT;
END;
/

@@scripts/qa_billing_e2e_run_cycle.sql
```

SQL de verificación:

```sql
SELECT ra.code, oa.status, oa.grant_type FROM org_addon oa
  JOIN ref_addon ra ON ra.id_addon = oa.rad_id_addon
 WHERE oa.org_id_organization = 29;

SELECT invoice_type, COUNT(*) FROM org_subscription_invoice
 WHERE org_id_organization = 29 AND status = 'PAID'
   AND created_at > systimestamp - INTERVAL '10' MINUTE
 GROUP BY invoice_type;
```

**Esperado:** ambos `org_addon` en `ACTIVE`/`PAID`. Al menos 2 invoices `MODULE_ADDON` `PAID` (uno por complemento) + 1 `SUBSCRIPTION` `PAID` (el plan), todas cubiertas por el saldo de 400.000 (sin necesitar Pagopar si el saldo alcanza; si no alcanza, sí pasa por tarjeta igual que en el pase de suscripción).

**Apagar el flag al cerrar este caso:**

```sql
UPDATE app_parameter SET param_value = '0' WHERE param_key = 'ADDONS_BILLING_LIVE';
COMMIT;
```

---

## 5. Caso B — Almacenamiento (`/panel/plan`)

Requiere **Premium** (la fixture ya lo es) y **NO** depende de `ADDONS_BILLING_LIVE` — storage siempre cobra si hay monto a pagar.

### B1. Confirmar elegibilidad en UI

1. `/panel/plan` → sección **"Almacenamiento adicional"** debe estar visible (no dice "Disponible con el plan Premium" deshabilitado).
2. Catálogo muestra `STORAGE_5GB` (15.000 Gs/mes) y `STORAGE_15GB` (35.000 Gs/mes) con el monto de prorrateo de "Hoy" según los días restantes del periodo.

### B2. Comprar `STORAGE_5GB` (prorrateo + cobro real)

1. Click **Contratar** en `STORAGE_5GB`. El modal muestra el monto prorrateado de hoy.
2. Confirmar → si `days_remaining > 0` y el monto prorrateado > 0, cobra con la tarjeta default (mismo flujo Pagopar que el plan). Respuesta `201` + polling.

SQL antes de comprar (para saber qué esperar):

```sql
SELECT current_period_start, current_period_end,
       TRUNC(current_period_end) - TRUNC(SYSTIMESTAMP) AS dias_restantes
  FROM org_subscription WHERE org_id_organization = 29;
```

Cálculo esperado: `CEIL(15000 * dias_restantes / periodo_dias)`, mínimo 1000 Gs si hay algún día restante. Ej.: con ~15 días de 30 → `CEIL(15000*15/30) = 7500` Gs.

SQL de verificación tras confirmar el pago (poll 30-120 s):

```sql
SELECT id_invoice, invoice_type, status, amount, gross_amount, period_end
  FROM org_subscription_invoice
 WHERE org_id_organization = 29 AND invoice_type = 'STORAGE_ADDON'
 ORDER BY created_at DESC FETCH FIRST 1 ROW ONLY;

SELECT rsa.code, osa.status, osa.quantity
  FROM org_storage_addon osa JOIN ref_storage_addon rsa ON rsa.id_storage_addon = osa.sad_id_storage_addon
 WHERE osa.org_id_organization = 29;

SELECT storage_limit_bytes FROM org_subscription WHERE org_id_organization = 29;
```

**Esperado:** invoice `STORAGE_ADDON` `PAID`. `org_storage_addon` fila `STORAGE_5GB` `ACTIVE` `quantity=1`. `period_end` de la factura = `current_period_end` del plan (alineado, no +1 mes desde hoy). `storage_limit_bytes` subió en 5.368.709.120 bytes (Premium base 5 GB + 5 GB addon = 10 GB).

UI: la barra de uso de storage en `/panel/plan` debe reflejar el nuevo límite tras recargar.

### B3. Si el periodo ya venció al momento de comprar

Caso borde: si por backdate previo (Caso A6) `current_period_end` quedó en el pasado, el prorrateo da `0` y la compra se activa **sin cobro** ("entra en la próxima renovación"). Verificar:

```sql
-- Solo si current_period_end <= systimestamp al momento de comprar
SELECT status FROM org_subscription_invoice
 WHERE org_id_organization = 29 AND invoice_type='STORAGE_ADDON'
 ORDER BY created_at DESC FETCH FIRST 1 ROW ONLY; -- puede no existir invoice si gross=0
```

Si esto pasa y se quiere forzar el caso "con cobro", primero renovar el periodo (correr un ciclo o `UPDATE current_period_end = ADD_MONTHS(systimestamp,1)`) y recién ahí comprar.

### B4. Cancelar 1 unidad

1. `/panel/plan` → en el paquete activo → **Cancelar**.

SQL:

```sql
SELECT osa.status, osa.quantity, osa.ends_at
  FROM org_storage_addon osa
 WHERE osa.org_id_organization = 29
   AND osa.sad_id_storage_addon = (SELECT id_storage_addon FROM ref_storage_addon WHERE code='STORAGE_5GB');

SELECT account_balance FROM org_subscription WHERE org_id_organization = 29;
```

**Esperado (con `quantity=1`):** `status='CANCELED'`, `ends_at` NOT NULL. Crédito o NCE según si hay FE `STORAGE_ADDON` 0260 aprobada para ese addon (mismo criterio que módulos: FE aprobada → NCE; si no → crédito en `account_balance` vía `fn_unused_credit_amount`). `storage_limit_bytes` vuelve a bajar (`pr_refresh_storage_limit`).

### B5. Comprar un segundo paquete distinto (variar catálogo)

Repetir B2 con `STORAGE_15GB` para asegurar que el flujo no está hardcodeado a un solo `code`. Mismo cálculo de prorrateo con `price_amount=35000`.

### B6. Renovación en el ciclo (storage entra al consolidado)

Con al menos un `org_storage_addon` `ACTIVE`, correr el mismo acelerador de ciclo del Caso A6 (o del pase de suscripción). El monto consolidado del plan debe incluir el addon de storage:

```sql
SELECT id_invoice, invoice_type, amount, gross_amount, sad_id_storage_addon
  FROM org_subscription_invoice
 WHERE org_id_organization = 29
   AND created_at > systimestamp - INTERVAL '10' MINUTE
 ORDER BY created_at DESC;
```

**Esperado:** una fila `SUBSCRIPTION` (plan) y, en la misma corrida, una fila `STORAGE_ADDON` por cada paquete `ACTIVE` (la renovación de storage **no** incrementa `quantity`, solo genera la factura y mantiene la fila activa — a diferencia de la compra mid-cycle que sí hace `quantity+1` vía `pr_fulfill_paid_addon` cuando el batch tiene una sola invoice).

### B7. Confirmación (solo lectura) — Base no puede comprar storage

No hace falta downgradear la fixture. Alcanza con leer el código y, si se quiere, un chequeo puntual en otra org de prueba que esté en Base:

```sql
SELECT s.org_id_organization, p.code
  FROM org_subscription s JOIN ref_plan p ON p.id_plan = s.pln_id_plan
 WHERE p.code = 'BASE' AND s.org_id_organization <> 1
 FETCH FIRST 5 ROWS ONLY;
```

El gate real está en `pr_charge_target` (rama `STORAGE_ADDON`): `fn_org_has_feature(org, 'APPOINTMENT_HISTORY') = 0` → error 403 "Los paquetes de almacenamiento solo estan disponibles en el plan Premium." `APPOINTMENT_HISTORY` solo está seedeado en `ref_plan_feature` para `id_plan=2` (Premium). En la UI, el botón "Contratar" aparece deshabilitado con el texto "Solo Premium" cuando `supports_storage_addons=0`.

---

## 6. Orden sugerido para una sesión

```text
Preflight §2
    → Reset §3 (fixture conocida: Premium, Odontograma PREVIEW, Cuerpo PAID+FE0260, sin storage)
    → Caso A1-A2 (ver catálogo, cancelar PREVIEW sin cobro)
    → Caso A3 (ADDONS_BILLING_LIVE=1 + saldo → activar sin Pagopar) → apagar flag
    → Caso A4 (ADDONS_BILLING_LIVE=1 + sin saldo → activar con Pagopar real) → apagar flag
    → Caso A5 (cancelar PAID con FE 0260 → NCE)
    → Caso A6 (ADDONS_BILLING_LIVE=1 + ciclo acelerado → PREVIEW→PAID ambos) → apagar flag
    → Caso B1-B2 (storage: comprar con prorrateo + Pagopar)
    → Caso B4 (cancelar 1 unidad)
    → Caso B5 (comprar el otro paquete)
    → Caso B6 (ciclo: storage entra al consolidado)
    → Reset §3 si se va a repetir, o dejar así para cierre de pase
```

---

## 7. Qué hace el bot vs. qué hace un humano

| Paso | Bot (SQL / repos) | Humano |
|---|---|---|
| Preflight, reset, prender/apagar `ADDONS_BILLING_LIVE` acotado | Sí | — |
| Login + switch de org + navegar `/panel/complementos` y `/panel/plan` | Sí si tiene browser | Preferible |
| Click Activar/Suscribirse/Cancelar/Contratar | Sí si tiene browser | Preferible, sobre todo para ver el copy PREVIEW vs PAID |
| Iframe uPay / PAN de prueba | Frágil en automatización | Completar el iframe si hace falta agregar tarjeta nueva |
| Webhook Pagopar (A4, B2) | Poll SQL 30-120 s | Si no llega, mismo troubleshooting que el pase de suscripción |
| Verificar `subscription_credit_note` (NCE) | Sí | — |

---

## 8. Troubleshooting rápido

| Síntoma | Causa típica | Qué hacer |
|---|---|---|
| `"El cobro de complementos todavía no está habilitado."` | `ADDONS_BILLING_LIVE=0` | Prenderlo (acotado) antes de A3/A4/A6 |
| `"Los paquetes de almacenamiento solo estan disponibles en el plan Premium."` | Org no tiene feature `APPOINTMENT_HISTORY` (no es Premium) | Confirmar plan; no aplica a la fixture (ya es Premium) |
| `"Este complemento ya está activo."` | Ya hay `org_addon` `ACTIVE`+`PAID` para ese código | Cancelar primero si se quiere repetir el flujo de activación |
| Cancelar módulo/storage devuelve `"Facturación en curso..."` | Hay una FE del addon `PENDING` sin CDC todavía | Esperar el outbox/firmador o revisar `einvoice_status` de esa invoice |
| Cancelar `PAID` no genera ni crédito ni NCE | Puede ser esperado: mutuamente excluyentes (FE 0260 aprobada → NCE; si no, crédito). Revisar `einvoice_cod_res` de la invoice de origen | No es bug si uno de los dos caminos se cumplió |
| Prorrateo de storage sale distinto al calculado a mano | `period_days` puede ser 30/31 según el mes real entre `current_period_start` y `current_period_end`, no fijo en 30 | Recalcular con las fechas reales de la fila |
| `storage_limit_bytes` no sube tras comprar | Invoice quedó `PENDING` (falta el webhook) o `pr_refresh_storage_limit` no corrió | Confirmar que la invoice pasó a `PAID` primero |
| Alguien más deja `ADDONS_BILLING_LIVE=1` prendido de una sesión anterior | Flag global sin dueño claro | Avisar antes de asumir que es "tu" corrida; no asumas que el flag en `1` es intencional tuyo |
| `qa_billing_e2e_modules.sql` falla a mitad y deja `ADDONS_BILLING_LIVE=1` | No debería — tiene `EXCEPTION` que restaura flags — pero si pasó, restaurar a mano | `UPDATE app_parameter SET param_value='0' WHERE param_key IN ('ADDONS_BILLING_LIVE','BILLING_ENABLED')` |

---

## 9. Archivos de referencia

| Path | Uso |
|---|---|
| `scripts/qa_billing_e2e_seed.sql` | Reset a estado conocido (Premium + Odontograma PREVIEW + Cuerpo PAID/FE0260) |
| `scripts/qa_billing_e2e_modules.sql` | Los mismos 6 casos de complementos, automatizados con asserts (referencia / regresión rápida) |
| `scripts/qa_billing_e2e_run_cycle.sql` | Acelerador de ciclo scoped a la fixture (`pr_run_billing_cycle_for_org`) |
| `scripts/qa_billing_e2e_exec.py` | Orquestador Python; sin args corre `seed` + `modules` contra `aoxdev` |
| `packages/PKG_AOX_ADDON_API.pls` | `pr_list_addons`, `pr_activate_module_addon`, `pr_cancel_module_addon` (endpoints `/workspace/addons*`) |
| `packages/PKG_AOX_ADDON_ELIGIBILITY.pls` | `fn_addon_eligible` — elegibilidad por rubro (`ref_addon_specialty` ↔ `organization_specialty`) |
| `packages/PKG_AOX_SUBSCRIPTION_BILLING_API.pls` | `pr_charge_target` (ramas `MODULE_ADDON`/`STORAGE_ADDON`), `pr_fulfill_paid_module_addon`, `pr_fulfill_paid_addon`, `pr_cancel_module_addon`, `pr_cancel_storage_addon`, `pr_refresh_storage_limit`, `fn_prorate_amount` |
| `tables/REF_ADDON.sql`, `ORG_ADDON.sql`, `REF_STORAGE_ADDON.sql`, `ORG_STORAGE_ADDON.sql` | DDL real (columnas/checks verificados) |
| `docs/ORDS_SUBSCRIPTION_BILLING.md` | Contratos de `/workspace/subscription/*` (storage). **No** documenta `/workspace/addons*` (módulos) — usar el paquete PL/SQL como fuente de verdad ahí. |
| `bookmate/src/pages/panel/complementos.astro` + `src/scripts/complementos-page.ts` | UI complementos |
| `bookmate/src/pages/panel/plan.astro` + `src/scripts/plan-page.ts` | UI storage (sección "Almacenamiento adicional") |
| `bookmate/src/lib/addons.ts` | Cliente ORDS complementos |
| `bookmate/src/lib/subscription.ts` | Cliente ORDS plan + storage |

Siguiente pase (fuera de alcance): pruebas de carga/concurrencia sobre `ADDONS_BILLING_LIVE` compartido, y feature flags de UI específicos de complementos (hoy no existen, `/panel/complementos` no depende de `PUBLIC_SUBSCRIPTION_BILLING_UI`).
