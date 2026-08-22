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
BEGIN
    pkg_aox_odontogram_api.pr_get_catalog(
        pi_auth_header   => :auth_header,
        po_status_code   => :status_code,
        po_response_body => :response_body
    );
END;
]'
    );
END;
/

COMMIT;

PROMPT OK: odontogram catalog ORDS
