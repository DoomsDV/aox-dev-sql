-- Fix: restaurar GET/PUT en /public/v1/reservations/:token
--
-- Causa: 20260710_sipap_refund_ords.sql llamo ORDS.define_template + solo DELETE,
-- lo que borro los handlers GET/PUT. /r/:token (SSR) hace GET y recibia 405 Method Not Allowed.
--
-- Endpoints:
--   GET    /public/v1/reservations/:token  -> pr_get_public_reservation
--   PUT    /public/v1/reservations/:token  -> pr_update_public_reservation
--   DELETE /public/v1/reservations/:token  -> pr_cancel_public_reservation (con body opcional)

BEGIN
    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token'
    );

    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_public_booking_api.pr_get_public_reservation(
        pi_public_token  => :token,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token',
        p_method      => 'PUT',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_public_booking_api.pr_update_public_reservation(
        pi_public_token  => :token,
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

    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token',
        p_method      => 'DELETE',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_public_booking_api.pr_cancel_public_reservation(
        pi_public_token  => :token,
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

PROMPT === ORDS reservations/:token GET+PUT+DELETE restaurados ===
