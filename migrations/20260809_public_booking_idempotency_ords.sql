-- Fase 5 (extension del framework de Idempotency-Key): reserva publica y upload de
-- comprobante SIPAP reenvian el header Idempotency-Key a PKG_AOX_PUBLIC_BOOKING_API.
-- Redefine los 2 handlers existentes del modulo 'public' (mismo p_source + el nuevo
-- parametro pi_idempotency_key via owa_util.get_cgi_env).

PROMPT === 20260809_public_booking_idempotency_ords ===

BEGIN
    ----------------------------------------------------------------------------
    -- POST /public/appointments -> pr_create_public_app
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'public', p_pattern => 'appointments');
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'appointments',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_public_booking_api.pr_create_public_app(
        pi_body             => :body_text,
        po_status_code      => v_status_code,
        po_response_body    => v_response_body,
        pi_idempotency_key  => owa_util.get_cgi_env('HTTP_IDEMPOTENCY_KEY')
    );

    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN
        htp.prn(v_response_body);
    END IF;
END;
        ]'
    );

    ----------------------------------------------------------------------------
    -- POST /public/reservations/:token/receipt -> pr_upload_public_receipt
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'public', p_pattern => 'reservations/:token/receipt');
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/receipt',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_public_booking_api.pr_upload_public_receipt(
        pi_public_token     => :token,
        pi_body             => :body_text,
        po_status_code      => v_status_code,
        po_response_body    => v_response_body,
        pi_idempotency_key  => owa_util.get_cgi_env('HTTP_IDEMPOTENCY_KEY')
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

PROMPT === 20260809_public_booking_idempotency_ords done ===
