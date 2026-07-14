
--------------------------------------------------------------------------------
-- FASE 1: TABLAS
--------------------------------------------------------------------------------
PROMPT --- FASE 1: Tablas ---

PROMPT [1/29] departments
@@tables\DEPARTMENTS.sql

PROMPT [2/29] cities
@@tables\CITIES.sql

PROMPT [3/29] org_specialty
@@tables\ORG_SPECIALTY.sql

PROMPT [4/29] role
@@tables\ROLE.sql

PROMPT [5/29] app_parameter
@@tables\APP_PARAMETER.sql

PROMPT [6/29] organization
@@tables\ORGANIZATION.sql

PROMPT [7/29] specialty
@@tables\SPECIALTY.sql

PROMPT [8/29] service
@@tables\SERVICE.sql

PROMPT [9/31] platform_user
@@tables\PLATFORM_USER.sql

PROMPT [10/31] org_member
@@tables\ORG_MEMBER.sql

PROMPT [11/31] customer
@@tables\CUSTOMER.sql

PROMPT [12/31] location
@@tables\LOCATION.sql

PROMPT [13/31] professional
@@tables\PROFESSIONAL.sql

PROMPT [13/29] professional_image
@@tables\PROFESSIONAL_IMAGE.sql

PROMPT [14/29] professional_service  *** REQUERIDO: copiar si no existe ***
@@tables\PROFESSIONAL_SERVICE.sql

PROMPT [15/31] professional_schedule
@@tables\PROFESSIONAL_SCHEDULE.sql

PROMPT [16/31] professional_schedule_exception
@@tables\PROFESSIONAL_SCHEDULE_EXCEPTION.sql

PROMPT [17/31] professional_schedule_exception_slot
@@tables\PROFESSIONAL_SCHEDULE_EXCEPTION_SLOT.sql

PROMPT [18/31] appointment
@@tables\APPOINTMENT.sql

PROMPT [19/31] app_user_email_verification
@@tables\APP_USER_EMAIL_VERIFICATION.sql

PROMPT [20/31] app_user_pwd_reset
@@tables\APP_USER_PWD_RESET.sql

PROMPT [21/31] app_user_session
@@tables\APP_USER_SESSION.sql

PROMPT [22/31] user_integration
@@tables\USER_INTEGRATION.sql

PROMPT [23/34] ref_pagopar_forma_pago
@@tables\REF_PAGOPAR_FORMA_PAGO.sql

PROMPT [24/34] org_integration
@@tables\ORG_INTEGRATION.sql

PROMPT [25/34] payment_transaction
@@tables\PAYMENT_TRANSACTION.sql

PROMPT [26/34] user_fcm_devices
@@tables\USER_FCM_DEVICES.sql

PROMPT [24/34] ref_booking_slot_interval
@@tables\REF_BOOKING_SLOT_INTERVAL.sql

PROMPT [25/34] ref_reminder_hours
@@tables\REF_REMINDER_HOURS.sql

PROMPT [26/34] ref_cancel_wait_hours
@@tables\REF_CANCEL_WAIT_HOURS.sql

PROMPT [27/34] workspace_setting
@@tables\WORKSPACE_SETTING.sql

PROMPT [28/34] ai_chat_session
@@tables\AI_CHAT_SESSION.sql

PROMPT [29/34] ai_chat_message
@@tables\AI_CHAT_MESSAGE.sql

PROMPT [30/34] aox_api_log
@@tables\AOX_API_LOG.sql

PROMPT [31/34] aox_ai_log
@@tables\AOX_AI_LOG.sql

PROMPT [32/34] aox_whatsapp_template_log
@@tables\AOX_WHATSAPP_TEMPLATE_LOG.sql

PROMPT [33/34] aox_push_fcm_log
@@tables\AOX_PUSH_FCM_LOG.sql

PROMPT [34/35] aox_fcm_log
@@tables\AOX_FCM_LOG.sql

PROMPT [35/35] org_entity_embedding
@@tables\ORG_ENTITY_EMBEDDING.sql

PROMPT --- Campanas push admin (Hasel_admn) ---
PROMPT [35b] push_var_catalog
@@tables\PUSH_VAR_CATALOG.sql

PROMPT [35c] push_campaign
@@tables\PUSH_CAMPAIGN.sql

PROMPT [35d] push_campaign_var
@@tables\PUSH_CAMPAIGN_VAR.sql

PROMPT [35e] push_campaign_delivery
@@tables\PUSH_CAMPAIGN_DELIVERY.sql

PROMPT --- Suscripcion y planes (Fase 1) ---
PROMPT [36/41] ref_plan
@@tables\REF_PLAN.sql

