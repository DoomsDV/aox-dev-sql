-- Migración: configuración de sistema en workspace (slots, recordatorios, espera cancelación)
-- Ejecutar después de REF_* y antes de recompilar paquetes.

PROMPT === Tablas de referencia (si no existen) ===
@@../tables/REF_BOOKING_SLOT_INTERVAL.sql
@@../tables/REF_REMINDER_HOURS.sql
@@../tables/REF_CANCEL_WAIT_HOURS.sql

PROMPT === Columnas en workspace_setting ===
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE workspace_setting ADD (rsi_id_slot_interval NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE workspace_setting ADD (rh_id_reminder_hours NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE workspace_setting ADD (cwh_id_cancel_wait_hours NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

PROMPT === Foreign keys ===
BEGIN
  EXECUTE IMMEDIATE '
    ALTER TABLE workspace_setting
      ADD CONSTRAINT fk_ws_slot_interval FOREIGN KEY (rsi_id_slot_interval)
      REFERENCES ref_booking_slot_interval (id_slot_interval)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-2275, -2261) THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE '
    ALTER TABLE workspace_setting
      ADD CONSTRAINT fk_ws_reminder_hours FOREIGN KEY (rh_id_reminder_hours)
      REFERENCES ref_reminder_hours (id_reminder_hours)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-2275, -2261) THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE '
    ALTER TABLE workspace_setting
      ADD CONSTRAINT fk_ws_cancel_wait_hours FOREIGN KEY (cwh_id_cancel_wait_hours)
      REFERENCES ref_cancel_wait_hours (id_cancel_wait_hours)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-2275, -2261) THEN RAISE; END IF;
END;
/

PROMPT === Defaults para filas existentes ===
UPDATE workspace_setting ws
   SET rsi_id_slot_interval = (
         SELECT id_slot_interval
           FROM ref_booking_slot_interval
          WHERE minutes_value = 30
            AND is_active = 1
          FETCH FIRST 1 ROW ONLY
       )
 WHERE ws.rsi_id_slot_interval IS NULL;

UPDATE workspace_setting ws
   SET rh_id_reminder_hours = (
         SELECT id_reminder_hours
           FROM ref_reminder_hours
          WHERE hours_value = 24
            AND is_active = 1
          FETCH FIRST 1 ROW ONLY
       )
 WHERE ws.rh_id_reminder_hours IS NULL;

UPDATE workspace_setting ws
   SET cwh_id_cancel_wait_hours = (
         SELECT id_cancel_wait_hours
           FROM ref_cancel_wait_hours
          WHERE hours_value = 3
            AND is_active = 1
          FETCH FIRST 1 ROW ONLY
       )
 WHERE ws.cwh_id_cancel_wait_hours IS NULL
   AND NVL(ws.unanswered_alert_action, 'KEEP') = 'CANCEL';

COMMIT;

PROMPT === Recompilar paquetes ===
@@../packages/PKG_AOX_UTIL.pls
@@../packages/PKG_AOX_WORKSPACE_API.pls
@@../packages/PKG_AOX_META_API.pls
@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls
