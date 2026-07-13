-- Migracion ORDS: Fase B2 - Upload comprobante SIPAP + OCR
-- Ejecutar como el esquema ORDS-enabled (aoxdev). Requiere modulo 'public' PUBLISHED.
--
-- Endpoint:
--   POST /public/v1/reservations/:token/receipt  -> pr_upload_public_receipt

BEGIN
    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/receipt'
    );

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

PROMPT === ORDS public/reservations/:token/receipt registrado ===
