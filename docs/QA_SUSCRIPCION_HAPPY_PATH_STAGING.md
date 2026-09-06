# QA staging — suscripción Hasel (camino feliz, solo plan)

Runbook para un agente con acceso a:

- Frontend: `bookmate/` (rama de staging)
- Backend SQL: `aox-dev/`
- Base **aoxdev** (Oracle ADB, esquema `aoxdev`)
- UI: `https://staging.hasel.app`

Alcance de **este pase**: catastrar tarjeta de prueba Pagopar, acelerar el cobro mensual **sin esperar al job**, confirmar factura + correo, **cancelar** suscripción y **bajar** de Premium a Base.

Fuera de alcance (siguiente pase): complementos/módulos y almacenamiento extra.

---

## 0. Cómo está armado el cobro (no improvisar)

| Pieza | Dónde | Qué hace |
|---|---|---|
| UI de plan | `https://staging.hasel.app/panel/plan` | Perfil fiscal, tarjetas uPay, historial, cancelar, bajar a Base |
| Catastro de tarjeta | `POST /api/v1/workspace/subscription/card/add` + iframe uPay + `.../card/confirm` | Tokeniza la tarjeta. Hasel no guarda el PAN |
| Cobro mensual real | `pkg_aox_subscription_billing_api.pr_charge_target` vía Pagopar `pago-recurrente/3.0` | Deja la factura en `PENDING` |
| Confirmar pago | Webhook `POST .../ords/aoxdev/pagopar/v1/subscription/webhook` | Pasa la factura a `PAID`, extiende el periodo |
| Acelerador DEV | `pr_run_billing_cycle_for_org(org_id)` | Solo la org fixture. **No** exige `BILLING_ENABLED=1` |
| Job global | `HASEL_SUBSCRIPTION_BILLING_CYCLE` → `pr_run_billing_cycle` | **Solo producción.** Con `BILLING_ENABLED=0` el job global sale en `SKIPPED` |
| Correo de factura | Firmador → webhook `invoice.ready` → ORDS `pr_receive_esign_webhook` → `pr_send_einvoice_email` | Astro **no** envía el mail. `poll-kude` no forma parte del camino feliz |

Precios vigentes en aoxdev (`ref_plan`):

| Plan | `id_plan` | Precio |
|---|---|---|
| Base | 1 | **129.000 Gs** |
| Premium | 2 | **229.000 Gs** |
| Continuidad (`FREE`) | 3 | 0 |

Fixture ya existente:

- `QA_BILLING_E2E_ORG_ID` = **29**
- Nombre: **QA Billing E2E**
- Owner: `mike.sdk83@gmail.com` (`platform_user` id=10, rol ADMIN)
- Flags actuales: `BILLING_ENABLED=0`, `ADDONS_BILLING_LIVE=0`
- Keys Pagopar de plataforma: cargadas
- `PAGOPAR_UPAY_RETURN_URL` = `https://staging.hasel.app/panel/plan`
- `ESIGN_WEBHOOK_URL` = `https://staging.hasel.app/api/internal/esign/emit-invoice` (Hasel **pide** emitir la FE; no es el mail)
- Receptor del mail: el firmador POSTea `invoice.ready` a `POST .../ords/aoxdev/public/v1/esign/webhook` (`pr_receive_esign_webhook`). El URL y el secret HMAC viven en el **panel esign** del tenant Hasel; `ESIGN_WEBHOOK_SECRET` en aoxdev debe coincidir.

El seed `scripts/qa_billing_e2e_seed.sql` deja la org en Premium ACTIVE, **pero también inserta módulos** (odontograma PREVIEW + BODY_MAP PAID) y una factura FE simulada. Para este pase hay que **borrar esos addons** después del seed.

---

## 1. Prohibido (abortar si el bot lo propone)

