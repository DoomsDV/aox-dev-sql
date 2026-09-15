-- HAS-23: listado filtra archivados; POST archive/restore.
-- Requiere PKG_AOX_CUSTOMER_API.pr_list_customers (pi_archived)
-- y pr_set_customer_active.
-- El template 'customers' ya existe. No redefinir el template:
-- ORDS.define_template puede recrearlo y borrar handlers.

PROMPT === 20260915_customer_archive_ords ===

@@../packages/PKG_AOX_CUSTOMER_API.pls

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
        pi_archived      => :archived,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );

    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'customers/:id/archive'
    );

    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'customers/:id/archive',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_customer_api.pr_set_customer_active(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_cus_id        => TO_NUMBER(:id),
        pi_is_active     => 0,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'customers/:id/restore'
    );

    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'customers/:id/restore',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_customer_api.pr_set_customer_active(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_cus_id        => TO_NUMBER(:id),
        pi_is_active     => 1,
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

PROMPT === 20260915_customer_archive_ords: OK ===
