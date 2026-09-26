-- Convergencia de paquetes al HEAD del repo (paso 9 de docs/DEPLOY_PRODUCCION_2026-09.md).
-- Las migraciones compilan paquetes del HEAD que dependen de objetos de migraciones
-- posteriores; este paso los recompila a todos en el orden de install_all.sql
-- (FASES 3-5) mas los que install_all no incluye (ATC), y cierra con compile_schema.
-- Como AOXDEV / WKSP_AOX. Esperado al final: 0 filas INVALID.
-- Generado desde install_all.sql; si cambia el orden alli, regenerar.

SET SERVEROUTPUT ON SIZE UNLIMITED

@@../../functions/FN_GET_PARAMETER.pls
@@../../packages/PKG_AOX_UTIL.pls
@@../../packages/PKG_AOX_PUBLIC_DIRECTORY.pls
@@../../packages/PKG_AOX_JOB_WRAPPER.pls
@@../../packages/PKG_AOX_SESSION.pls
@@../../functions/FN_AOX_TENANT_VPD_PREDICATE.pls
@@../../packages/PKG_AOX_TENANT_VPD.pls
@@../../packages/PKG_AOX_JWT.pls
@@../../packages/PKG_AOX_AUTH.pls
@@../../packages/PKG_AOX_ADDON_ELIGIBILITY.pls
@@../../packages/PKG_AOX_PERMISSION_API_SPEC.pls
@@../../packages/PKG_AOX_SUBSCRIPTION_API.pls
@@../../packages/PKG_AOX_PERMISSION_API.pls
@@../../packages/PKG_AOX_PAYMENT_SETTINGS_API.pls
@@../../packages/PKG_AOX_BILLING_PROFILE_API.pls
@@../../packages/PKG_AOX_PAYMENTS_API.pls
@@../../packages/PKG_AOX_REFUND_CLAIMS_API.pls
@@../../packages/PKG_AOX_REFUND_COMPENSATION_API.pls
@@../../packages/PKG_AOX_REFUND_DISPUTES_API.pls
@@../../packages/PKG_AOX_OPS_ADMIN_BRIDGE.pls
@@../../packages/PKG_AOX_BUCKET.pls
@@../../packages/PKG_AOX_META_API.pls
@@../../packages/PKG_AOX_FCM_API.pls
@@../../packages/PKG_AOX_INBOX_API.pls
@@../../packages/PKG_AOX_FCM_API.pls
@@../../packages/PKG_AOX_PUSH_CAMPAIGN.pls
@@../../packages/PKG_AOX_AUTH_API.pls
@@../../packages/PKG_AOX_CATALOG_API.pls
@@../../packages/PKG_AOX_SPECIALTY_API.pls
@@../../packages/PKG_AOX_SERVICE_API.pls
@@../../packages/PKG_AOX_LOCATION_API.pls
@@../../packages/PKG_AOX_LOCATION_CLOSURE_API.pls
@@../../packages/PKG_AOX_SCHEDULE_API.pls
@@../../packages/PKG_AOX_SCHEDULE_EXCEPTION_API.pls
@@../../packages/PKG_AOX_CUSTOMER_API.pls
@@../../packages/PKG_AOX_DASHBOARD_API.pls
@@../../packages/PKG_AOX_INTEGRATION_API.pls
@@../../packages/PKG_AOX_ORG_INTEGRATION_API.pls
@@../../packages/PKG_AOX_PAGOPAR_API.pls
@@../../packages/PKG_AOX_SUBSCRIPTION_BILLING_API.pls
@@../../packages/PKG_AOX_ADDON_API.pls
@@../../packages/PKG_AOX_ODONTOGRAM_API.pls
@@../../packages/PKG_AOX_BODY_MAP_API.pls
@@../../packages/PKG_AOX_USER_API.pls
@@../../packages/PKG_AOX_WORKSPACE_API.pls
@@../../packages/PKG_AOX_PROFESSIONAL_API.pls
@@../../packages/PKG_AOX_APPOINTMENT_API.pls
@@../../packages/PKG_AOX_PUBLIC_BOOKING_API.pls
@@../../packages/PKG_AOX_IA_MANAGER.pls
@@../../packages/PKG_AOX_VECTOR_SEARCH.pls
@@../../packages/PKG_AOX_IA_API.pls
@@../../packages/PKG_AOX_AI_CONTEXT.pls
@@../../packages/PKG_AOX_AI_TOOLS.pls
@@../../packages/PKG_AOX_AI_AGENT_SETUP.pls
@@../../packages/PKG_AOX_CHAT_MANAGER.pls
@@../../packages/PKG_AOX_CHAT_API.pls
@@../../packages/PKG_AOX_JOB_WRAPPER.pls

-- No estan en install_all.sql
@@../../packages/PKG_AOX_ATC_KB.pls
@@../../packages/PKG_AOX_ATC_CHAT.pls
@@../../packages/PKG_AOX_ATC_CHAT_API.pls

EXEC DBMS_UTILITY.compile_schema(USER, compile_all => FALSE);

PROMPT === Objetos INVALID restantes (esperado: ninguno)
SELECT object_type, object_name FROM user_objects WHERE status = 'INVALID' ORDER BY 1, 2;
