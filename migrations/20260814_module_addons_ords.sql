-- Migracion ORDS: complementos de modulo + odontograma.
-- Ejecutar como el esquema ORDS-enabled (aoxdev). Requiere que el modulo
-- 'hasel' (/api/v1/) ya exista (PUBLISHED).
--
-- Endpoints (modulo hasel, prefijo /api/v1/):
--   GET  /workspace/addons                      -> pr_list_addons
--   POST /workspace/addons                      -> pr_activate_module_addon
--   POST /workspace/addons/cancel               -> pr_cancel_module_addon
--   GET  /workspace/customers/:id/odontogram    -> pr_get_chart
--   POST /workspace/customers/:id/odontogram    -> pr_add_event

BEGIN
    ----------------------------------------------------------------------------
    -- GET|POST /workspace/addons
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/addons');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/addons',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_addon_api.pr_list_addons(
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

    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/addons',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_addon_api.pr_activate_module_addon(
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

    ----------------------------------------------------------------------------
    -- POST /workspace/addons/cancel
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/addons/cancel');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/addons/cancel',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_addon_api.pr_cancel_module_addon(
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

    ----------------------------------------------------------------------------
    -- GET|POST /workspace/customers/:id/odontogram
    ----------------------------------------------------------------------------
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/customers/:id/odontogram'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/customers/:id/odontogram',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_odontogram_api.pr_get_chart(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_customer_id   => TO_NUMBER(:id),
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/customers/:id/odontogram',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_odontogram_api.pr_add_event(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_customer_id   => TO_NUMBER(:id),
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
