-- Lectores publicos VPD-safe: directorio /explorar y pr_refresh_all.
-- ORG_PUBLIC_DIRECTORY (sin VPD) + set_org por org. No escanear
-- WORKSPACE_SETTING / LOCATION / APPOINTMENT cross-tenant.
-- Como AOXDEV. Idempotente (CREATE OR REPLACE).

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260919_aox_public_vpd_readers ===

@@../packages/PKG_AOX_PUBLIC_DIRECTORY.pls
@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls

PROMPT === 20260919_aox_public_vpd_readers listo ===
