-- ORDS: catálogo de hallazgos del odontograma.
-- GET /workspace/odontogram/catalog

BEGIN
    ORDS.DEFINE_TEMPLATE(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/odontogram/catalog'
    );

    ORDS.DEFINE_HANDLER(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/odontogram/catalog',
        p_method      => 'GET',
        p_source_type => ORDS.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_odontogram_api.pr_get_catalog(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );

    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN
        htp.prn(v_response_body);
    END IF;
END;
]'
    );
END;
/

COMMIT;

PROMPT OK: odontogram catalog ORDS