| Acción | Por qué |
|---|---|
| `UPDATE app_parameter SET param_value='1' WHERE param_key='BILLING_ENABLED'` | Encendería cobro de **todas** las orgs facturables de aoxdev |
| Crear o correr el job `HASEL_SUBSCRIPTION_BILLING_CYCLE` | Migración prod-only (`migrations/20260711_subscription_recurring_job.sql`) |
| `pkg_aox_subscription_billing_api.pr_run_billing_cycle` (global) | Con `BILLING_ENABLED=0` no cobra; si alguien prende el flag, cobra a todos |
| `python scripts/qa_billing_e2e_exec.py` **sin argumentos** | Por default corre `qa_billing_e2e_modules.sql` y prende `ADDONS_BILLING_LIVE` |
| `@@scripts/qa_billing_e2e_modules.sql` | Fuera de alcance; ensucia monto y flags |
| Tocar `organization` / `org_subscription` de **org_id=1** | Consultorio General |
| `qa_billing_e2e_cleanup.sql` a mitad de un caso | Borra la org 29 entera (tarjeta, perfil, membresía) |
| Inventar un PAN de tarjeta | No hay tarjeta sandbox en el repo. Usar la que dé Pagopar para el comercio HASEL |
| Cancelar y bajar en la **misma** suscripción sin reset | Ambos escriben el mismo `pending_pln_id_plan` |

Acelerador permitido:

```sql
-- SOLO esto, y SOLO contra la fixture:
pkg_aox_subscription_billing_api.pr_run_billing_cycle_for_org(
  TO_NUMBER(fn_get_parameter('QA_BILLING_E2E_ORG_ID'))
);
-- o: @@scripts/qa_billing_e2e_run_cycle.sql
```

Ese procedimiento **rechaza** cualquier org que no sea `QA_BILLING_E2E_ORG_ID` y aborta si `org_id=1`.

---

## 2. Preflight (solo lectura)

Correr **antes** de cualquier UPDATE/DELETE:

```sql
SELECT fn_get_parameter('QA_BILLING_E2E_ORG_ID') AS org_id,
       fn_get_parameter('BILLING_ENABLED')         AS billing_enabled,
       fn_get_parameter('ADDONS_BILLING_LIVE')    AS addons_live,
       fn_get_parameter('PAGOPAR_UPAY_RETURN_URL') AS upay_return
  FROM dual;

SELECT id_organization, name
  FROM organization
 WHERE id_organization = TO_NUMBER(fn_get_parameter('QA_BILLING_E2E_ORG_ID'));

SELECT job_name, enabled, state
  FROM user_scheduler_jobs
 WHERE job_name LIKE '%BILLING%' OR job_name LIKE '%SUBSCRIPTION%';
```

**Abortar** si cualquiera de esto falla:

- `org_id` distinto de `29` o `NULL`, o `name` distinto de `QA Billing E2E`
- `BILLING_ENABLED <> 0` o `ADDONS_BILLING_LIVE <> 0`
- `PAGOPAR_UPAY_RETURN_URL` no es `https://staging.hasel.app/panel/plan`
- aparece el job `HASEL_SUBSCRIPTION_BILLING_CYCLE`

UI: abrir `https://staging.hasel.app/panel/plan` logueado como `mike.sdk83@gmail.com`, org **QA Billing E2E**.

- Si redirige a `/panel/dashboard`, el flag `PUBLIC_SUBSCRIPTION_BILLING_UI` está en `0` o el host de staging está resolviendo como prod (`hasel.app`). No es un bug de cobro: hay que corregir env de Vercel staging.
- Visible por defecto en staging (`feature-flags.ts`: se oculta solo en `hasel.app` / `www.hasel.app`).

---

## 3. Reset a “solo plan” (SQL)

No hace falta borrar la org. El seed es idempotente sobre la fixture 29. **Después** hay que quitar módulos, invoices viejas y la key de idempotencia del día.

```sql
ALTER SESSION DISABLE PARALLEL DML;

@@scripts/qa_billing_e2e_seed.sql
```

