-- Bookmate Assistant: agenda filtrable con agregados de hora/día.
-- Ejecutar como AOXDEV. Recompila pkg_aox_assistant_api y registra
-- GET /assistant/appointments en el módulo hasel.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === compile assistant read package ===
@@../packages/PKG_AOX_ASSISTANT_API.pls

PROMPT === ORDS assistant appointments ===
BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'assistant/appointments'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'assistant/appointments',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_assistant_api.pr_list_appointments(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_from_date     => :from_date,
        pi_to_date       => :to_date,
        pi_status        => :status_filter,
        pi_prof_id       => CASE WHEN TRIM(:pro_id) IS NULL THEN NULL ELSE TO_NUMBER(TRIM(:pro_id)) END,
        pi_loc_id        => CASE WHEN TRIM(:loc_id) IS NULL THEN NULL ELSE TO_NUMBER(TRIM(:loc_id)) END,
        pi_service_id    => CASE WHEN TRIM(:service_id) IS NULL THEN NULL ELSE TO_NUMBER(TRIM(:service_id)) END,
        pi_weekday       => CASE WHEN TRIM(:weekday) IS NULL THEN NULL ELSE TO_NUMBER(TRIM(:weekday)) END,
        pi_hour          => CASE WHEN TRIM(:hour) IS NULL THEN NULL ELSE TO_NUMBER(TRIM(:hour)) END,
        pi_limit         => CASE WHEN TRIM(:limit) IS NULL THEN NULL ELSE TO_NUMBER(TRIM(:limit)) END,
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

PROMPT OK: assistant appointments endpoint
