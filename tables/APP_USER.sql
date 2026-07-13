-- DEPRECADO: usar platform_user + org_member.
-- Instalaciones nuevas: ver install_all.sql (PLATFORM_USER, ORG_MEMBER).
-- Bases existentes: ejecutar migrations/20260528_multi_org_identity.sql
-- Compatibilidad de lectura: views/APP_USER_COMPAT.sql (vista app_user)

PROMPT Tabla app_user reemplazada por platform_user y org_member. Ver migracion 20260528_multi_org_identity.sql
