PROMPT === Fase 2 (plan correccion N+1): patron Transactional Outbox ===
PROMPT === 2a) Triggers de embeddings (customer/professional/service/location) ===
PROMPT === 2b) Campanas push FCM (envio invertido: encolar primero, despachar despues) ===

PROMPT === 1) Tabla embedding_sync_outbox ===
@@../tables/EMBEDDING_SYNC_OUTBOX.sql

PROMPT === 2) Columna resolved_url en push_campaign_delivery (idempotente) ===
DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_count
      FROM user_tab_columns
     WHERE table_name  = 'PUSH_CAMPAIGN_DELIVERY'
       AND column_name = 'RESOLVED_URL';

    IF v_count = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE push_campaign_delivery ADD (resolved_url VARCHAR2(1000) NULL)';
    END IF;
END;
/

PROMPT === 3) Paquete PKG_AOX_VECTOR_SEARCH (pr_enqueue_embedding_sync + pr_process_embedding_outbox) ===
@@../packages/PKG_AOX_VECTOR_SEARCH.pls

PROMPT === 4) Triggers DML (ahora encolan en vez de llamar a Azure OpenAI directo) ===
@@../triggers/TRG_VECTOR_EMBEDDING_SYNC.sql

PROMPT === 5) Paquete PKG_AOX_PUSH_CAMPAIGN (pr_execute_campaign invertido + pr_dispatch_campaign_deliveries) ===
@@../packages/PKG_AOX_PUSH_CAMPAIGN.pls

PROMPT === 6) Job HASEL_PROCESS_EMBEDDING_OUTBOX (cada ~30s) ===
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_PROCESS_EMBEDDING_OUTBOX', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HASEL_PROCESS_EMBEDDING_OUTBOX',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN pkg_aox_vector_search.pr_process_embedding_outbox(50); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY; INTERVAL=30',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'Fase 2: dequeue de embedding_sync_outbox (FOR UPDATE SKIP LOCKED), llama a Azure OpenAI fuera de la transaccion del trigger.'
    );
END;
/

PROMPT === 7) Job HASEL_DISPATCH_PUSH_CAMPAIGNS (cada ~30s) ===
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_DISPATCH_PUSH_CAMPAIGNS', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HASEL_DISPATCH_PUSH_CAMPAIGNS',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN pkg_aox_push_campaign.pr_dispatch_campaign_deliveries(100); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=SECONDLY; INTERVAL=30',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'Fase 2: dequeue de push_campaign_delivery PENDING (FOR UPDATE SKIP LOCKED), despacha a FCM fuera de pr_execute_campaign.'
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
 WHERE job_name IN ('HASEL_PROCESS_EMBEDDING_OUTBOX', 'HASEL_DISPATCH_PUSH_CAMPAIGNS');

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('PKG_AOX_VECTOR_SEARCH', 'PKG_AOX_PUSH_CAMPAIGN', 'EMBEDDING_SYNC_OUTBOX')
 ORDER BY object_name, object_type;
