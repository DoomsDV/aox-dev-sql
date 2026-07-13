-- Migracion ORDS: Fase C - cancel con body + submit alias + mark-refund-sent
--
-- Public:
--   DELETE /public/v1/reservations/:token          (pasa :body_text)
--   POST   /public/v1/reservations/:token/refund-alias
-- Workspace:
--   POST   /api/v1/workspace/payments/:id/mark-refund-sent

BEGIN
    ----------------------------------------------------------------------------
    -- DELETE /public/reservations/:token (redefinir con body opcional)
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'public', p_pattern => 'reservations/:token');
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

    ----------------------------------------------------------------------------
    -- POST /public/reservations/:token/refund-alias
    ----------------------------------------------------------------------------
    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-alias'
    );
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-alias',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_public_booking_api.pr_submit_refund_alias(
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

    ----------------------------------------------------------------------------
    -- POST /workspace/payments/:id/mark-refund-sent
    ----------------------------------------------------------------------------
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/:id/mark-refund-sent'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/:id/mark-refund-sent',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_payments_api.pr_mark_refund_sent(
        pi_auth_header    => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_transaction_id => TO_NUMBER(:id),
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

PROMPT === ORDS Fase C (refund) registrado ===