Luego, **siempre** este bloque (plan-only). Dejar `current_period_end` a **+1 mes** hasta que la tarjeta esté catastrada:

```sql
DECLARE
    v_org  NUMBER := TO_NUMBER(fn_get_parameter('QA_BILLING_E2E_ORG_ID'));
    v_name organization.name%TYPE;
BEGIN
    IF v_org IS NULL OR v_org = 1 THEN
        RAISE_APPLICATION_ERROR(-20002, 'fixture invalida');
    END IF;

    SELECT name INTO v_name FROM organization WHERE id_organization = v_org;
    IF v_name <> 'QA Billing E2E' THEN
        RAISE_APPLICATION_ERROR(-20003, 'org ' || v_org || ' no es la fixture');
    END IF;

    DELETE FROM subscription_einvoice_outbox WHERE org_id_organization = v_org;
    DELETE FROM subscription_credit_note   WHERE org_id_organization = v_org;
    DELETE FROM org_billing_credit_ledger  WHERE org_id_organization = v_org;
    DELETE FROM org_subscription_invoice   WHERE org_id_organization = v_org;
    DELETE FROM org_storage_addon          WHERE org_id_organization = v_org;
    DELETE FROM org_addon                  WHERE org_id_organization = v_org;

    DELETE FROM api_idempotency_key
     WHERE scope_code = 'SUBSCRIPTION_CHARGE_TARGET'
       AND idem_key LIKE 'CYCLE:' || v_org || ':%';

    UPDATE org_subscription
       SET status                 = 'ACTIVE',
           pln_id_plan            = (SELECT id_plan FROM ref_plan WHERE code = 'PREMIUM'),
           is_founder             = 0,
           billing_exempt         = 0,
           auto_renew             = 1,
           charge_retry_count     = 0,
           account_balance        = 0,
           pending_pln_id_plan    = NULL,
           pending_plan_change_at = NULL,
           canceled_at            = NULL,
           trial_started_at      = NULL,
           trial_ends_at         = NULL,
           grace_ends_at         = NULL,
           current_period_start   = systimestamp,
           current_period_end     = ADD_MONTHS(systimestamp, 1),
           updated_at            = systimestamp
     WHERE org_id_organization = v_org;

    COMMIT;
END;
/
```

Notas:

- **No** borrar `org_payment_card` si ya hay una tarjeta ACTIVE de una corrida anterior (ahorra el iframe). Si se quiere probar el catastro desde cero, borrar las tarjetas **primero en la UI** (`/panel/plan` → eliminar) y recién después `DELETE FROM org_payment_card WHERE org_id_organization = 29`. El cleanup local **no** revoca la tarjeta en Pagopar: al confirmar de nuevo, `pr_sync_cards` puede reimportar tarjetas remotas.
- `qa_billing_e2e_restore_snapshot.sql` **no** sirve para este pase: re-ejecuta el seed **con módulos**.
- `charge_retry_count` se incrementa **antes** de cobrar. Tope: `SUBSCRIPTION_MAX_CHARGE_RETRIES` = 4. Si se satura, el ciclo deja de cobrar aunque la factura siga `PENDING`.

---

## 4. Caso A — camino feliz de cobro

### A1. UI: perfil + tarjeta (periodo todavía a futuro)

1. Login: `https://staging.hasel.app` con `mike.sdk83@gmail.com`.
2. Cambiar a la org **QA Billing E2E** (el JWT lleva `organization_id`; si se queda en otra org, se cobra/agendan cosas en la org equivocada).
3. Ir a `/panel/plan`.
4. Completar/confirmar **Datos de facturación** (el seed deja RUC `80069563`, email `mike.sdk83@gmail.com`). Sin perfil completo el botón “Agregar tarjeta” queda bloqueado.
5. **Agregar tarjeta** → iframe uPay (Pagopar). Usar la **tarjeta de prueba** que Pagopar habilitó para el comercio HASEL (`pago-recurrente/3.0`). No hay PAN en este repo.
6. Al volver, la URL debe ser `https://staging.hasel.app/panel/plan?status=add_new_card_success` (o `add_new_card_error`). `plan-page.ts` llama `confirmCard()` solo.
7. La tarjeta debe verse listada y **predeterminada**.

