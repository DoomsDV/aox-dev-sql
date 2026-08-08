-- Hardening seguridad login, Fase 2: lockout temporal de cuenta tras N fallos consecutivos
-- (PKG_AOX_AUTH_API.pr_login_auth), complementa el rate limit por identificador/IP (Fase 1).

PROMPT === 20260808_account_lockout ===

ALTER SESSION DISABLE PARALLEL DML;

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE platform_user ADD (failed_login_attempts NUMBER DEFAULT 0 NOT NULL)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE platform_user ADD (locked_until TIMESTAMP WITH TIME ZONE NULL)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

COMMENT ON COLUMN platform_user.failed_login_attempts IS 'Contador de intentos fallidos de login consecutivos; se resetea a 0 en login exitoso.';
COMMENT ON COLUMN platform_user.locked_until IS 'Timestamp hasta el cual la cuenta esta bloqueada por exceso de intentos fallidos (NULL = no bloqueada).';

BEGIN
    MERGE INTO app_parameter t
    USING (
        SELECT 'ACCOUNT_LOCKOUT_MAX_ATTEMPTS' AS param_key, '5' AS param_value,
               'Intentos fallidos consecutivos antes de bloquear temporalmente la cuenta' AS description FROM dual
        UNION ALL
        SELECT 'ACCOUNT_LOCKOUT_MINUTES', '15',
               'Minutos de bloqueo temporal de cuenta tras superar ACCOUNT_LOCKOUT_MAX_ATTEMPTS' FROM dual
    ) s
    ON (t.param_key = s.param_key)
    WHEN NOT MATCHED THEN
        INSERT (param_key, param_value, description)
        VALUES (s.param_key, s.param_value, s.description);

    COMMIT;
END;
/

PROMPT === 20260808_account_lockout done ===
