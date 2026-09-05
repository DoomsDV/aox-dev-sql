-- ORDS + customer history: mapa corporal por cita (BODY_MAP).

PROMPT === compile PKG_AOX_BODY_MAP_API ===
@@../packages/PKG_AOX_BODY_MAP_API.pls

PROMPT === ORDS body snapshots ===
BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/customers/:id/body-snapshots'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/customers/:id/body-snapshots',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_body_map_api.pr_list_snapshots(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_customer_id   => TO_NUMBER(:id),
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
        p_pattern     => 'workspace/customers/:id/body-snapshots/:appointmentId'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/customers/:id/body-snapshots/:appointmentId',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_body_map_api.pr_get_snapshot(
        pi_auth_header    => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_customer_id    => TO_NUMBER(:id),
        pi_appointment_id => TO_NUMBER(:appointmentId),
        po_status_code    => v_status_code,
        po_response_body  => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/customers/:id/body-snapshots/:appointmentId',
        p_method      => 'PUT',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_body_map_api.pr_put_snapshot(
        pi_auth_header    => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_customer_id    => TO_NUMBER(:id),
        pi_appointment_id => TO_NUMBER(:appointmentId),
        pi_body           => :body_text,
        po_status_code    => v_status_code,
        po_response_body  => v_response_body
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

PROMPT === PKG_AOX_CUSTOMER_API body_mark_count ===
@@../packages/PKG_AOX_CUSTOMER_API.pls

PROMPT OK: body map API ORDS
