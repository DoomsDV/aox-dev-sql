-- =============================================================================
-- Admin: preferencia personal para recibir pushes de todos los profesionales
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === org_member.notify_all_professionals ===

BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE org_member ADD (
            notify_all_professionals CHAR(1) DEFAULT 'N' NOT NULL
        )
    ]';
    DBMS_OUTPUT.PUT_LINE('Columna notify_all_professionals agregada.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN
            DBMS_OUTPUT.PUT_LINE('notify_all_professionals ya existe, se omite ADD.');
        ELSE
            RAISE;
        END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE org_member ADD CONSTRAINT chk_om_notify_all_professionals
            CHECK (notify_all_professionals IN ('Y', 'N'))
    ]';
    DBMS_OUTPUT.PUT_LINE('Constraint chk_om_notify_all_professionals agregada.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -2260 OR SQLCODE = -2275 OR SQLCODE = -2264 THEN
            DBMS_OUTPUT.PUT_LINE('Constraint chk_om_notify_all_professionals ya existe, se omite.');
        ELSE
            RAISE;
        END IF;
END;
/

COMMENT ON COLUMN org_member.notify_all_professionals IS
    'Y = el admin recibe pushes de citas de otros profesionales de la org. Default N.';
/

COMMIT;
/