-- =============================================================================
-- FCM: dispositivos por platform_user (multi-org) en lugar de org_member aislado
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === FCM: agregar platform_user_id ===

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE user_fcm_devices ADD platform_user_id NUMBER';
    DBMS_OUTPUT.PUT_LINE('Columna platform_user_id agregada.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN
            DBMS_OUTPUT.PUT_LINE('platform_user_id ya existe, se omite ADD.');
        ELSE
            RAISE;
        END IF;
END;
/

UPDATE user_fcm_devices d
   SET platform_user_id = (
         SELECT m.platform_user_id
           FROM org_member m
          WHERE m.id_org_member = d.usr_id_user
       )
 WHERE d.platform_user_id IS NULL;

DECLARE
    v_orphans NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_orphans
      FROM user_fcm_devices
     WHERE platform_user_id IS NULL;

    IF v_orphans > 0 THEN
        RAISE_APPLICATION_ERROR(
            -20001,
            'Hay ' || v_orphans || ' filas en user_fcm_devices sin platform_user_id. Corregir antes de continuar.'
        );
    END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE '
        ALTER TABLE user_fcm_devices MODIFY platform_user_id NUMBER NOT NULL';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-1442) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE user_fcm_devices DROP CONSTRAINT fk_user_fcm';
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE user_fcm_devices DROP CONSTRAINT fk_fcm_org_member';
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

BEGIN
    EXECUTE IMMEDIATE '
        ALTER TABLE user_fcm_devices
        ADD CONSTRAINT fk_fcm_platform_user FOREIGN KEY (platform_user_id)
        REFERENCES platform_user (id_platform_user) ON DELETE CASCADE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-2261, -2264) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'CREATE INDEX idx_fcm_platform_user ON user_fcm_devices (platform_user_id)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-955, -1408) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE user_fcm_devices DROP COLUMN usr_id_user';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-904) THEN RAISE; END IF;
END;
/

PROMPT === FCM platform_user_id: listo ===
