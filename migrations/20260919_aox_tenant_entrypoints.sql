-- RLS/VPD oleada 3 (entrypoints): choke JWT/publico/webhook/jobs/AI.
-- RESULT_CACHE tenant fuera. Dual-write set_org desde PKG_AOX_AI_CONTEXT.
-- Como AOXDEV. Idempotente (CREATE OR REPLACE de paquetes).

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260919_aox_tenant_entrypoints ===

@@../packages/PKG_AOX_UTIL.pls
@@../packages/PKG_AOX_SESSION.pls
@@../packages/PKG_AOX_AI_CONTEXT.pls
@@../packages/PKG_AOX_AUTH_API.pls
@@../packages/PKG_AOX_PERMISSION_API.pls
@@../packages/PKG_AOX_CUSTOMER_API.pls
@@../packages/PKG_AOX_APPOINTMENT_API.pls
@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls
@@../packages/PKG_AOX_PAYMENTS_API.pls
@@../packages/PKG_AOX_PAYMENT_SETTINGS_API.pls
@@../packages/PKG_AOX_SUBSCRIPTION_API.pls
@@../packages/PKG_AOX_SUBSCRIPTION_BILLING_API.pls
@@../packages/PKG_AOX_ADDON_API.pls
@@../packages/PKG_AOX_WORKSPACE_API.pls
@@../packages/PKG_AOX_LOCATION_API.pls
@@../packages/PKG_AOX_LOCATION_CLOSURE_API.pls
@@../packages/PKG_AOX_PROFESSIONAL_API.pls
@@../packages/PKG_AOX_SERVICE_API.pls
@@../packages/PKG_AOX_SCHEDULE_API.pls
@@../packages/PKG_AOX_SCHEDULE_EXCEPTION_API.pls
@@../packages/PKG_AOX_SPECIALTY_API.pls
@@../packages/PKG_AOX_USER_API.pls
@@../packages/PKG_AOX_BILLING_PROFILE_API.pls
@@../packages/PKG_AOX_ORG_INTEGRATION_API.pls
@@../packages/PKG_AOX_INTEGRATION_API.pls
@@../packages/PKG_AOX_FCM_API.pls
@@../packages/PKG_AOX_INBOX_API.pls
@@../packages/PKG_AOX_DASHBOARD_API.pls
@@../packages/PKG_AOX_CHAT_API.pls
@@../packages/PKG_AOX_ATC_CHAT_API.pls
@@../packages/PKG_AOX_IA_API.pls
@@../packages/PKG_AOX_ODONTOGRAM_API.pls
@@../packages/PKG_AOX_BODY_MAP_API.pls
@@../packages/PKG_AOX_REFUND_CLAIMS_API.pls
@@../packages/PKG_AOX_REFUND_DISPUTES_API.pls
@@../packages/PKG_AOX_OPS_ADMIN_BRIDGE.pls
@@../packages/PKG_AOX_META_API.pls
@@../packages/PKG_AOX_VECTOR_SEARCH.pls
@@../packages/PKG_AOX_CATALOG_API.pls
@@../packages/PKG_AOX_PUSH_CAMPAIGN.pls
@@../packages/PKG_AOX_REFUND_COMPENSATION_API.pls
@@../packages/PKG_AOX_CHAT_MANAGER.pls

PROMPT --- Probe RESULT_CACHE tenant ---
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_cnt
      FROM user_procedures
     WHERE object_name = 'PKG_AOX_UTIL'
       AND procedure_name IN (
            'FN_GET_SCHEDULE_EXCEPTION_TYPE',
            'FN_IS_LOCATION_CLOSED_FULL_DAY',
            'FN_GET_ORG_BOOKING_SLOT_MINUTES'
           )
       AND result_cache = 'YES';

    IF v_cnt > 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe RESULT_CACHE: quedan ' || v_cnt || ' funciones tenant cacheadas');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe RESULT_CACHE tenant = NO OK');
END;
/

PROMPT --- Probe choke JWT / dual-write AI ---
DECLARE
    v_jwt NUMBER;
    v_ai  NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_jwt
      FROM user_procedures
     WHERE object_name = 'PKG_AOX_SESSION'
       AND procedure_name = 'PR_BIND_TENANT_FROM_JWT';
    IF v_jwt = 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: falta pr_bind_tenant_from_jwt');
    END IF;

    SELECT COUNT(*)
      INTO v_ai
      FROM user_source
     WHERE name = 'PKG_AOX_AI_CONTEXT'
       AND type = 'PACKAGE BODY'
       AND UPPER(text) LIKE '%PKG_AOX_SESSION.SET_ORG%';
    IF v_ai = 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: PKG_AOX_AI_CONTEXT no hace dual-write set_org');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe choke JWT + dual-write AI OK');
END;
/