SQL (columnas reales de `org_payment_card`: `id_payment_card`, `brand`, `masked_number`, no `card_brand`/`last_four`):

```sql
SELECT id_payment_card, status, is_default, brand, masked_number, pagopar_card_id, confirmed_at
  FROM org_payment_card
 WHERE org_id_organization = 29
 ORDER BY created_at DESC;
```

Esperado: ≥ 1 fila `status='ACTIVE'`, una con `is_default=1` y `pagopar_card_id` NOT NULL (`pr_charge_consolidated_cycle` exige exactamente esa combinación para elegir la tarjeta a cobrar).

Si el iframe vuelve a `hasel.app` (prod): `PAGOPAR_UPAY_RETURN_URL` se pisó. Abortar y restaurar el parámetro de staging.

### A2. Acelerar el cobro (SQL, después de la tarjeta)

El ciclo cobra si **todas** estas condiciones se cumplen:

- `status IN ('ACTIVE','PAST_DUE')`
- `auto_renew = 1`
- `billing_exempt = 0`
- `current_period_end <= systimestamp`
- plan ≠ `FREE`
- `charge_retry_count < 4`
- hay tarjeta default activa

```sql
DECLARE
    v_org NUMBER := TO_NUMBER(fn_get_parameter('QA_BILLING_E2E_ORG_ID'));
BEGIN
    IF v_org <> 29 THEN
        RAISE_APPLICATION_ERROR(-20002, 'fixture invalida');
    END IF;

    DELETE FROM api_idempotency_key
     WHERE scope_code = 'SUBSCRIPTION_CHARGE_TARGET'
       AND idem_key LIKE 'CYCLE:' || v_org || ':%';

    UPDATE org_subscription
       SET current_period_end = systimestamp - INTERVAL '1' SECOND,
           charge_retry_count = 0,
           status               = 'ACTIVE',
           auto_renew           = 1,
           billing_exempt       = 0
     WHERE org_id_organization = v_org;

    COMMIT;
END;
/

@@scripts/qa_billing_e2e_run_cycle.sql
```

**No** re-ejecutar el ciclo en un loop el mismo día. La key de idempotencia es:

```text
CYCLE:<org_id>:<YYYYMMDD>
```

Un segundo run el mismo día hace **REPLAY** (no cobra de nuevo) y **igual** suma `charge_retry_count` — pero **solo si el primer intento llegó a completarse** (Pagopar respondió, sea éxito o `PENDING`). El log `SUCCESS` de `pr_run_billing_cycle_for_org` **no** significa que Pagopar cobró: hay que mirar la factura.

⚠️ Caso distinto — **rechazo explícito de Pagopar** (`fn_pay` responde `respuesta:false`, ej. tarjeta de prueba inválida): `pr_charge_target` deja la key `IN_PROGRESS` a propósito (por diseño, para que el frontend emita una key nueva en el próximo intento del usuario — ver comentario en el código, `EXCEPTION WHEN OTHERS` de `pr_charge_target`). Como acá reusamos la **misma** key `CYCLE:<org>:<YYYYMMDD>` todo el día, un segundo run **no** hace replay: falla con `ORA-20xxx "Ya hay un cobro en curso para esta operación..."`. Solución: correr de nuevo el `DELETE FROM api_idempotency_key ...` antes de reintentar el ciclo (ya está en el bloque de arriba, así que simplemente re-ejecutar todo el bloque completo sirve).

### A3. Confirmar el pago

