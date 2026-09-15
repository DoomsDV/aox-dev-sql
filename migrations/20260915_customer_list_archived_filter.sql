-- HAS-38: GET /customers respeta archived= (0 activos, 1 archivados).
-- HAS-23 ya tenia pi_archived en el paquete y 20260915_customer_archive_ords.sql,
-- pero en aoxdevelop el GET seguia sin el bind y pr_list_customers no filtraba
-- is_active: Archivados ON devolvía el padron completo.
-- Recompila el paquete y redefine solo el GET. No toca archive/restore.

PROMPT === 20260915_customer_list_archived_filter ===

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

    COMMIT;
END;
/

PROMPT === 20260915_customer_list_archived_filter: OK ===
