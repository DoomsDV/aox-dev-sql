-- Fix POST /auth/refresh: el handler llamaba a pkg_aox_auth_api.pr_refresh_token
-- (no existe) y ORDS respondia 555 ORDS-25001. El procedimiento vive en pkg_aox_jwt.
-- No usar define_template: reemplazaria el template y borraria handlers previos.

BEGIN
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'auth/refresh',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_body_text     CLOB := :body_text;
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_jwt.pr_refresh_token(
        pi_body          => v_body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );

    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);

    IF v_response_body IS NOT NULL THEN
        htp.prn(v_response_body);
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        :status_code := 500;
        owa_util.mime_header('application/json', TRUE);
        htp.prn('{"status": "error", "message": "Error interno del servidor en el endpoint de refresh."}');
END;
        ]'
    );

    COMMIT;
END;
/
