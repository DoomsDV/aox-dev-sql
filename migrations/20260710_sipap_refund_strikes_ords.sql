-- Migracion ORDS + job Fase D
--   POST /public/v1/reservations/:token/refund-claim
--   POST /api/v1/workspace/payments/:id/waive-refund
--   Job HASEL_REFUND_SLA_CHECK (cada hora)

BEGIN
    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-claim'
    );
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-claim',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_refund_claims_api.pr_submit_public_claim(
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
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/:id/waive-refund'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/:id/waive-refund',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_payments_api.pr_waive_refund(
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

BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_REFUND_SLA_CHECK', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HASEL_REFUND_SLA_CHECK',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN pkg_aox_refund_claims_api.pr_process_refund_sla(pi_batch_size => 100); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=HOURLY;INTERVAL=1',
        enabled         => TRUE,
        comments        => 'Fase D: reclamos automaticos si reembolso PENDING supera SLA 48h habiles'
    );
END;
/

PROMPT === ORDS + job Fase D registrados ===
