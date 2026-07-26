PROMPT === Seed plantilla WhatsApp: rechazo comprobante seña SIPAP ===

MERGE INTO app_parameter t
USING (
    SELECT
        'META_WA_TEMPLATE_PAYMENT_REJECT' AS param_key,
        'rechazo_comprobante_sena_v1' AS param_value,
        'Plantilla Meta: comercio rechaza comprobante de seña SIPAP (body: cliente, org, fecha/hora, motivo; boton reserva {{token}}).' AS description
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
 WHERE param_key = 'META_WA_TEMPLATE_PAYMENT_REJECT';
