PROMPT === Actualizar plantilla WhatsApp: cancelacion_auto_hasel_v3 ===
--
-- Reemplaza cancelacion_auto_hasel_v2 ({{2}} = solo HH24:MI).
-- Plantilla Meta a registrar (aprobacion externa):
--   nombre: cancelacion_auto_hasel_v3
--   body:
--     ¡Hola, {{1}}! Tu reserva del {{2}} en {{3}} ha sido cancelada
--     automáticamente debido a la falta de confirmación.
--
--     Si seguís necesitando el espacio, podés revisar la disponibilidad
--     y agendar un nuevo horario con el botón de abajo.
--   {{1}} = nombre del cliente
--   {{2}} = fecha y hora del turno (DD-MM-YYYY HH24:MI)
--   {{3}} = nombre de la organización
--   boton URL: mismo sufijo que v2 (org_slug/p/pro_slug via fn_public_booking_path_suffix)

MERGE INTO app_parameter t
USING (
    SELECT
        'META_WA_TEMPLATE_AUTO_CANCEL' AS param_key,
        'cancelacion_auto_hasel_v3' AS param_value,
        'Plantilla Meta: cancelación automática por timeout de asistencia (body: cliente, fecha/hora, org; botón Volver a agendar).' AS description
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
 WHERE param_key = 'META_WA_TEMPLATE_AUTO_CANCEL';
