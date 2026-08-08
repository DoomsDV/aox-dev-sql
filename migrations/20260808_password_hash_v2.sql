-- Hardening seguridad login, Fase 3: migracion de hash de password de SHA-256 sin salt
-- a PBKDF2-like (HMAC-SHA256 iterado, con salt por usuario), con rehash progresivo
-- transparente en el proximo login exitoso de cada usuario (PKG_AOX_AUTH_API.pr_login_auth).

PROMPT === 20260808_password_hash_v2 ===

ALTER SESSION DISABLE PARALLEL DML;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE platform_user ADD (password_salt VARCHAR2(64) NULL)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[ALTER TABLE platform_user ADD (password_algo VARCHAR2(30) DEFAULT 'SHA256_LEGACY' NOT NULL)]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE platform_user ADD (password_iterations NUMBER NULL)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

COMMENT ON COLUMN platform_user.password_salt IS 'Salt aleatorio (hex) por usuario para password_algo = PBKDF2_HMAC_SHA256_V1. NULL para hashes legados.';
/

COMMENT ON COLUMN platform_user.password_algo IS 'Algoritmo del password_hash: SHA256_LEGACY (sin salt, legado) o PBKDF2_HMAC_SHA256_V1 (con salt e iteraciones).';
/

COMMENT ON COLUMN platform_user.password_iterations IS 'Cantidad de iteraciones usadas al generar password_hash cuando password_algo = PBKDF2_HMAC_SHA256_V1.';
/

BEGIN
    MERGE INTO app_parameter t
    USING (
        SELECT 'PASSWORD_HASH_ITERATIONS' AS param_key, '100000' AS param_value,
               'Iteraciones de HMAC-SHA256 para fn_hash_password_v2 en nuevos hashes/rehashes (medido: ~500ms/100k iter en ADB DEV)' AS description
        FROM dual
    ) s
    ON (t.param_key = s.param_key)
    WHEN NOT MATCHED THEN
        INSERT (param_key, param_value, description)
        VALUES (s.param_key, s.param_value, s.description);

    COMMIT;
END;
/

PROMPT === 20260808_password_hash_v2 done ===
