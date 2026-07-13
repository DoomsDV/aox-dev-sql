PROMPT === Actualizar plantilla WhatsApp: confirmar_asistencia_reserva_v2 ===

MERGE INTO app_parameter t
USING (
    SELECT
        'META_WA_TEMPLATE_ATTENDANCE' AS param_key,
        'confirmar_asistencia_reserva_v2' AS param_value,
        'Plantilla Meta para solicitar confirmación de asistencia (quick reply Sí/No).' AS description
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
 WHERE param_key = 'META_WA_TEMPLATE_ATTENDANCE';
