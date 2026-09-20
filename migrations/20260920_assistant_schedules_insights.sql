-- Bookmate Assistant: horarios en batch e insights operativos compuestos.
-- Ejecutar como AOXDEV. Recompila pkg_aox_assistant_api y registra
-- GET /assistant/schedules y GET /assistant/insights en el módulo hasel.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === compile assistant read package ===
@@../packages/PKG_AOX_ASSISTANT_API.pls

PROMPT === ORDS assistant schedules and insights ===
BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'assistant/schedules'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'assistant/schedules',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_assistant_api.pr_list_schedules(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'assistant/insights'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'assistant/insights',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_assistant_api.pr_get_insights(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_days          => NVL(TO_NUMBER(:days), 30),
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

PROMPT OK: assistant schedules and insights endpoints
