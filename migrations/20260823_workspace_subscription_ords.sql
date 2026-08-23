-- ORDS: GET /workspace/subscription (estado de plan, entitlements y storage de la org)
--
-- 20260710_subscription_phase2.sql dejo este endpoint anotado como "registrado aparte
-- con ORDS.define_handler", asi que nunca quedo versionado. Al replayar la cadena sobre
-- una base nueva el endpoint no se crea y el panel se queda sin estado de suscripcion.
PROMPT === ORDS workspace/subscription ===

BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_api.pr_get_subscription(
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

    COMMIT;
END;
/

PROMPT OK: ORDS workspace/subscription
