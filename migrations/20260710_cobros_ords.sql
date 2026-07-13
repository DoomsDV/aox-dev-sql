-- Migracion ORDS: Fase B3 - Handlers menu Cobros
-- Modulo hasel. Endpoints:
--   GET  /api/v1/workspace/payments
--   GET  /api/v1/workspace/payments/pending-count
--   POST /api/v1/workspace/payments/:id/approve
--   POST /api/v1/workspace/payments/:id/reject

BEGIN
    ----------------------------------------------------------------------------
    -- GET /workspace/payments
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/payments');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_payments_api.pr_list_payments(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_status_filter => :status_filter,
        pi_date_preset   => :date_preset,
        pi_date_from     => :date_from,
        pi_date_to       => :date_to,
        pi_page          => :page,
        pi_limit         => :limit,
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
    -- GET /workspace/payments/pending-count
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/payments/pending-count');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/pending-count',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_payments_api.pr_pending_count(
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

    ----------------------------------------------------------------------------
    -- POST /workspace/payments/:id/approve
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/payments/:id/approve');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/:id/approve',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_payments_api.pr_approve_payment(
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

    ----------------------------------------------------------------------------
    -- POST /workspace/payments/:id/reject
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/payments/:id/reject');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/:id/reject',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_payments_api.pr_reject_payment(
        pi_auth_header    => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_transaction_id => TO_NUMBER(:id),
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

PROMPT === ORDS workspace/payments registrado ===