Inmediatamente después del ciclo la factura suele estar `PENDING`. `PAID` llega con el **webhook Pagopar**, no con el SQL.

```sql
SELECT id_invoice, invoice_type, status, amount, gross_amount, credit_applied,
       payment_provider, external_reference, paid_at,
       einvoice_status, einvoice_cod_res, einvoice_email_status, einvoice_email_to
  FROM org_subscription_invoice
 WHERE org_id_organization = 29
 ORDER BY created_at DESC;

SELECT status, auto_renew, charge_retry_count,
       current_period_start, current_period_end,
       last_charge_at
  FROM org_subscription
 WHERE org_id_organization = 29;

SELECT created_at, status, process_name, error_message
  FROM aox_api_log
 WHERE org_id = 29
   AND api_name IN ('SUBSCRIPTION_BILLING_CYCLE', 'SUBSCRIPTION_WEBHOOK')
 ORDER BY created_at DESC FETCH FIRST 15 ROWS ONLY;
```

**Esperado (camino feliz):**

| Campo | Valor |
|---|---|
| `invoice_type` | **`SUBSCRIPTION`** (único valor que usa `pr_charge_consolidated_cycle` para la fila del plan; `CONSOLIDATED` es solo el `pi_target_type` interno, no un valor de columna — no existe en el `CHECK` de `invoice_type`. **No** debe aparecer `MODULE_ADDON` / `STORAGE_ADDON` en este caso) |
| `amount` / `gross_amount` | **229000** |
| `payment_provider` | `pagopar` |
| `status` | `PENDING` → (webhook, 30–120 s) → **`PAID`** |
| `current_period_end` | ~ +1 mes desde ahora |
| `charge_retry_count` | `0` después del fulfill (si sigue subiendo, el webhook no llegó) |
| `BILLING_ENABLED` | sigue `0` |

UI: recargar `/panel/plan` → historial con la factura pagada.

Si a los 2–3 minutos sigue `PENDING` y `fn_pay` fue OK (hay `external_reference`): el webhook no llegó al ORDS de aoxdev. Revisar URL en el panel Pagopar (comercio HASEL):

```text
https://g9549f707e8ebfa-aoxdev.adb.sa-saopaulo-1.oraclecloudapps.com/ords/aoxdev/pagopar/v1/subscription/webhook
```

Último recurso (solo si el cobro **real** ya ocurrió en Pagopar y el webhook no llega): simular el webhook con el `external_reference` real, igual que `qa_billing_e2e_modules.sql` (~229–235):

```sql
DECLARE
    v_hash   VARCHAR2(128);
    v_token  VARCHAR2(64);
    v_status NUMBER;
    v_body   CLOB;
BEGIN
    SELECT external_reference INTO v_hash
      FROM org_subscription_invoice
     WHERE org_id_organization = 29
       AND status = 'PENDING'
     ORDER BY created_at DESC FETCH FIRST 1 ROW ONLY;

    v_token := pkg_aox_pagopar_api.fn_pagopar_sha1_token(
        fn_get_parameter('SUBSCRIPTION_PAGOPAR_PRIVATE_KEY') || v_hash
    );

    pkg_aox_subscription_billing_api.pr_subscription_webhook(
        '{"resultado":[{"hash_pedido":"' || v_hash || '","token":"' || v_token || '","pagado":true}]}',
        v_status,
        v_body
    );
    DBMS_OUTPUT.PUT_LINE('webhook status=' || v_status);
    COMMIT;
END;
/
```

No usar un hash inventado. No marcar `PAID` a mano con `UPDATE`.

### A4. Confirmar FE + correo

El mail **no** lo manda Astro ni el cron `poll-kude`. Camino feliz:

1. Factura `PAID` → `pr_dispatch_einvoice_outbox` llama a `ESIGN_WEBHOOK_URL` (`emit-invoice`) para **pedir** la emisión SIFEN.
2. El firmador firma, genera KuDE y encola `invoice.ready`.
3. El worker del firmador POSTea HMAC a ORDS:

