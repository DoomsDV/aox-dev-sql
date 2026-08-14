-- Excepcion aprobada de conflictos de horario (panel).
-- No cambia appointment.status. La alerta naranja sale del sheet si la huella
-- del slot coincide; el calendario pinta borde verde dashed.

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (schedule_exception_approved NUMBER(1) DEFAULT 0 NOT NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (schedule_exception_approved_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (schedule_exception_approved_by NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (schedule_exception_reason VARCHAR2(40) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (schedule_exception_start TIMESTAMP(6) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (schedule_exception_end TIMESTAMP(6) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (schedule_exception_loc NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (schedule_exception_pro NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment DROP CONSTRAINT chk_app_sched_exc_approved';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -2443 THEN RAISE; END IF;
END;
/

ALTER TABLE appointment
  ADD CONSTRAINT chk_app_sched_exc_approved CHECK (
    schedule_exception_approved IN (0, 1)
  )
/

COMMENT ON COLUMN appointment.schedule_exception_approved IS
  '1 si el staff aprobo una excepcion de agenda para el slot actual (huella). Independiente de appointment.status.';
/

COMMENT ON COLUMN appointment.schedule_exception_approved_at IS
  'Momento en que se aprobo la excepcion de horario.';
/

COMMENT ON COLUMN appointment.schedule_exception_approved_by IS
  'user_id (JWT) del staff que aprobo la excepcion de horario.';
/

COMMENT ON COLUMN appointment.schedule_exception_reason IS
  'Motivo de desalineacion al aprobar: LOCATION_CLOSED|DAY_BLOCKED|TIME_OUTSIDE_SCHEDULE|WRONG_LOCATION.';
/

COMMENT ON COLUMN appointment.schedule_exception_start IS
  'Huella: start_time del slot para el que vale la excepcion.';
/

COMMENT ON COLUMN appointment.schedule_exception_end IS
  'Huella: end_time del slot para el que vale la excepcion.';
/

COMMENT ON COLUMN appointment.schedule_exception_loc IS
  'Huella: sucursal del slot para el que vale la excepcion.';
/

COMMENT ON COLUMN appointment.schedule_exception_pro IS
  'Huella: profesional del slot para el que vale la excepcion.';
/
