-- Migracion: Fase 1 - Suscripcion base (planes, features, storage addons, facturacion)
-- Roadmap Hasel: Premium + Planes + Historial
-- Crea las tablas (ejecucion unica) y carga seed via MERGE + backfill de founders
-- (estos ultimos son idempotentes: re-ejecutar no duplica).
--
-- Constantes de storage:
--   5 GB  = 5  * 1073741824 = 5368709120 bytes
--   15 GB = 15 * 1073741824 = 16106127360 bytes

--------------------------------------------------------------------------------
PROMPT === 1. Tablas de referencia y de organizacion ===
--------------------------------------------------------------------------------

@@../tables/REF_PLAN.sql
@@../tables/REF_PLAN_FEATURE.sql
@@../tables/REF_STORAGE_ADDON.sql
@@../tables/ORG_SUBSCRIPTION.sql
@@../tables/ORG_STORAGE_ADDON.sql
@@../tables/ORG_SUBSCRIPTION_INVOICE.sql

--------------------------------------------------------------------------------
PROMPT === 2. Seed de planes comerciales (BASE, PREMIUM) ===
--------------------------------------------------------------------------------

MERGE INTO ref_plan t
USING (
  SELECT 1 AS id_plan, 'BASE'    AS code, 'Base'    AS name,  99000 AS price_amount, 'PYG' AS currency, 'MONTHLY' AS billing_period, 0          AS storage_limit_bytes, 1 AS is_active, 1 AS sort_order FROM dual UNION ALL
  SELECT 2 AS id_plan, 'PREMIUM' AS code, 'Premium' AS name, 229000 AS price_amount, 'PYG' AS currency, 'MONTHLY' AS billing_period, 5368709120 AS storage_limit_bytes, 1 AS is_active, 2 AS sort_order FROM dual
) s
ON (t.id_plan = s.id_plan)
WHEN MATCHED THEN UPDATE SET
  t.code                = s.code,
  t.name                = s.name,
  t.price_amount        = s.price_amount,
  t.currency            = s.currency,
  t.billing_period      = s.billing_period,
  t.storage_limit_bytes = s.storage_limit_bytes,
  t.is_active           = s.is_active,
  t.sort_order          = s.sort_order
WHEN NOT MATCHED THEN
  INSERT (id_plan, code, name, price_amount, currency, billing_period, storage_limit_bytes, is_active, sort_order)
  VALUES (s.id_plan, s.code, s.name, s.price_amount, s.currency, s.billing_period, s.storage_limit_bytes, s.is_active, s.sort_order);

COMMIT;

--------------------------------------------------------------------------------
PROMPT === 3. Seed de entitlements por plan ===
--------------------------------------------------------------------------------

MERGE INTO ref_plan_feature t
USING (
  -- BASE (id_plan = 1)
  SELECT 1 AS pln_id_plan, 'WEB_BOOKING'            AS feature_code FROM dual UNION ALL
  SELECT 1, 'NOTIFICATIONS'          FROM dual UNION ALL
  SELECT 1, 'CUSTOMERS'              FROM dual UNION ALL
  SELECT 1, 'SERVICES'              FROM dual UNION ALL
  SELECT 1, 'TEAM_MULTI_BRANCH'      FROM dual UNION ALL
  SELECT 1, 'AI_MORNING_DIGEST'      FROM dual UNION ALL
  SELECT 1, 'PROFITABILITY_ANALYTICS' FROM dual UNION ALL
  -- PREMIUM (id_plan = 2): todo lo de Base + extras
  SELECT 2, 'WEB_BOOKING'            FROM dual UNION ALL
  SELECT 2, 'NOTIFICATIONS'          FROM dual UNION ALL
  SELECT 2, 'CUSTOMERS'              FROM dual UNION ALL
  SELECT 2, 'SERVICES'              FROM dual UNION ALL
  SELECT 2, 'TEAM_MULTI_BRANCH'      FROM dual UNION ALL
  SELECT 2, 'AI_MORNING_DIGEST'      FROM dual UNION ALL
  SELECT 2, 'VOICE_RECEPTION'        FROM dual UNION ALL
  SELECT 2, 'DEPOSIT_COLLECTION'     FROM dual UNION ALL
  SELECT 2, 'APPOINTMENT_HISTORY'    FROM dual UNION ALL
  SELECT 2, 'PROFITABILITY_ANALYTICS' FROM dual
) s
ON (t.pln_id_plan = s.pln_id_plan AND t.feature_code = s.feature_code)
WHEN NOT MATCHED THEN
  INSERT (pln_id_plan, feature_code, is_enabled)
  VALUES (s.pln_id_plan, s.feature_code, 1);

COMMIT;

--------------------------------------------------------------------------------
PROMPT === 4. Seed de paquetes de storage adicional ===
--------------------------------------------------------------------------------

MERGE INTO ref_storage_addon t
USING (
  SELECT 1 AS id_storage_addon, 'STORAGE_5GB'  AS code, '+5 GB de almacenamiento'  AS name, 5368709120  AS extra_bytes, 30000 AS price_amount, 'PYG' AS currency, 'MONTHLY' AS billing_period, 1 AS is_active, 1 AS sort_order FROM dual UNION ALL
  SELECT 2 AS id_storage_addon, 'STORAGE_15GB' AS code, '+15 GB de almacenamiento' AS name, 16106127360 AS extra_bytes, 70000 AS price_amount, 'PYG' AS currency, 'MONTHLY' AS billing_period, 1 AS is_active, 2 AS sort_order FROM dual
) s
ON (t.id_storage_addon = s.id_storage_addon)
WHEN MATCHED THEN UPDATE SET
  t.code           = s.code,
  t.name           = s.name,
  t.extra_bytes    = s.extra_bytes,
  t.price_amount   = s.price_amount,
  t.currency       = s.currency,
  t.billing_period = s.billing_period,
  t.is_active      = s.is_active,
  t.sort_order     = s.sort_order
WHEN NOT MATCHED THEN
  INSERT (id_storage_addon, code, name, extra_bytes, price_amount, currency, billing_period, is_active, sort_order)
  VALUES (s.id_storage_addon, s.code, s.name, s.extra_bytes, s.price_amount, s.currency, s.billing_period, s.is_active, s.sort_order);

COMMIT;

--------------------------------------------------------------------------------
PROMPT === 5. Backfill founders: orgs existentes -> Premium (FOUNDER, billing_exempt) ===
--------------------------------------------------------------------------------
-- Toda organizacion sin suscripcion pasa a Premium como early adopter:
--   status = FOUNDER, is_founder = 1, billing_exempt = 1
--   storage_limit_bytes = storage del plan Premium (5 GB)

INSERT INTO org_subscription (
  org_id_organization, pln_id_plan, status, is_founder, billing_exempt,
  storage_used_bytes, storage_limit_bytes
)
SELECT o.id_organization,
       2                 AS pln_id_plan,
       'FOUNDER'         AS status,
       1                 AS is_founder,
       1                 AS billing_exempt,
       0                 AS storage_used_bytes,
       (SELECT storage_limit_bytes FROM ref_plan WHERE id_plan = 2) AS storage_limit_bytes
  FROM organization o
 WHERE NOT EXISTS (
         SELECT 1
           FROM org_subscription s
          WHERE s.org_id_organization = o.id_organization
       );

COMMIT;

PROMPT === Fase 1 (suscripcion base) finalizada ===
