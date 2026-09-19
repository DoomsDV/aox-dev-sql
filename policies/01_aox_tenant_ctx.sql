-- AOX_TENANT_CTX: application context del tenant activo.
-- Solo pkg_aox_session puede escribirlo (CREATE CONTEXT ... USING).
-- Si ORA-01031, ejecutar como usuario ADMIN de la ADB:
--   CREATE OR REPLACE CONTEXT aox_tenant_ctx USING aoxdev.pkg_aox_session;
CREATE OR REPLACE CONTEXT aox_tenant_ctx USING pkg_aox_session;
