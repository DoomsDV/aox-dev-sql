PROMPT === Actualizar plantilla WhatsApp: cancelacion_reserva_manual_hasel_v3 ===
--
-- Reemplaza cancelacion_reserva_manual_hasel_v2. Mismas variables:
--   body {{1}} = nombre del cliente
--   body {{2}} = nombre del establecimiento (organization.name, no sucursal)
--   body {{3}} = fecha y hora del turno (DD-MM-YYYY HH24:MI)
--   boton URL: https://hasel.app/{{1}}
--     sufijo = org_slug/p/pro_slug  (ej. fisio-av/p/dann-vergara)

MERGE INTO app_parameter t
USING (
    SELECT
        'META_WA_TEMPLATE_CANCEL' AS param_key,
        'cancelacion_reserva_manual_hasel_v3' AS param_value,
        'Plantilla Meta: cancelación manual v3 (body: cliente, establecimiento, fecha/hora; botón org/p/pro).' AS description
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
 WHERE param_key = 'META_WA_TEMPLATE_CANCEL';
