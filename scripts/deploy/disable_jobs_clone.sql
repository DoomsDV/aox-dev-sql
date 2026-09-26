-- SOLO CLON DE ENSAYO: frena y deshabilita todos los jobs del esquema conectado.
-- En la base de produccion aborta sin tocar nada.
BEGIN
    IF SYS_CONTEXT('USERENV', 'DB_NAME') = 'G9549F707E8EBFA_AOX' THEN
        RAISE_APPLICATION_ERROR(-20000, 'disable_jobs_clone.sql no se corre en produccion');
    END IF;
    FOR j IN (SELECT job_name FROM user_scheduler_running_jobs) LOOP
        BEGIN
            DBMS_SCHEDULER.stop_job(j.job_name, force => TRUE);
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
    END LOOP;
    FOR j IN (SELECT job_name FROM user_scheduler_jobs WHERE enabled = 'TRUE') LOOP
        DBMS_SCHEDULER.disable(j.job_name, force => TRUE);
        DBMS_OUTPUT.PUT_LINE('disable ' || j.job_name);
    END LOOP;
END;
/
