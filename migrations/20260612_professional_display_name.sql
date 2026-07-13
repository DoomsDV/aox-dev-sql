-- =============================================================================
-- display_name por organizacion (professional + org_invitation)
-- Reemplaza invite_first_name / invite_last_name.
-- No modifica profile_slug ni public_slug.
--
-- ORDEN:
--   1) Ejecutar este script
--   2) Recompilar packages afectados (ver install_all o checklist)
--   3) Template APEX ACCEPTINVITE sin #FIRST_NAME#
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 1) Columna professional.display_name ===

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE professional ADD display_name VARCHAR2(150)';
    DBMS_OUTPUT.PUT_LINE('professional.display_name agregada.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN
            DBMS_OUTPUT.PUT_LINE('professional.display_name ya existe.');
        ELSE
            RAISE;
        END IF;
END;
/

PROMPT === 2) Columna org_invitation.display_name ===

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_invitation ADD display_name VARCHAR2(150)';
    DBMS_OUTPUT.PUT_LINE('org_invitation.display_name agregada.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN
            DBMS_OUTPUT.PUT_LINE('org_invitation.display_name ya existe.');
        ELSE
            RAISE;
        END IF;
END;
/

PROMPT === 3) Backfill org_invitation.display_name desde invite_* ===

DECLARE
    v_has_invite_cols NUMBER := 0;
BEGIN
    SELECT COUNT(*)
      INTO v_has_invite_cols
      FROM user_tab_columns
     WHERE table_name = 'ORG_INVITATION'
       AND column_name = 'INVITE_FIRST_NAME';

    IF v_has_invite_cols > 0 THEN
        EXECUTE IMMEDIATE q'[
            UPDATE org_invitation
               SET display_name = TRIM(invite_first_name || ' ' || invite_last_name)
             WHERE display_name IS NULL
               AND (invite_first_name IS NOT NULL OR invite_last_name IS NOT NULL)
        ]';
        DBMS_OUTPUT.PUT_LINE('org_invitation.display_name backfill desde invite_*.');
    END IF;
END;
/

PROMPT === 4) Backfill professional.display_name (activos desde platform_user) ===

BEGIN
    EXECUTE IMMEDIATE q'[
        UPDATE professional p
           SET display_name = (
                 SELECT TRIM(pu.first_name || ' ' || pu.last_name)
                   FROM org_member m
                   JOIN platform_user pu ON pu.id_platform_user = m.platform_user_id
                  WHERE m.id_org_member = p.usr_id_user
               )
         WHERE p.display_name IS NULL
           AND p.usr_id_user IS NOT NULL
    ]';
    DBMS_OUTPUT.PUT_LINE('professional.display_name backfill desde platform_user.');
END;
/

PROMPT === 5) Backfill professional.display_name (pendientes desde org_invitation) ===

BEGIN
    EXECUTE IMMEDIATE q'[
        UPDATE professional p
           SET display_name = (
                 SELECT i.display_name
                   FROM org_invitation i
                  WHERE i.pro_id_professional = p.id_professional
                    AND i.status = 'PENDING'
                  FETCH FIRST 1 ROW ONLY
               )
         WHERE p.display_name IS NULL
           AND p.usr_id_user IS NULL
    ]';
    DBMS_OUTPUT.PUT_LINE('professional.display_name backfill desde invitaciones pendientes.');
END;
/

PROMPT === 6) Fallback: humanizar profile_slug ===

BEGIN
    EXECUTE IMMEDIATE q'[
        UPDATE professional
           SET display_name = INITCAP(REPLACE(REPLACE(TRIM(profile_slug), '-', ' '), '_', ' '))
         WHERE display_name IS NULL
           AND profile_slug IS NOT NULL
           AND TRIM(profile_slug) IS NOT NULL
    ]';
    DBMS_OUTPUT.PUT_LINE('professional.display_name fallback desde profile_slug.');
END;
/

PROMPT === 7) Sincronizar invitation.display_name faltante desde professional ===

BEGIN
    EXECUTE IMMEDIATE q'[
        UPDATE org_invitation i
           SET display_name = (
                 SELECT p.display_name
                   FROM professional p
                  WHERE p.id_professional = i.pro_id_professional
               )
         WHERE i.display_name IS NULL
           AND i.status = 'PENDING'
    ]';
    DBMS_OUTPUT.PUT_LINE('org_invitation.display_name sincronizado desde professional.');
END;
/

PROMPT === 8) DROP invite_first_name / invite_last_name ===

DECLARE
    v_has_invite_cols NUMBER := 0;
BEGIN
    SELECT COUNT(*)
      INTO v_has_invite_cols
      FROM user_tab_columns
     WHERE table_name = 'ORG_INVITATION'
       AND column_name = 'INVITE_FIRST_NAME';

    IF v_has_invite_cols > 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE org_invitation DROP COLUMN invite_first_name';
        EXECUTE IMMEDIATE 'ALTER TABLE org_invitation DROP COLUMN invite_last_name';
        DBMS_OUTPUT.PUT_LINE('Columnas invite_first_name / invite_last_name eliminadas.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('invite_* ya no existen.');
    END IF;
END;
/

PROMPT === 9) Trigger slug: usar display_name en pendientes ===

CREATE OR REPLACE TRIGGER trg_professional_slug
BEFORE INSERT OR UPDATE OF profile_slug, usr_id_user, display_name ON professional
FOR EACH ROW
DECLARE
    v_first_name platform_user.first_name%TYPE;
    v_last_name  platform_user.last_name%TYPE;
    v_source     VARCHAR2(300);
BEGIN
    IF :NEW.profile_slug IS NOT NULL THEN
        :NEW.profile_slug := pkg_aox_util.fn_generate_slug(:NEW.profile_slug);
        RETURN;
    END IF;

    IF :NEW.usr_id_user IS NOT NULL THEN
        IF :NEW.display_name IS NOT NULL AND TRIM(:NEW.display_name) IS NOT NULL THEN
            v_source := TRIM(:NEW.display_name) || '-' || :NEW.usr_id_user;
        ELSE
            SELECT pu.first_name, pu.last_name
              INTO v_first_name, v_last_name
              FROM org_member m
              JOIN platform_user pu ON pu.id_platform_user = m.platform_user_id
             WHERE m.id_org_member = :NEW.usr_id_user;

            v_source := v_first_name || ' ' || v_last_name || '-' || :NEW.usr_id_user;
        END IF;

        :NEW.profile_slug := pkg_aox_util.fn_generate_slug(v_source);
        RETURN;
    END IF;

    IF :NEW.display_name IS NOT NULL AND TRIM(:NEW.display_name) IS NOT NULL THEN
        :NEW.profile_slug := pkg_aox_util.fn_generate_slug(TRIM(:NEW.display_name));
        RETURN;
    END IF;

    :NEW.profile_slug := pkg_aox_util.fn_generate_slug('profesional-' || lower(rawtohex(sys_guid())));
END;
/

PROMPT === Migracion display_name completada ===
