-- ORDS: ATC ask (KB global RAG)
-- POST /ords/aoxdev/ai/atc/ask

BEGIN
    ORDS.define_template(
        p_module_name => 'ai',
        p_pattern     => 'atc/ask'
    );

    ORDS.define_handler(
        p_module_name => 'ai',
        p_pattern     => 'atc/ask',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_atc_chat_api.pr_ask(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_body          => :body_text,
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