```text
POST https://g9549f707e8ebfa-aoxdev.adb.sa-saopaulo-1.oraclecloudapps.com/ords/aoxdev/public/v1/esign/webhook
```

4. `pr_receive_esign_webhook` baja el XML, persiste artefactos (`pr_save_einvoice_artifacts`) y **encola el mail** (`pr_send_einvoice_email`).

No invocar `GET /api/internal/esign/poll-kude` ni esperar el cron de las 11:00 UTC. Eso es reconciliación vieja; el happy path no lo usa.

Poll SQL (30–120 s) hasta FE + mail:

```sql
SELECT id_invoice, invoice_type, status,
       einvoice_cdc, einvoice_cod_res, einvoice_status,
       einvoice_kude_url, einvoice_xml_sha256,
       einvoice_email_status, einvoice_email_to, einvoice_sent_at
  FROM org_subscription_invoice
 WHERE org_id_organization = 29
   AND invoice_type = 'SUBSCRIPTION'
 ORDER BY created_at DESC FETCH FIRST 1 ROW ONLY;
```

**Esperado:**

| Campo | Valor |
|---|---|
| `einvoice_cod_res` | `0260` |
| `einvoice_kude_url` | NOT NULL (la mandó el firmador en `invoice.ready`) |
| `einvoice_xml_sha256` | NOT NULL |
| `einvoice_email_status` | `SENT` (APEX Mail encoló; **no** prueba bandeja) |
| `einvoice_email_to` | `mike.sdk83@gmail.com` |
| Adjuntos | KuDE PDF + XML |

Si a los 2–3 minutos hay `0260` pero el mail sigue `PENDING`/`NONE`: el webhook del firmador no pegó. Verificar en aoxdev `ESIGN_WEBHOOK_SECRET` (seteado, no `PENDING`) y `ESIGN_API_KEY`, y en el panel esign que la URL activa sea el ORDS `/public/v1/esign/webhook` de aoxdev. **No** disparar `poll-kude` para “arreglarlo” en este pase.

Verificación humana: bandeja de `mike.sdk83@gmail.com`. `einvoice_email_status='SENT'` solo confirma `apex_mail.push_queue`.

---

## 5. Caso B — cancelar suscripción (rama aparte)

Hacerlo **después** del Caso A, o con un reset §3 + tarjeta si A no se corrió. **No** mezclar con el downgrade.

### B1. UI (periodo todavía vigente)

En `/panel/plan` → **Terminar / cancelar suscripción**.

SQL inmediato (todavía no vencer el periodo):

```sql
SELECT p.code AS plan_actual,
       pp.code AS pending_plan,
       s.auto_renew, s.canceled_at, s.status,
       s.current_period_end
  FROM org_subscription s
  JOIN ref_plan p ON p.id_plan = s.pln_id_plan
  LEFT JOIN ref_plan pp ON pp.id_plan = s.pending_pln_id_plan
 WHERE s.org_id_organization = 29;
```

**Esperado ahora:** plan sigue **Premium**, `pending_plan='FREE'`, `auto_renew=0`, `canceled_at` NOT NULL, `status='ACTIVE'`. Todavía se puede usar el panel hasta el fin de ciclo.

Si `current_period_end` ya está vencido al pulsar cancelar, `pr_cancel_subscription` **aplica ya** FREE/`READ_ONLY` y el ciclo no cobra. Por eso: **no** backdatear el periodo *antes* de cancelar en UI.

### B2. Aplicar la cancelación (SQL)

```sql
UPDATE org_subscription
   SET current_period_end = systimestamp - INTERVAL '1' SECOND
 WHERE org_id_organization = 29
   AND pending_pln_id_plan = (SELECT id_plan FROM ref_plan WHERE code = 'FREE');
COMMIT;

@@scripts/qa_billing_e2e_run_cycle.sql
```

