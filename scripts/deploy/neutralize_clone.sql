-- SOLO CLON DE ENSAYO: neutralizar un clon de aoxprod apenas queda Available.
-- Correr como ADMIN en Database Actions > SQL del clon (F5).
-- El clon arranca con los jobs y las keys de prod: sin esto manda WhatsApp, push y
-- alertas reales a clientes. En la base de produccion (G9549F707E8EBFA_AOX) aborta.
-- Idempotente: si se corre de nuevo, conserva el respaldo de los valores originales.
-- Los jobs que crea el pase despues los apaga el manifiesto (CLONE_DISABLE_JOBS).

SET SERVEROUTPUT ON

DECLARE
    v_db VARCHAR2(128) := SYS_CONTEXT('USERENV', 'DB_NAME');
BEGIN
    IF UPPER(v_db) = 'G9549F707E8EBFA_AOX' THEN
        RAISE_APPLICATION_ERROR(-20000, 'ESTO ES PRODUCCION (' || v_db || '). No se toca nada.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Base: ' || v_db);

    -- 1) Frenar lo que este corriendo y deshabilitar todos los jobs del esquema.
    FOR j IN (SELECT owner, job_name FROM dba_scheduler_running_jobs WHERE owner = 'WKSP_AOX') LOOP
        BEGIN
            DBMS_SCHEDULER.stop_job(j.owner || '.' || j.job_name, force => TRUE);
            DBMS_OUTPUT.PUT_LINE('stop    ' || j.job_name);
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('stop ERR ' || j.job_name || ': ' || SQLERRM);
        END;
    END LOOP;

    FOR j IN (SELECT owner, job_name FROM dba_scheduler_jobs
               WHERE owner = 'WKSP_AOX' AND enabled = 'TRUE') LOOP
        DBMS_SCHEDULER.disable(j.owner || '.' || j.job_name, force => TRUE);
        DBMS_OUTPUT.PUT_LINE('disable ' || j.job_name);
    END LOOP;

    -- 2) Respaldar en ADMIN los parametros que se van a pisar (solo la primera vez).
    BEGIN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE admin.clone_param_bak AS
            SELECT param_key, param_value, SYSTIMESTAMP AS saved_at
              FROM wksp_aox.app_parameter
             WHERE param_key IN (
                   'META_API_KEY', 'FCM_PUSH_SERVICE_BEARER', 'FCM_PUSH_SERVICE_URL',
                   'SUBSCRIPTION_PAGOPAR_PRIVATE_KEY', 'SUBSCRIPTION_PAGOPAR_PUBLIC_KEY',
                   'ESIGN_CALLBACK_SERVICE_TOKEN', 'OPS_ALERT_ENABLED', 'OPS_ALERT_PHONE')]';
        DBMS_OUTPUT.PUT_LINE('respaldo admin.clone_param_bak creado');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -955 THEN
                RAISE;
            END IF;
            DBMS_OUTPUT.PUT_LINE('respaldo admin.clone_param_bak ya existe (se conserva)');
    END;

    -- 3) Cortar salidas a terceros: WhatsApp (Meta), push (FCM), Pagopar, eSign, alertas ops.
    UPDATE wksp_aox.app_parameter
       SET param_value = CASE param_key
                             WHEN 'OPS_ALERT_ENABLED'    THEN '0'
                             WHEN 'FCM_PUSH_SERVICE_URL' THEN 'https://clone-disabled.invalid'
                             ELSE 'DISABLED_IN_CLONE'
                         END
     WHERE param_key IN (
           'META_API_KEY', 'FCM_PUSH_SERVICE_BEARER', 'FCM_PUSH_SERVICE_URL',
           'SUBSCRIPTION_PAGOPAR_PRIVATE_KEY', 'SUBSCRIPTION_PAGOPAR_PUBLIC_KEY',
           'ESIGN_CALLBACK_SERVICE_TOKEN', 'OPS_ALERT_ENABLED', 'OPS_ALERT_PHONE');
    DBMS_OUTPUT.PUT_LINE('parametros neutralizados: ' || SQL%ROWCOUNT);
    COMMIT;
END;
/

-- 4) Verificacion: debe dar 0 jobs habilitados y 8 parametros neutralizados.
SELECT COUNT(*) AS jobs_habilitados
  FROM dba_scheduler_jobs
 WHERE owner = 'WKSP_AOX' AND enabled = 'TRUE';

SELECT param_key, param_value
  FROM wksp_aox.app_parameter
 WHERE param_key IN (SELECT param_key FROM admin.clone_param_bak)
 ORDER BY 1;
