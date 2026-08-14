-- ORDS: aprobar excepcion de horario (Descartar advertencia).
-- Requiere PKG_AOX_APPOINTMENT_API.PR_APPROVE_SCHEDULE_EXCEPTION.
--
-- Endpoint:
--   POST /api/v1/appointments/:id/schedule-exception
--     -> pkg_aox_appointment_api.pr_approve_schedule_exception

BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'appointments/:id/schedule-exception'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'appointments/:id/schedule-exception',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_appointment_api.pr_approve_schedule_exception(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_app_id        => :id,
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
