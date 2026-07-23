-- Migracion ORDS: perfil fiscal de suscripcion Hasel
-- Ejecutar como el esquema ORDS-enabled (aoxdev). Requiere modulo 'hasel' PUBLISHED.
--
-- Endpoints:
--   GET  /api/v1/workspace/billing-profile  -> pr_get_billing_profile
--   PUT  /api/v1/workspace/billing-profile  -> pr_put_billing_profile

BEGIN
    ----------------------------------------------------------------------------
    -- GET /workspace/billing-profile
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/billing-profile');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/billing-profile',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_billing_profile_api.pr_get_billing_profile(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ----------------------------------------------------------------------------
    -- PUT /workspace/billing-profile
    ----------------------------------------------------------------------------
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/billing-profile',
        p_method      => 'PUT',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_billing_profile_api.pr_put_billing_profile(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    COMMIT;
END;
/

PROMPT === ORDS workspace/billing-profile registrado ===