**Esperado:**

- Plan **Continuidad** (`FREE`)
- `status='READ_ONLY'`
- `auto_renew=0`
- **sin** factura nueva de cobro
- addons ACTIVE cancelados **sin** crédito (si quedara alguno)

UI: el panel en modo continuidad / solo lectura.

---

## 6. Caso C — bajar Premium → Base (rama aparte)

**Reset §3** (y tarjeta si se borró) **antes** de este caso. Cancel y downgrade no conviven: un solo `pending_pln_id_plan`.

### C1. UI (periodo vigente)

En `/panel/plan` → **Pasar a Base** (acción `schedule`, no cobro inmediato).

SQL:

```sql
SELECT p.code AS plan_actual,
       pp.code AS pending_plan,
       s.auto_renew, s.account_balance,
       s.pending_plan_change_at, s.current_period_end
  FROM org_subscription s
  JOIN ref_plan p ON p.id_plan = s.pln_id_plan
  LEFT JOIN ref_plan pp ON pp.id_plan = s.pending_pln_id_plan
 WHERE s.org_id_organization = 29;
```

**Esperado ahora:** sigue **Premium**, `pending_plan='BASE'`, `auto_renew=1`, **sin** crédito de plan (`account_balance` no sube por bajar de plan).

### C2. Aplicar el downgrade + cobro de Base

El ciclo **primero** aplica el pending y **después** cobra el plan ya aplicado. Si el periodo está vencido, **en la misma corrida** se baja a Base **y** se cobra Base (129.000 Gs).

Como el Caso A pudo dejar una key `CYCLE:29:hoy` COMPLETED del cobro Premium, **borrarla** antes de este ciclo (si no, idempotencia del mismo día choca o hace replay):

```sql
DECLARE
    v_org NUMBER := 29;
BEGIN
    DELETE FROM api_idempotency_key
     WHERE scope_code = 'SUBSCRIPTION_CHARGE_TARGET'
       AND idem_key LIKE 'CYCLE:' || v_org || ':%';

    UPDATE org_subscription
       SET current_period_end = systimestamp - INTERVAL '1' SECOND,
           charge_retry_count = 0
     WHERE org_id_organization = v_org;

    COMMIT;
END;
/

@@scripts/qa_billing_e2e_run_cycle.sql
```

**Esperado:**

- Plan **Base**
- `pending_*` NULL
- Factura nueva `PAID` (tras webhook) de **129000** Gs
- `auto_renew=1`, `status='ACTIVE'`

Si se quiere **solo** ver el pending agendado sin cobro de Base, **no** correr C2.

---

## 7. Orden sugerido para una sesión

```text
Preflight §2
    → Reset §3 (periodo a +1 mes, sin módulos)
    → Caso A (tarjeta UI → backdate → ciclo → webhook Pagopar → FE firmador → invoice.ready → mail)
    → Caso B (cancelar UI → backdate → ciclo → Continuidad)
    → Reset §3 + tarjeta (si sigue)
    → Caso C (bajar UI → backdate + borrar CYCLE:hoy → ciclo → Base 129.000)
    → Teardown opcional
```

Teardown (solo al **cerrar** el pase, y solo si se pide):

1. En UI, eliminar tarjetas de la org fixture (revoca en Pagopar).
2. `@@scripts/qa_billing_e2e_cleanup.sql` — borra org 29. Abortará si el id es 1 o el nombre no es `QA Billing E2E`.

---

## 8. Qué hace el bot vs. qué hace un humano