PROMPT [37/41] ref_plan_feature
@@tables\REF_PLAN_FEATURE.sql

PROMPT [38/41] ref_storage_addon
@@tables\REF_STORAGE_ADDON.sql

PROMPT [39/41] org_subscription
@@tables\ORG_SUBSCRIPTION.sql

PROMPT [40/41] org_storage_addon
@@tables\ORG_STORAGE_ADDON.sql

PROMPT [41/43] org_subscription_invoice
@@tables\ORG_SUBSCRIPTION_INVOICE.sql

PROMPT [41b/43] org_payment_card (Pagopar pago-recurrente / catastro de tarjetas)
@@tables\ORG_PAYMENT_CARD.sql

PROMPT --- Historial por cita + adjuntos (Fase 4) ---
PROMPT [42/44] appointment_session_record
@@tables\APPOINTMENT_SESSION_RECORD.sql

PROMPT [43/44] appointment_attachment
@@tables\APPOINTMENT_ATTACHMENT.sql

PROMPT --- Cobros SIPAP (Fase A) ---
PROMPT [44/45] ref_sipap_bank
@@tables\REF_SIPAP_BANK.sql

PROMPT [45/45] org_payment_settings
@@tables\ORG_PAYMENT_SETTINGS.sql

@@tables\ORG_REFUND_CLAIM.sql

PROMPT --- Seed catalogo de bancos SIPAP Paraguay ---
MERGE INTO ref_sipap_bank t
USING (
  SELECT 1  AS id_bank, 'CONTINENTAL' AS code, 'Banco Continental' AS name, 1 AS is_active, 10  AS sort_order FROM dual UNION ALL
  SELECT 2,  'ITAU',          'Banco Itaú',                 1, 20  FROM dual UNION ALL
  SELECT 3,  'FAMILIAR',      'Banco Familiar',             1, 30  FROM dual UNION ALL
  SELECT 4,  'GNB',           'Banco GNB',                  1, 40  FROM dual UNION ALL
  SELECT 5,  'ATLAS',         'Banco Atlas',                1, 50  FROM dual UNION ALL
  SELECT 6,  'UENO',          'Ueno Bank',                  1, 60  FROM dual UNION ALL
  SELECT 7,  'BASA',          'Banco Basa',                 1, 70  FROM dual UNION ALL
  SELECT 8,  'VISION',        'Visión Banco',               1, 80  FROM dual UNION ALL
  SELECT 9,  'INTERFISA',     'Interfisa',                  1, 90  FROM dual UNION ALL
  SELECT 10, 'SOLAR',         'Solar Bank',                 1, 100 FROM dual UNION ALL
  SELECT 11, 'SUDAMERIS',     'Banco Sudameris',            1, 110 FROM dual UNION ALL
  SELECT 12, 'BNF',           'Banco Nacional de Fomento',  1, 120 FROM dual UNION ALL
  SELECT 13, 'DO_BRASIL',     'Banco do Brasil',            1, 130 FROM dual UNION ALL
  SELECT 14, 'CITIBANK',      'Citibank',                   1, 140 FROM dual UNION ALL
  SELECT 15, 'REGIONAL',      'Banco Regional',             1, 150 FROM dual UNION ALL
  SELECT 16, 'ZETA',          'Banco Zeta',                 1, 160 FROM dual UNION ALL
  SELECT 17, 'TU_FINANCIERA', 'Tu Financiera',              1, 170 FROM dual UNION ALL
  SELECT 18, 'FINANCIERA_RIO','Financiera Río',             1, 180 FROM dual
) s
ON (t.id_bank = s.id_bank)
WHEN MATCHED THEN UPDATE SET
  t.code = s.code, t.name = s.name, t.is_active = s.is_active, t.sort_order = s.sort_order
WHEN NOT MATCHED THEN
  INSERT (id_bank, code, name, is_active, sort_order)
  VALUES (s.id_bank, s.code, s.name, s.is_active, s.sort_order);
COMMIT;

PROMPT --- Seed catalogo de planes / features / storage addons ---
MERGE INTO ref_plan t
USING (
  SELECT 1 AS id_plan, 'BASE'    AS code, 'Base'    AS name,  99000 AS price_amount, 'PYG' AS currency, 'MONTHLY' AS billing_period, 0          AS storage_limit_bytes, 1 AS is_active, 1 AS sort_order FROM dual UNION ALL
  SELECT 2 AS id_plan, 'PREMIUM' AS code, 'Premium' AS name, 229000 AS price_amount, 'PYG' AS currency, 'MONTHLY' AS billing_period, 5368709120 AS storage_limit_bytes, 1 AS is_active, 2 AS sort_order FROM dual
) s
ON (t.id_plan = s.id_plan)
WHEN MATCHED THEN UPDATE SET
  t.code = s.code, t.name = s.name, t.price_amount = s.price_amount, t.currency = s.currency,
  t.billing_period = s.billing_period, t.storage_limit_bytes = s.storage_limit_bytes,
  t.is_active = s.is_active, t.sort_order = s.sort_order
