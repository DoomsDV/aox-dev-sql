-- Fix: eliminar cita con seña PENDING fallaba por FK_PAYTX_APP (child record found).
-- Comportamiento: pr_delete_appointment borra reclamos + payment_transaction no pagados
-- antes del DELETE de appointment. Seña pagada sigue bloqueada (usar cancelación).
--
-- Desplegar: recompilar PKG_AOX_APPOINTMENT_API desde aox-dev/packages/.
PROMPT === 20260711_delete_appointment_clear_pending_paytx ===
PROMPT Recompilar PKG_AOX_APPOINTMENT_API (pr_delete_appointment limpia paytx no pagados).
/
