-- Migracion ORDS: GET /customers acepta query param search (nombre/telefono).
-- Nota: NO usar "q" — es reservado por ORDS (QBE) y responde 400 Bad Request.
-- Requiere PKG_AOX_CUSTOMER_API.pr_list_customers con pi_search.

BEGIN
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'customers',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_customer_api.pr_list_customers(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_page          => :page,
        pi_limit         => :limit,
        pi_pro_id        => :pro_id,
        pi_search        => :search,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );

    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    COMMIT;
END;
/
