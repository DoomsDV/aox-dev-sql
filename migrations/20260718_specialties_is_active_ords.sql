-- Migracion ORDS: GET /specialties acepta is_active.
-- Nota: NO usar "q" — reservado por ORDS (QBE).

BEGIN
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'specialties',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_specialty_api.pr_list_specialties(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_page          => :page,
        pi_limit         => :limit,
        pi_is_active     => :is_active,
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
