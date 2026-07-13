-- Migracion: Fase 2 - API de suscripción
-- Roadmap Hasel: Premium + Planes + Historial
--
-- Contenido:
--   * PKG_AOX_SUBSCRIPTION_API: fn_org_has_feature, fn_get_subscription_state,
--     fn_get_storage_limit_bytes, fn_org_can_write, fn_assert_org_can_write,
--     pr_ensure_trial_subscription, pr_get_subscription.
--   * PKG_AOX_AUTH_API: crea suscripción TRIAL (Premium, 14 días) al registrar organización.
--   * Endpoint ORDS: GET /api/v1/workspace/subscription (registrado aparte con ORDS.define_handler).
--
-- Nota: SUBSCRIPTION_API se compila antes que AUTH_API (dependencia).

PROMPT === 1. Paquete de suscripción ===
@@../packages/PKG_AOX_SUBSCRIPTION_API.pls

PROMPT === 2. Paquete de auth (TRIAL en registro) ===
@@../packages/PKG_AOX_AUTH_API.pls

PROMPT === 3. Recompilacion de objetos invalidos ===
BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === Fase 2 (API de suscripción) finalizada ===
