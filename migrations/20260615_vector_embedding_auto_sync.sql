PROMPT === Fase 2: reindex automatico de embeddings ===

PROMPT === 1) Paquete PKG_AOX_VECTOR_SEARCH (sync masivo + hook triggers) ===
@@../packages/PKG_AOX_VECTOR_SEARCH.pls

PROMPT === 2) Triggers DML ===
@@../triggers/TRG_VECTOR_EMBEDDING_SYNC.sql

PROMPT === 3) Job nocturno DBMS_SCHEDULER (03:00) ===

BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_SYNC_ORG_EMBEDDINGS', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HASEL_SYNC_ORG_EMBEDDINGS',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PKG_AOX_VECTOR_SEARCH.PR_SYNC_ALL_ORGS_EMBEDDINGS',
        start_date      => TRUNC(SYSTIMESTAMP) + INTERVAL '1' DAY + INTERVAL '3' HOUR,
        repeat_interval => 'FREQ=DAILY; BYHOUR=3; BYMINUTE=0; BYSECOND=0',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'Reindexa embeddings de clientes, profesionales, servicios y sucursales por org'
    );
END;
/

COMMIT;

PROMPT === Verificacion ===
SELECT trigger_name, table_name, status
  FROM user_triggers
 WHERE trigger_name LIKE 'TRG_%VECTOR_EMBEDDING%'
 ORDER BY trigger_name;

SELECT job_name, enabled, state, repeat_interval, next_run_date
  FROM user_scheduler_jobs
 WHERE job_name = 'HASEL_SYNC_ORG_EMBEDDINGS';

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name = 'PKG_AOX_VECTOR_SEARCH'
 ORDER BY object_type;