WHEN NOT MATCHED THEN
  INSERT (id_plan, code, name, price_amount, currency, billing_period, storage_limit_bytes, is_active, sort_order)
  VALUES (s.id_plan, s.code, s.name, s.price_amount, s.currency, s.billing_period, s.storage_limit_bytes, s.is_active, s.sort_order);
COMMIT;

MERGE INTO ref_plan_feature t
USING (
  SELECT 1 AS pln_id_plan, 'WEB_BOOKING'             AS feature_code FROM dual UNION ALL
  SELECT 1, 'NOTIFICATIONS'           FROM dual UNION ALL
  SELECT 1, 'CUSTOMERS'               FROM dual UNION ALL
  SELECT 1, 'SERVICES'                FROM dual UNION ALL
  SELECT 1, 'TEAM_MULTI_BRANCH'       FROM dual UNION ALL
  SELECT 1, 'AI_MORNING_DIGEST'       FROM dual UNION ALL
  SELECT 2, 'WEB_BOOKING'             FROM dual UNION ALL
  SELECT 2, 'NOTIFICATIONS'           FROM dual UNION ALL
  SELECT 2, 'CUSTOMERS'               FROM dual UNION ALL
  SELECT 2, 'SERVICES'                FROM dual UNION ALL
  SELECT 2, 'TEAM_MULTI_BRANCH'       FROM dual UNION ALL
  SELECT 2, 'AI_MORNING_DIGEST'       FROM dual UNION ALL
  SELECT 2, 'VOICE_RECEPTION'         FROM dual UNION ALL
  SELECT 2, 'DEPOSIT_COLLECTION'      FROM dual UNION ALL
  SELECT 2, 'APPOINTMENT_HISTORY'     FROM dual UNION ALL
  SELECT 2, 'PROFITABILITY_ANALYTICS' FROM dual
) s
ON (t.pln_id_plan = s.pln_id_plan AND t.feature_code = s.feature_code)
WHEN NOT MATCHED THEN
  INSERT (pln_id_plan, feature_code, is_enabled) VALUES (s.pln_id_plan, s.feature_code, 1);
COMMIT;

MERGE INTO ref_storage_addon t
USING (
  SELECT 1 AS id_storage_addon, 'STORAGE_5GB'  AS code, '+5 GB de almacenamiento'  AS name, 5368709120  AS extra_bytes, 30000 AS price_amount, 'PYG' AS currency, 'MONTHLY' AS billing_period, 1 AS is_active, 1 AS sort_order FROM dual UNION ALL
  SELECT 2 AS id_storage_addon, 'STORAGE_15GB' AS code, '+15 GB de almacenamiento' AS name, 16106127360 AS extra_bytes, 70000 AS price_amount, 'PYG' AS currency, 'MONTHLY' AS billing_period, 1 AS is_active, 2 AS sort_order FROM dual
) s
ON (t.id_storage_addon = s.id_storage_addon)
WHEN MATCHED THEN UPDATE SET
  t.code = s.code, t.name = s.name, t.extra_bytes = s.extra_bytes, t.price_amount = s.price_amount,
  t.currency = s.currency, t.billing_period = s.billing_period, t.is_active = s.is_active, t.sort_order = s.sort_order
WHEN NOT MATCHED THEN
  INSERT (id_storage_addon, code, name, extra_bytes, price_amount, currency, billing_period, is_active, sort_order)
  VALUES (s.id_storage_addon, s.code, s.name, s.extra_bytes, s.price_amount, s.currency, s.billing_period, s.is_active, s.sort_order);
COMMIT;

PROMPT --- Cargar datos semilla (role, app_parameter, org_specialty) manualmente si aplica ---

--------------------------------------------------------------------------------
-- FASE 2: FUNCIONES
--------------------------------------------------------------------------------
PROMPT --- FASE 2: Funciones ---

@@functions\FN_GET_PARAMETER.pls

--------------------------------------------------------------------------------
-- FASE 3: PAQUETES (nucleo)
--------------------------------------------------------------------------------
PROMPT --- FASE 3: Paquetes - nucleo ---

