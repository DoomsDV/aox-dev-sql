-- Jobs que el pase 2026-09 crea habilitados pero quedan APAGADOS por decision (2026-09-26):
--   HASEL_PROCESS_SURVEY_REQUESTS   (encuestas CSAT por WhatsApp)
--   HASEL_PAGOPAR_RECONCILE         (reconciliacion Pagopar; solo con el cobro encendido)
--   HASEL_ADMIN_DISPATCH_CAMPAIGNS  (campanas push de HASEL_ADMIN)
-- Corre en prod y en el clon, como WKSP_AOX o HASEL_ADMIN: apaga los que existan en el
-- esquema conectado. El manifiesto lo llama justo despues de cada migracion que los crea,
-- para que no lleguen a correr durante el pase. Idempotente.
-- Para encenderlos mas adelante: DBMS_SCHEDULER.enable('<job>') como el owner.

SET SERVEROUTPUT ON

BEGIN
    FOR j IN (SELECT job_name, enabled
                FROM user_scheduler_jobs
               WHERE job_name IN ('HASEL_PROCESS_SURVEY_REQUESTS',
                                  'HASEL_PAGOPAR_RECONCILE',
                                  'HASEL_ADMIN_DISPATCH_CAMPAIGNS')) LOOP
        IF j.enabled = 'TRUE' THEN
            DBMS_SCHEDULER.disable(j.job_name, force => TRUE);
            DBMS_OUTPUT.PUT_LINE('apagado ' || j.job_name);
        ELSE
            DBMS_OUTPUT.PUT_LINE('ya apagado ' || j.job_name);
        END IF;
    END LOOP;
END;
/
