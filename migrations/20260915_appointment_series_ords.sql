-- ORDS: crear serie semanal de citas (HAS-22).
-- Requiere PKG_AOX_APPOINTMENT_API.PR_CREATE_APPOINTMENT_SERIES
-- y la migracion 20260915_appointment_series.sql.
--
-- Endpoint:
--   POST /api/v1/appointments/series
--     -> pkg_aox_appointment_api.pr_create_appointment_series

BEGIN
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'appointments/series');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'appointments/series',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_appointment_api.pr_create_appointment_series(
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