@@packages\PKG_AOX_UTIL.pls
@@packages\PKG_AOX_JWT.pls
@@packages\PKG_AOX_AUTH.pls
-- SUBSCRIPTION_API en nucleo: BUCKET y otros paquetes dependen de sus gates/entitlements.
@@packages\PKG_AOX_SUBSCRIPTION_API.pls
-- Cobros SIPAP (Fase A): SERVICE_API depende de fn_org_deposits_enabled.
@@packages\PKG_AOX_PAYMENT_SETTINGS_API.pls
@@packages\PKG_AOX_PAYMENTS_API.pls

@@packages\PKG_AOX_REFUND_CLAIMS_API.pls
@@packages\PKG_AOX_BUCKET.pls
@@packages\PKG_AOX_META_API.pls
@@packages\PKG_AOX_FCM_API.pls
@@packages\PKG_AOX_PUSH_CAMPAIGN.pls

--------------------------------------------------------------------------------
-- FASE 4: PAQUETES (APIs)
--------------------------------------------------------------------------------
PROMPT --- FASE 4: Paquetes - APIs ---

@@packages\PKG_AOX_AUTH_API.pls
@@packages\PKG_AOX_CATALOG_API.pls
@@packages\PKG_AOX_SPECIALTY_API.pls
@@packages\PKG_AOX_SERVICE_API.pls
@@packages\PKG_AOX_LOCATION_API.pls
@@packages\PKG_AOX_SCHEDULE_API.pls
@@packages\PKG_AOX_SCHEDULE_EXCEPTION_API.pls
@@packages\PKG_AOX_CUSTOMER_API.pls
@@packages\PKG_AOX_DASHBOARD_API.pls
@@packages\PKG_AOX_INTEGRATION_API.pls
@@packages\PKG_AOX_ORG_INTEGRATION_API.pls
@@packages\PKG_AOX_PAGOPAR_API.pls
-- Facturacion comercial de suscripcion (Fase 5): depende de SUBSCRIPTION_API + PAGOPAR_API.
@@packages\PKG_AOX_SUBSCRIPTION_BILLING_API.pls
@@packages\PKG_AOX_USER_API.pls
@@packages\PKG_AOX_WORKSPACE_API.pls
@@packages\PKG_AOX_PROFESSIONAL_API.pls
@@packages\PKG_AOX_APPOINTMENT_API.pls
@@packages\PKG_AOX_PUBLIC_BOOKING_API.pls

--------------------------------------------------------------------------------
-- FASE 5: PAQUETES (IA)
--------------------------------------------------------------------------------
PROMPT --- FASE 5: Paquetes - IA ---

@@packages\PKG_AOX_IA_MANAGER.pls
@@packages\PKG_AOX_VECTOR_SEARCH.pls
@@triggers\TRG_VECTOR_EMBEDDING_SYNC.sql
@@packages\PKG_AOX_IA_API.pls
@@packages\PKG_AOX_AI_CONTEXT.pls
@@packages\PKG_AOX_AI_TOOLS.pls
@@packages\PKG_AOX_AI_AGENT_SETUP.pls
@@packages\PKG_AOX_CHAT_MANAGER.pls
@@packages\PKG_AOX_CHAT_API.pls

--------------------------------------------------------------------------------
-- FASE 6 (OPCIONAL): Contexto seguro para agente IA
-- Requiere CREATE ANY CONTEXT o ejecutar como ADMIN
--------------------------------------------------------------------------------
/*
PROMPT --- FASE 6 (opcional): Contexto AOX_AI_CTX ---
CREATE OR REPLACE CONTEXT aox_ai_ctx USING pkg_aox_ai_context;
*/

--------------------------------------------------------------------------------
-- FASE 7 (OPCIONAL): Setup Azure / DBMS_CLOUD_AI_AGENT
-- No esta en aox-dev; usar desde bookmate\aox\paquetes\ si aplica:
--   GRANT_HASEL_AI_AGENT_PRIVS.sql  (como ADMIN)
--   GRANT_HASEL_AI_AGENT_ACL.sql     (como ADMIN)
--   SETUP_HASEL_AI_AGENT.sql         (como WKSP_AOX)
--   CREATE_ATTENDANCE_REMINDER_JOBS.sql
--------------------------------------------------------------------------------

PROMPT --- Recompilacion de objetos invalidos ---
BEGIN
    DBMS_UTILITY.compile_schema(
        schema    => USER,
        compile_all => FALSE
    );
END;
/

PROMPT --- Objetos invalidos restantes ---
SELECT object_type, object_name, status
  FROM user_objects
 WHERE status = 'INVALID'
   AND object_type IN ('PACKAGE', 'PACKAGE BODY', 'FUNCTION', 'PROCEDURE', 'VIEW', 'TRIGGER')
 ORDER BY object_type, object_name;

PROMPT ============================================================
PROMPT AOX-DEV - Instalacion finalizada
PROMPT ============================================================