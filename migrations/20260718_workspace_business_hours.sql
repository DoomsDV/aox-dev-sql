-- Migracion: horario comercial informativo (perfil publico)
-- Solo vitrina; no afecta reservas / professional_schedule.

PROMPT === workspace_setting.business_hours (JSON) ===
BEGIN
    EXECUTE IMMEDIATE q'[ALTER TABLE workspace_setting ADD business_hours VARCHAR2(4000) NULL]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;
END;
/

PROMPT === Migracion business_hours OK ===
