-- Migracion: Fase 5 - Facturacion comercial de suscripcion (planes, checkout, addons)
-- Roadmap Hasel: Premium + Planes + Historial
--
-- Contenido:
--   * PKG_AOX_SUBSCRIPTION_BILLING_API: catalogo de planes/addons, checkout Pagopar
--     de suscripcion (facturacion de plataforma, separado de senas de citas),
--     cambio de plan (founders/exentos) y webhook de confirmacion.
--   * Parametros de plataforma para las claves Pagopar de facturacion de Hasel.
--   * Endpoints ORDS (modulo hasel + pagopar) se registran aparte:
--       docs/ORDS_SUBSCRIPTION_BILLING.md  o  migrations/20260710_subscription_billing_ords.sql
--
-- Dependencias: PKG_AOX_UTIL, PKG_AOX_SUBSCRIPTION_API, PKG_AOX_PAGOPAR_API, FN_GET_PARAMETER.

PROMPT === 1. Parametros de plataforma (claves Pagopar de facturacion de Hasel) ===
-- Se crean vacios (idempotente). Cargar los valores reales en DEV/PROD via UI o UPDATE.
-- NOTA: son distintos de las claves Pagopar por-organizacion usadas para senas de citas.

MERGE INTO app_parameter t
USING (
  SELECT 'SUBSCRIPTION_PAGOPAR_PUBLIC_KEY'      AS param_key, 'Public key Pagopar de la plataforma Hasel (facturacion de suscripcion).'  AS description FROM dual UNION ALL
  SELECT 'SUBSCRIPTION_PAGOPAR_PRIVATE_KEY'     AS param_key, 'Private key Pagopar de la plataforma Hasel (facturacion de suscripcion).' AS description FROM dual UNION ALL
  SELECT 'SUBSCRIPTION_PAYMENT_PENDING_MINUTES' AS param_key, 'Minutos de vigencia del checkout de suscripcion antes de expirar.'        AS description FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN
  INSERT (param_key, param_value, description)
  VALUES (
    s.param_key,
    CASE s.param_key WHEN 'SUBSCRIPTION_PAYMENT_PENDING_MINUTES' THEN '1440' ELSE ' ' END,
    s.description
  );

COMMIT;

PROMPT === 2. Paquete de facturacion de suscripcion ===
@@../packages/PKG_AOX_SUBSCRIPTION_BILLING_API.pls

PROMPT === 3. Recompilacion de objetos invalidos ===
BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === Fase 5 (facturacion de suscripcion) finalizada ===
PROMPT Recorda: registrar los handlers ORDS (workspace/plans, workspace/subscription/checkout,
PROMPT workspace/subscription/change-plan, workspace/subscription/invoice/:hash, y
PROMPT pagopar subscription/webhook) y cargar SUBSCRIPTION_PAGOPAR_PUBLIC_KEY / _PRIVATE_KEY.
