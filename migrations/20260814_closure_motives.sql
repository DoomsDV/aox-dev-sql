-- Motivos de cierre: feriados oficiales (ref_holiday) + nombres personalizados.
-- ORDS: GET /closures/motives  (modulo hasel)
-- Package: pkg_aox_location_closure_api.pr_list_closure_motives

BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'closures/motives'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'closures/motives',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_location_closure_api.pr_list_closure_motives(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
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
