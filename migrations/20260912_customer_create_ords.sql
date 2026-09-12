-- Migracion ORDS: POST /customers (alta de cliente).
-- Requiere PKG_AOX_CUSTOMER_API.pr_create_customer.
-- El template 'customers' ya existe (GET de listado). No redefinir el template:
-- ORDS.define_template puede recrearlo y borrar el GET.

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

    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'customers',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_customer_api.pr_create_customer(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_body          => :body_text,
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
