-- Migracion ORDS: orden asc/desc por fecha de cita en GET /workspace/payments
-- Modulo hasel. Parametro bind :sort_dir (asc|desc, default desc).

BEGIN
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_payments_api.pr_list_payments(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_status_filter => :status_filter,
        pi_date_preset   => :date_preset,
        pi_date_from     => :date_from,
        pi_date_to       => :date_to,
        pi_page          => :page,
        pi_limit         => :limit,
        pi_sort_dir      => :sort_dir,
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

PROMPT === ORDS workspace/payments sort_dir registrado ===
