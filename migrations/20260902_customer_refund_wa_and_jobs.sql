PROMPT === Seed plantilla WhatsApp: reembolso_pendiente_cliente_v1 ===
--
-- Acuse al cliente que cancela con reembolso (no pide alias: ya lo cargo en /r/{token}).
-- Plantilla Meta a registrar (aprobacion externa):
--   nombre: reembolso_pendiente_cliente_v1
--   body: Hola {{1}}, cancelaste tu turno en {{2}}. Te corresponde un reembolso de {{3}}
--         por la seña. El comercio te transferira en hasta 48 horas habiles. Turno: {{4}}.
--   boton URL: https://hasel.app/r/{{1}}  (sufijo = public_manage_token)
-- Hasta que Meta apruebe la plantilla, el envio queda logueado en aox_api_log si falla.

MERGE INTO app_parameter t
USING (
    SELECT
        'META_WA_TEMPLATE_CUSTOMER_REFUND' AS param_key,
        'reembolso_pendiente_cliente_v1' AS param_value,
        'Plantilla Meta: acuse de reembolso cuando cancela el cliente (body: cliente, org, monto, fecha/hora; boton https://hasel.app/r/{{token}}).' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN MATCHED THEN
    UPDATE SET
        t.param_value = s.param_value,
        t.description = s.description
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);

COMMIT;

PROMPT Verificación:
SELECT param_key, param_value, description
  FROM app_parameter
 WHERE param_key = 'META_WA_TEMPLATE_CUSTOMER_REFUND';

PROMPT === Chequeo job HASEL_REFUND_DISPUTE_CHECK ===
SELECT job_name, enabled, state, run_count, failure_count, last_start_date
  FROM user_scheduler_jobs
 WHERE job_name = 'HASEL_REFUND_DISPUTE_CHECK';
