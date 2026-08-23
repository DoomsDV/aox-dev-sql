-- Migracion: interruptor global del cobro de suscripcion Hasel
--
-- Contexto del pase a produccion: se despliega toda la infraestructura de planes
-- (necesaria porque los paquetes nuevos consultan fn_org_has_feature) pero todavia
-- no se cobra. Las organizaciones existentes quedan FOUNDER + billing_exempt por el
-- backfill de 20260709_subscription_plans_phase1.sql.
--
-- Sin este flag, las organizaciones NUEVAS entrarian en TRIAL de 14 dias y al vencer
-- el backend les bloquea escritura y reserva publica, sin checkout habilitado donde
-- regularizar. Con BILLING_ENABLED = 0 nacen FOUNDER exentas.
--
-- Para habilitar el cobro (junto con las keys SUBSCRIPTION_PAGOPAR_* y el job
-- HASEL_SUBSCRIPTION_BILLING_CYCLE de 20260711_subscription_recurring_job.sql):
--   UPDATE app_parameter SET param_value = '1' WHERE param_key = 'BILLING_ENABLED';
--   COMMIT;

PROMPT === 1. Parametro BILLING_ENABLED ===

MERGE INTO app_parameter t
USING (
  SELECT 'BILLING_ENABLED' AS param_key,
         '0'               AS param_value,
         '1=cobrar suscripcion Hasel (trial 14 dias + job de cobro). 0=sin cobro: las organizaciones nuevas nacen FOUNDER exentas.' AS description
    FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN
  INSERT (param_key, param_value, description)
  VALUES (s.param_key, s.param_value, s.description);

COMMIT;

PROMPT === 2. Paquete de suscripcion (fn_billing_enabled + pr_ensure_trial_subscription) ===

@@../packages/PKG_AOX_SUBSCRIPTION_API.pls

PROMPT === 3. Recompilar dependientes ===
-- El cambio de spec de PKG_AOX_SUBSCRIPTION_API invalida a todos los paquetes que
-- consultan entitlements (AUTH_API, BUCKET, PAYMENTS_API, PUBLIC_BOOKING_API, etc.).

BEGIN
  DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === Migracion BILLING_ENABLED finalizada ===
