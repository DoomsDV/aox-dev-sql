-- Security hardening: rate-limit table, JWT leeway/rate params, WA signature ORDS,
-- CORS origins (staging + hasel + localhost; pagopar same).

PROMPT === 20260724_security_auth_hardening ===

-- ---------------------------------------------------------------------------
-- Rate limit buckets
-- ---------------------------------------------------------------------------
BEGIN
    EXECUTE IMMEDIATE q'[
        CREATE TABLE api_rate_limit_bucket (
            scope_code         VARCHAR2(64)  NOT NULL,
            bucket_key         VARCHAR2(255) NOT NULL,
            attempt_count      NUMBER        DEFAULT 1 NOT NULL,
            window_started_at  TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
            updated_at         TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
            CONSTRAINT pk_api_rate_limit_bucket PRIMARY KEY (scope_code, bucket_key)
        )
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        CREATE INDEX ix_api_rate_limit_window
            ON api_rate_limit_bucket (scope_code, window_started_at)
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-955, -1408) THEN RAISE; END IF;
END;
/

-- ---------------------------------------------------------------------------
-- App parameters (defaults; META_APP_SECRET must be set manually in each env)
-- ---------------------------------------------------------------------------
BEGIN
    MERGE INTO app_parameter t
    USING (
        SELECT 'JWT_VALIDATE_LEEWAY_SEC' AS param_key, '30' AS param_value,
               'Leeway seconds for apex_jwt.validate (exp/nbf/iat)' AS description FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_LOGIN_MAX', '10', 'Max login attempts per identifier per window' FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_LOGIN_WINDOW_SEC', '900', 'Login rate-limit window seconds' FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_FORGOT_MAX', '5', 'Max forgot-password attempts per email per window' FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_FORGOT_WINDOW_SEC', '900', 'Forgot-password rate-limit window seconds' FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_PUBLIC_BOOKING_MAX', '20', 'Max public booking creates per phone/IP per window' FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_PUBLIC_BOOKING_WINDOW_SEC', '900', 'Public booking rate-limit window seconds' FROM dual
    ) s
    ON (t.param_key = s.param_key)
    WHEN NOT MATCHED THEN
        INSERT (param_key, param_value, description)
        VALUES (s.param_key, s.param_value, s.description);

    -- Placeholder so operators know the key; replace with real Meta App Secret.
    -- Until then WhatsApp POST webhooks are rejected (fn_verify returns 0 for UNSET).
    MERGE INTO app_parameter t
    USING (
        SELECT 'META_APP_SECRET' AS param_key,
               'UNSET' AS param_value,
               'Meta App Secret for X-Hub-Signature-256 on WhatsApp webhooks' AS description
        FROM dual
    ) s
    ON (t.param_key = s.param_key)
    WHEN NOT MATCHED THEN
        INSERT (param_key, param_value, description)
        VALUES (s.param_key, s.param_value, s.description);

    COMMIT;
END;
/

-- ---------------------------------------------------------------------------
-- ORDS CORS: include staging.hasel.app
-- ---------------------------------------------------------------------------
DECLARE
    c_origins CONSTANT VARCHAR2(500) :=
        'https://hasel.app,https://staging.hasel.app,http://localhost:4321';
BEGIN
    FOR r IN (
        SELECT name FROM user_ords_modules
         WHERE name IN ('hasel', 'public', 'ai', 'whatsapp', 'pagopar')
    ) LOOP
        ORDS.set_module_origins_allowed(
            p_module_name     => r.name,
            p_origins_allowed => c_origins
        );
    END LOOP;
    COMMIT;
END;
/

-- ---------------------------------------------------------------------------
-- WhatsApp POST: require X-Hub-Signature-256
-- ---------------------------------------------------------------------------
BEGIN
    ORDS.define_handler(
        p_module_name    => 'whatsapp',
        p_pattern        => 'attendance-reply',
        p_method         => 'POST',
        p_source_type    => ORDS.source_type_plsql,
        p_source         => q'[
DECLARE
    v_body_blob BLOB := :body;
    v_body      CLOB := :body_text;
    v_sig       VARCHAR2(4000);
    v_payload   VARCHAR2(200);
    v_response  json_object_t := json_object_t();
BEGIN
    BEGIN
        v_sig := owa_util.get_cgi_env('HTTP_X_HUB_SIGNATURE_256');
    EXCEPTION
        WHEN OTHERS THEN
            v_sig := NULL;
    END;

    IF NVL(pkg_aox_meta_api.fn_verify_webhook_signature(v_body_blob, v_sig), 0) <> 1 THEN
        :status_code := 403;
        v_response.put('status', 'error');
        v_response.put('message', 'Firma de webhook invalida o META_APP_SECRET no configurado.');
        owa_util.mime_header('application/json', FALSE);
        owa_util.http_header_close;
        htp.prn(v_response.to_clob());
        RETURN;
    END IF;

    APEX_JSON.parse(v_body);

    v_payload := APEX_JSON.get_varchar2(
        p_path => 'entry[1].changes[1].value.messages[1].button.payload'
    );

    IF v_payload IS NULL THEN
        v_payload := APEX_JSON.get_varchar2(
            p_path => 'entry[1].changes[1].value.messages[1].interactive.button_reply.id'
        );
    END IF;

    IF v_payload IS NULL THEN
        v_payload := APEX_JSON.get_varchar2(
            p_path => 'entry[1].changes[1].value.messages[1].interactive.button_reply.payload'
        );
    END IF;

    IF v_payload IS NULL
       OR NOT REGEXP_LIKE(
            UPPER(TRIM(v_payload)),
            '^(CONFIRMAR_RESERVA_ID_|CANCELAR_RESERVA_ID_)[0-9]+$'
       ) THEN
        :status_code := 200;
        v_response.put('status', 'ignored');
        v_response.put('message', 'Evento sin payload de asistencia valido.');
        owa_util.mime_header('application/json', FALSE);
        owa_util.http_header_close;
        htp.prn(v_response.to_clob());
        RETURN;
    END IF;

    pkg_aox_meta_api.pr_apply_attendance_payload(pi_payload => v_payload);

    :status_code := 200;
    v_response.put('status', 'success');
    v_response.put('message', 'Respuesta registrada.');
    owa_util.mime_header('application/json', FALSE);
    owa_util.http_header_close;
    htp.prn(v_response.to_clob());
EXCEPTION
    WHEN OTHERS THEN
        :status_code := 400;
        v_response := json_object_t();
        v_response.put('status', 'error');
        v_response.put('message', REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''));
        owa_util.mime_header('application/json', FALSE);
        owa_util.http_header_close;
        htp.prn(v_response.to_clob());
END;
]',
        p_items_per_page => 0
    );
    COMMIT;
END;
/

PROMPT === 20260724_security_auth_hardening done ===
