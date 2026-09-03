PROMPT === Retirar plantilla WhatsApp legacy cita_confirmada ===
--
-- Meta ya no tiene cita_confirmada. El único caller (PKG_AOX_AI_TOOLS.fn_create_appointment)
-- ahora usa META_WA_TEMPLATE_BOOKING via pr_enqueue_booking_confirmation_wa.

DELETE FROM app_parameter
 WHERE param_key = 'META_WA_TEMPLATE_LEGACY';

COMMIT;

PROMPT Verificación (0 filas esperado):
SELECT param_key, param_value
  FROM app_parameter
 WHERE param_key = 'META_WA_TEMPLATE_LEGACY';
