-- Hardening seguridad login, Fase 1: rate limit por IP en pr_login_auth y pr_forgot_password
-- (PKG_AOX_AUTH_API), complementa el rate limit existente por identificador/email.

PROMPT === 20260808_login_rate_limit_ip ===

BEGIN
    MERGE INTO app_parameter t
    USING (
        SELECT 'RATE_LIMIT_LOGIN_IP_MAX' AS param_key, '30' AS param_value,
               'Max intentos de login por IP por ventana (AUTH_LOGIN_IP / AUTH_FORGOT_IP)' AS description FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_LOGIN_IP_WINDOW_SEC', '900',
               'Ventana en segundos del rate limit de login por IP' FROM dual
    ) s
    ON (t.param_key = s.param_key)
    WHEN NOT MATCHED THEN
        INSERT (param_key, param_value, description)
        VALUES (s.param_key, s.param_value, s.description);

    COMMIT;
END;
/

PROMPT === 20260808_login_rate_limit_ip done ===
