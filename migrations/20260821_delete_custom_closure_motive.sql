-- DELETE /closures/motives: elimina un motivo personalizado y todos los
-- cierres de la org con ese nombre.
-- No usar define_template: reemplazaria el template y borraria el GET.

PROMPT === 20260821_delete_custom_closure_motive ===

BEGIN
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'closures/motives',
        p_method      => 'DELETE',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_body_text     CLOB := :body_text;
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_location_closure_api.pr_delete_custom_motive(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_body          => v_body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );

    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);

    IF v_response_body IS NOT NULL THEN
        htp.prn(v_response_body);
    END IF;
END;
        ]'
    );

    COMMIT;
END;
/

PROMPT === 20260821_delete_custom_closure_motive done ===
