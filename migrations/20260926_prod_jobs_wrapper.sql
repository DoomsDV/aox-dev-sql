-- Jobs de produccion al wrapper VPD.
-- 20260919_aox_tenant_jobs_ops solo reapunta los jobs que existen en aoxdevelop. Prod tiene
-- jobs propios que llaman a los paquetes directo; con VPD encendido correrian sin contexto
-- (predicado 1=2) y no procesarian nada:
--   JOB_PROCESS_ATTENDANCE_REMINDERS / _TIMEOUTS (WhatsApp confirmar asistencia),
--   JOB_HASEL_MORNING_DIGEST (push diario), HASEL_SYNC_ORG_EMBEDDINGS (nombre prod del sync),
--   HASEL_INCIDENT_MONITOR (creado a mano en prod sin wrapper).
-- Ademas crea JOB_REVOKE_EXPIRED_SESSIONS_JOB, que en aoxdevelop se creo a mano.
-- Como AOXDEV / WKSP_AOX. Idempotente. Respeta el enabled actual de cada job.

SET SERVEROUTPUT ON SIZE UNLIMITED

@@../packages/PKG_AOX_JOB_WRAPPER.pls

DECLARE
    PROCEDURE point_to_wrapper(pi_job VARCHAR2, pi_action VARCHAR2) IS
        v_enabled user_scheduler_jobs.enabled%TYPE;
    BEGIN
        SELECT enabled INTO v_enabled FROM user_scheduler_jobs WHERE job_name = pi_job;
        DBMS_SCHEDULER.disable(pi_job, force => TRUE);
        DBMS_SCHEDULER.set_attribute(pi_job, 'job_type', 'PLSQL_BLOCK');
        DBMS_SCHEDULER.set_attribute(pi_job, 'job_action', pi_action);
        IF v_enabled = 'TRUE' THEN
            DBMS_SCHEDULER.enable(pi_job);
        END IF;
        DBMS_OUTPUT.PUT_LINE('wrapper ' || pi_job || ' (enabled=' || v_enabled || ')');
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            DBMS_OUTPUT.PUT_LINE('SKIP job ausente ' || pi_job);
    END point_to_wrapper;
BEGIN
    point_to_wrapper('JOB_PROCESS_ATTENDANCE_REMINDERS',
                     'BEGIN pkg_aox_job_wrapper.pr_process_attendance_reminders; END;');
    point_to_wrapper('JOB_PROCESS_ATTENDANCE_TIMEOUTS',
                     'BEGIN pkg_aox_job_wrapper.pr_process_attendance_timeouts; END;');
    point_to_wrapper('JOB_HASEL_MORNING_DIGEST',
                     'BEGIN pkg_aox_job_wrapper.pr_process_morning_digest; END;');
    point_to_wrapper('HASEL_SYNC_ORG_EMBEDDINGS',
                     'BEGIN pkg_aox_job_wrapper.pr_sync_org_embeddings; END;');
    point_to_wrapper('JOB_SYNC_ORG_EMBEDDINGS',
                     'BEGIN pkg_aox_job_wrapper.pr_sync_org_embeddings; END;');
    -- En prod se creo a mano (2026-09-25) sin wrapper; 20260924_ops_incident_monitor solo lo crea si falta.
    point_to_wrapper('HASEL_INCIDENT_MONITOR',
                     'BEGIN pkg_aox_job_wrapper.pr_process_incident_monitor; END;');
END;
/

DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count
      FROM user_scheduler_jobs
     WHERE job_name = 'JOB_REVOKE_EXPIRED_SESSIONS_JOB';
    IF v_count = 0 THEN
        DBMS_SCHEDULER.create_job(
            job_name        => 'JOB_REVOKE_EXPIRED_SESSIONS_JOB',
            job_type        => 'PLSQL_BLOCK',
            job_action      => 'BEGIN pkg_aox_job_wrapper.pr_revoke_expired_sessions; END;',
            start_date      => SYSTIMESTAMP,
            repeat_interval => 'FREQ=MINUTELY; INTERVAL=15',
            enabled         => TRUE,
            comments        => 'Revoca refresh tokens vencidos (APP_USER_SESSION).'
        );
        DBMS_OUTPUT.PUT_LINE('CREATED JOB_REVOKE_EXPIRED_SESSIONS_JOB');
    ELSE
        DBMS_OUTPUT.PUT_LINE('JOB_REVOKE_EXPIRED_SESSIONS_JOB ya existe');
    END IF;
END;
/

SELECT job_name, enabled, SUBSTR(job_action, 1, 70) AS job_action
  FROM user_scheduler_jobs
 ORDER BY job_name;
