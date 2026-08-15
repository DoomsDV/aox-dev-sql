-- ORDS: anular hallazgo del odontograma (soft delete).
-- POST /workspace/customers/:id/odontogram/:eventId/void

BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/customers/:id/odontogram/:eventId/void'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/customers/:id/odontogram/:eventId/void',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_odontogram_api.pr_void_event(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_customer_id   => TO_NUMBER(:id),
        pi_event_id      => TO_NUMBER(:eventId),
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