| Paso | Bot (SQL / repos) | Humano |
|---|---|---|
| Preflight, reset, backdate, ciclo | Sí | — |
| Login + switch de org + `/panel/plan` | Sí si tiene browser | Preferible |
| PAN de prueba Pagopar | **No está en el repo** | Pedir / pegar la tarjeta sandbox |
| Iframe uPay (CVV, expiry) | Frágil en automatización | Completar el iframe |
| Webhook Pagopar | Poll SQL 30–120 s | Si no llega, revisar panel Pagopar |
| Webhook firmador `invoice.ready` | Poll `einvoice_email_status` | Si no llega, URL/secret en panel esign + ORDS `/public/v1/esign/webhook` |
| Bandeja de correo | Ver `einvoice_email_status` | Abrir Gmail y confirmar adjuntos |

---

## 9. Troubleshooting rápido

| Síntoma | Causa típica | Qué hacer |
|---|---|---|
| Ciclo “OK” y **cero** factura | `period_end` todavía futuro, `auto_renew=0`, `billing_exempt=1`, founder, o plan FREE | Revisar `org_subscription`; no fiarse del log SUCCESS |
| Factura `PENDING` eterna | Webhook no pegó | Ver `external_reference` + URL webhook aoxdev |
| `VALIDATION_ERROR` “facturación no configurada” | Keys Pagopar vacías | No deberían estarlo; verificar `LENGTH(param_value)=32` |
| Ciclo no corre: “solo admite la fixture” | `QA_BILLING_E2E_ORG_ID` ≠ org pedida | No ciclar otras orgs |
| Reintento mismo día no cobra (REPLAY silencioso) | Idempotencia `CYCLE:29:YYYYMMDD` ya `COMPLETED` | Borrar esa key **y** `charge_retry_count=0` |
| Ciclo falla con `"Ya hay un cobro en curso..."` | El intento anterior fue **rechazado por Pagopar** (tarjeta inválida) y la key quedó `IN_PROGRESS` a propósito | Borrar la key `CYCLE:29:YYYYMMDD` de `api_idempotency_key` y volver a correr el bloque de A2/C2 completo |
| Monto ≠ 229.000 | Módulos / storage / `ADDONS_BILLING_LIVE=1` / founder 50% | `DELETE org_addon`; flags en 0; `is_founder=0` |
| `/panel/plan` redirige al dashboard | UI billing oculta | Env staging: no `PUBLIC_SUBSCRIPTION_BILLING_UI=0` |
| Mail nunca llega | Firmador no entregó `invoice.ready`, HMAC inválido, o APEX Mail | URL/secret en panel esign; `ESIGN_WEBHOOK_SECRET` / `ESIGN_API_KEY` en aoxdev. No usar `poll-kude` |
| Iframe no vuelve a staging | Return URL mal | Verificar `PAGOPAR_UPAY_RETURN_URL` |

---

## 10. Archivos de referencia

| Path | Uso |
|---|---|
| `scripts/qa_billing_e2e_seed.sql` | Alta/reset fixture 29 (trae módulos: hay que borrarlos) |
| `scripts/qa_billing_e2e_run_cycle.sql` | Acelerador aislado |
| `scripts/qa_billing_e2e_cleanup.sql` | Borra la fixture (no a mitad de prueba) |
| `scripts/qa_billing_e2e_modules.sql` | **No usar** en este pase |
| `packages/PKG_AOX_SUBSCRIPTION_BILLING_API.pls` | Ciclo, cobro, cancel, change-plan, webhook Pagopar, `pr_receive_esign_webhook` (mail) |
| `migrations/20260905_esign_webhook_receiver.sql` | ORDS `POST /public/v1/esign/webhook` |
| `docs/ORDS_SUBSCRIPTION_BILLING.md` | Contrato de endpoints |
| `docs/DEPLOY_PAGOPAR.md` | uPay, webhook, return URL staging |
| `bookmate/src/pages/panel/plan.astro` + `src/scripts/plan-page.ts` | UI |
| `bookmate/src/config/feature-flags.ts` | Visibilidad de `/panel/plan` |

Siguiente pase (no documentado aquí): complementos (`/panel/complementos`) y addons de storage, con `ADDONS_BILLING_LIVE` y `qa_billing_e2e_modules.sql`.
