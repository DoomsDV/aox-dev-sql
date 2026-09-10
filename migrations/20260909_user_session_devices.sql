-- Sesiones de dispositivo: familia estable ante rotación de refresh + listado/revocar.
-- También reserva el slug público terminos-y-condiciones (PKG_AOX_UTIL).

PROMPT === 20260909_user_session_devices ===

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE app_user_session ADD session_family VARCHAR2(64)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE app_user_session ADD user_agent VARCHAR2(400)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE app_user_session ADD ip_address VARCHAR2(45)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE app_user_session ADD last_seen_at TIMESTAMP(6) WITH TIME ZONE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

UPDATE app_user_session
   SET session_family = lower(rawtohex(sys_guid()))
 WHERE session_family IS NULL;

UPDATE app_user_session
   SET last_seen_at = created_at
 WHERE last_seen_at IS NULL;

COMMIT;

BEGIN
    EXECUTE IMMEDIATE 'CREATE INDEX ix_app_user_session_family ON app_user_session (session_family, is_revoked)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-955, -1408) THEN RAISE; END IF;
END;
/

BEGIN
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'auth/sessions');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'auth/sessions',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_auth_api.pr_list_sessions(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN
        htp.prn(v_response_body);
    END IF;
END;
        ]'
    );

    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'auth/sessions/revoke');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'auth/sessions/revoke',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_auth_api.pr_revoke_session(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN
        htp.prn(v_response_body);
    END IF;
END;
        ]'
    );

    COMMIT;
END;
/
