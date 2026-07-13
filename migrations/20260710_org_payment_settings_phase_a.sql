-- Migracion: Fase A Cobros SIPAP - org_payment_settings + API
-- Roadmap Hasel: Cobros / senas por transferencia
--
-- Contenido:
--   * Tabla org_payment_settings (1:1 org)
--   * PKG_AOX_PAYMENT_SETTINGS_API (GET/PUT + fn_org_deposits_enabled)
--   * PKG_AOX_SERVICE_API: gate deposits_enabled al configurar seña

PROMPT === 1. Tabla org_payment_settings ===
@@../tables/ORG_PAYMENT_SETTINGS.sql

PROMPT === 2. API de configuracion de cobros ===
@@../packages/PKG_AOX_PAYMENT_SETTINGS_API.pls

PROMPT === 3. Gate de senas en servicios (deposits_enabled) ===
@@../packages/PKG_AOX_SERVICE_API.pls

PROMPT === 4. Recompilacion de objetos invalidos ===
BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === Fase A (org_payment_settings) finalizada ===
