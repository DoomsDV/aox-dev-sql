-- ORDS + jobs del modulo de disputas de reembolso.

BEGIN
    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-dispute'
    );
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-dispute',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_refund_disputes_api.pr_open_public_dispute(
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

    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-dispute/insist'
    );
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-dispute/insist',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_refund_disputes_api.pr_insist_public(
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

    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-proof'
    );
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-proof',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_refund_disputes_api.pr_get_public_proof(
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

    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/:id/refund-proof'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/:id/refund-proof',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_refund_disputes_api.pr_get_staff_proof(
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
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/:id/refund-proof',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_refund_disputes_api.pr_upload_staff_proof(
        pi_auth_header     => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_transaction_id  => TO_NUMBER(:id),
        pi_body            => :body_text,
        pi_idempotency_key => owa_util.get_cgi_env('IDEMPOTENCY-KEY'),
        po_status_code     => v_status_code,
        po_response_body   => v_response_body
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

BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_REFUND_SLA_CHECK', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_REFUND_DISPUTE_CHECK', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HASEL_REFUND_DISPUTE_CHECK',
        job_type        => 'PLSQL_BLOCK',
        job_action      => q'[
BEGIN
    pkg_aox_refund_disputes_api.pr_process_dispute_timeouts(100);
    pkg_aox_refund_disputes_api.pr_process_notify_outbox(50);
END;
        ]',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=15',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'Timeouts de disputa (CAS + ledger) y outbox FCM de Cobros'
    );
END;
/

PROMPT === ORDS + job disputas de reembolso registrados ===
