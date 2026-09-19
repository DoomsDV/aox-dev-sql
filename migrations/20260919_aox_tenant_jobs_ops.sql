-- Wrappers de jobs ACCESSIBLE BY + job revoke sessions + desactivar duplicado Pagopar.
-- begin_job sigue gated por BG_JOB_ID. APP_USER_SESSION sin VPD.
-- Como AOXDEV. Idempotente.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260919_aox_tenant_jobs_ops ===

@@../packages/PKG_AOX_JOB_WRAPPER.pls
@@../packages/PKG_AOX_SESSION.pls
@@../packages/PKG_AOX_AUTH_API.pls
@@../packages/PKG_AOX_JOB_WRAPPER.pls

PROMPT --- Reapuntar jobs al wrapper; desactivar JOB_EXPIRE_PAGOPAR_PAYMENTS ---
DECLARE
    PROCEDURE set_action(
        pi_job   IN VARCHAR2,
        pi_block IN VARCHAR2,
        pi_proc  IN VARCHAR2 DEFAULT NULL
    ) IS
        v_exists NUMBER;
        v_type   user_scheduler_jobs.job_type%TYPE;
    BEGIN
        SELECT COUNT(*)
          INTO v_exists
          FROM user_scheduler_jobs
         WHERE job_name = UPPER(pi_job);
        IF v_exists = 0 THEN
            DBMS_OUTPUT.PUT_LINE('SKIP job ausente ' || pi_job);
            RETURN;
        END IF;
        SELECT job_type
          INTO v_type
          FROM user_scheduler_jobs
         WHERE job_name = UPPER(pi_job);
        IF v_type = 'STORED_PROCEDURE' THEN
            DBMS_SCHEDULER.SET_ATTRIBUTE(
                name      => pi_job,
                attribute => 'job_action',
                value     => NVL(pi_proc, pi_block)
            );
        ELSE
            DBMS_SCHEDULER.SET_ATTRIBUTE(
                name      => pi_job,
                attribute => 'job_action',
                value     => pi_block
            );
        END IF;
        DBMS_OUTPUT.PUT_LINE('job_action OK ' || pi_job || ' (' || v_type || ')');
    END;
BEGIN
    set_action(
        'HASEL_DISPATCH_PUSH_CAMPAIGNS',
        'BEGIN pkg_aox_job_wrapper.pr_dispatch_push_campaigns; END;'
    );
    set_action(
        'HASEL_EXPIRE_PENDING_PAYMENTS',
        'BEGIN pkg_aox_job_wrapper.pr_expire_pending_payments; END;'
    );
    set_action(
        'HASEL_HOLIDAY_REMINDERS',
        'BEGIN pkg_aox_job_wrapper.pr_process_holiday_reminders; END;'
    );
    set_action(
        'HASEL_PROCESS_EMBEDDING_OUTBOX',
        'BEGIN pkg_aox_job_wrapper.pr_process_embedding_outbox; END;'
    );
    set_action(
        'HASEL_PROCESS_SURVEY_REQUESTS',
        'BEGIN pkg_aox_job_wrapper.pr_process_survey_requests; END;'
    );
    set_action(
        'HASEL_REFUND_DISPUTE_CHECK',
        'BEGIN pkg_aox_job_wrapper.pr_process_refund_disputes; END;'
    );
    set_action(
        'JOB_REVOKE_EXPIRED_SESSIONS_JOB',
        'BEGIN pkg_aox_job_wrapper.pr_revoke_expired_sessions; END;'
    );
    set_action(
        'JOB_SYNC_ORG_EMBEDDINGS',
        'BEGIN pkg_aox_job_wrapper.pr_sync_org_embeddings; END;',
        'pkg_aox_job_wrapper.pr_sync_org_embeddings'
    );

    BEGIN
        DBMS_SCHEDULER.DISABLE(
            name  => 'JOB_EXPIRE_PAGOPAR_PAYMENTS',
            force => TRUE
        );
        DBMS_OUTPUT.PUT_LINE('DISABLE JOB_EXPIRE_PAGOPAR_PAYMENTS (duplicado)');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE NOT IN (-27476, -27475) THEN
                RAISE;
            END IF;
            DBMS_OUTPUT.PUT_LINE('SKIP DISABLE JOB_EXPIRE_PAGOPAR_PAYMENTS: ' || SQLERRM);
    END;
END;
/

PROMPT --- Probes jobs-ops ---
DECLARE
    v_action   user_scheduler_jobs.job_action%TYPE;
    v_enabled  VARCHAR2(5);
    v_cnt      NUMBER;
    v_called   BOOLEAN;
BEGIN
    SELECT COUNT(*)
      INTO v_cnt
      FROM user_procedures
     WHERE object_name = 'PKG_AOX_AUTH_API'
       AND procedure_name = 'PR_REVOKE_EXPIRED_SESSIONS';
    IF v_cnt = 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: falta pr_revoke_expired_sessions');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe pr_revoke_expired_sessions declarado OK');

    pkg_aox_auth_api.pr_revoke_expired_sessions;
    DBMS_OUTPUT.PUT_LINE('Probe revoke expired (tabla C) OK');

    v_called := FALSE;
    BEGIN
        EXECUTE IMMEDIATE 'BEGIN pkg_aox_session.begin_job; END;';
        v_called := TRUE;
    EXCEPTION
        WHEN OTHERS THEN
            v_called := FALSE;
            DBMS_OUTPUT.PUT_LINE('Probe begin_job fuera de wrapper/BG_JOB: ' || SQLCODE);
    END;
    IF v_called THEN
        BEGIN
            EXECUTE IMMEDIATE 'BEGIN pkg_aox_session.end_job; END;';
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
        RAISE_APPLICATION_ERROR(-20000, 'Probe: begin_job debio ser inaccesible o rechazado');
    END IF;
    IF pkg_aox_session.fn_access_mode IS NOT NULL THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: leftover ACCESS_MODE tras begin_job bloqueado');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe begin_job no invocable desde bloque anonimo OK');

    SELECT job_action
      INTO v_action
      FROM user_scheduler_jobs
     WHERE job_name = 'JOB_REVOKE_EXPIRED_SESSIONS_JOB';
    IF UPPER(v_action) NOT LIKE '%PKG_AOX_JOB_WRAPPER.PR_REVOKE_EXPIRED_SESSIONS%' THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: revoke job no apunta al wrapper');
    END IF;

    SELECT job_action
      INTO v_action
      FROM user_scheduler_jobs
     WHERE job_name = 'HASEL_EXPIRE_PENDING_PAYMENTS';
    IF UPPER(v_action) NOT LIKE '%PKG_AOX_JOB_WRAPPER.PR_EXPIRE_PENDING_PAYMENTS%' THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: expire payments no apunta al wrapper');
    END IF;

    SELECT enabled
      INTO v_enabled
      FROM user_scheduler_jobs
     WHERE job_name = 'JOB_EXPIRE_PAGOPAR_PAYMENTS';
    IF v_enabled <> 'FALSE' THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: JOB_EXPIRE_PAGOPAR_PAYMENTS sigue enabled');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe jobs reapuntados y Pagopar duplicado off OK');
END;
/

PROMPT === 20260919_aox_tenant_jobs_ops listo ===
