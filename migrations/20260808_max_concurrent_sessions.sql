-- Hardening seguridad login, Fase 4: limite de sesiones concurrentes (multi-dispositivo).
-- PKG_AOX_JWT.pr_generate_auth_tokens revoca automaticamente el refresh token activo mas
-- antiguo de un usuario cuando supera MAX_CONCURRENT_SESSIONS al generar uno nuevo.

PROMPT === 20260808_max_concurrent_sessions ===

BEGIN
    MERGE INTO app_parameter t
    USING (
        SELECT 'MAX_CONCURRENT_SESSIONS' AS param_key, '5' AS param_value,
               'Cantidad maxima de refresh tokens activos (sesiones) por usuario; al superarla se revoca el mas antiguo' AS description FROM dual
    ) s
    ON (t.param_key = s.param_key)
    WHEN NOT MATCHED THEN
        INSERT (param_key, param_value, description)
        VALUES (s.param_key, s.param_value, s.description);

    COMMIT;
END;
/

PROMPT === 20260808_max_concurrent_sessions done ===
