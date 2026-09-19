PROMPT CREATE OR REPLACE PACKAGE pkg_aox_public_directory
CREATE OR REPLACE PACKAGE pkg_aox_public_directory AS
/**
 * Duenio de ORG_PUBLIC_DIRECTORY y ORG_PUBLIC_TOKEN (tablas sin VPD).
 * Lookup slug/token -> org_id para que pkg_aox_session.set_org no lea
 * tablas tenant. Triggers mantienen la proyeccion; no silencia bugs.
 */
    c_kind_appointment_manage CONSTANT VARCHAR2(30) := 'APPOINTMENT_MANAGE';

    FUNCTION fn_normalize_slug(
        pi_slug IN VARCHAR2
    ) RETURN VARCHAR2;

    FUNCTION fn_token_hash(
        pi_token IN VARCHAR2
    ) RETURN RAW;

    FUNCTION fn_org_id_by_slug(
        pi_slug IN VARCHAR2
    ) RETURN NUMBER;

    FUNCTION fn_slug_taken(
        pi_slug           IN VARCHAR2,
        pi_exclude_org_id IN NUMBER DEFAULT NULL
    ) RETURN NUMBER;

    PROCEDURE pr_resolve_token(
        pi_token            IN  VARCHAR2,
        po_org_id           OUT NUMBER,
        po_appointment_id   OUT NUMBER
    );

    PROCEDURE pr_sync_workspace(
        pi_org_id             IN NUMBER,
        pi_slug               IN VARCHAR2,
        pi_enforcement_level  IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE pr_apply_publication_flags(
        pi_org_id            IN NUMBER,
        pi_enforcement_level IN VARCHAR2
    );

    PROCEDURE pr_delete_org(
        pi_org_id IN NUMBER
    );

    PROCEDURE pr_sync_appointment_token(
        pi_appointment_id IN NUMBER,
        pi_org_id         IN NUMBER,
        pi_token          IN VARCHAR2
    );

    PROCEDURE pr_delete_appointment_token(
        pi_appointment_id IN NUMBER
    );

    PROCEDURE pr_refresh_all;
END pkg_aox_public_directory;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_public_directory
CREATE OR REPLACE PACKAGE BODY pkg_aox_public_directory AS

    FUNCTION fn_normalize_slug(
        pi_slug IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_slug VARCHAR2(100) := LOWER(TRIM(pi_slug));
    BEGIN
        IF v_slug IS NULL OR LENGTH(v_slug) = 0 THEN
            RETURN NULL;
        END IF;
        RETURN v_slug;
    END fn_normalize_slug;

    FUNCTION fn_token_hash(
        pi_token IN VARCHAR2
    ) RETURN RAW IS
        v_token VARCHAR2(128) := LOWER(TRIM(pi_token));
        v_hash  RAW(32);
    BEGIN
        IF v_token IS NULL OR LENGTH(v_token) = 0 THEN
            RETURN NULL;
        END IF;
        SELECT STANDARD_HASH(v_token, 'SHA256')
          INTO v_hash
          FROM dual;
        RETURN v_hash;
    END fn_token_hash;

    FUNCTION fn_is_unpublished_level(
        pi_level IN VARCHAR2
    ) RETURN NUMBER IS
    BEGIN
        IF UPPER(TRIM(NVL(pi_level, 'NONE'))) IN (
            'PUBLIC_UNPUBLISHED',
            'OPERATIONS_SUSPENDED'
        ) THEN
            RETURN 1;
        END IF;
        RETURN 0;
    END fn_is_unpublished_level;

    FUNCTION fn_blocks_booking_level(
        pi_level IN VARCHAR2
    ) RETURN NUMBER IS
    BEGIN
        IF UPPER(TRIM(NVL(pi_level, 'NONE'))) IN (
            'PUBLIC_BOOKINGS',
            'PUBLIC_UNPUBLISHED',
            'OPERATIONS_SUSPENDED'
        ) THEN
            RETURN 1;
        END IF;
        RETURN 0;
    END fn_blocks_booking_level;

    FUNCTION fn_enforcement_level(
        pi_org_id IN NUMBER,
        pi_level  IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_level VARCHAR2(30);
    BEGIN
        IF pi_level IS NOT NULL THEN
            RETURN UPPER(TRIM(pi_level));
        END IF;
        BEGIN
            SELECT /*+ no_parallel */ NVL(refund_enforcement_level, 'NONE')
              INTO v_level
              FROM org_payment_settings
             WHERE org_id_organization = pi_org_id;
            RETURN UPPER(TRIM(v_level));
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN 'NONE';
        END;
    END fn_enforcement_level;

    FUNCTION fn_org_id_by_slug(
        pi_slug IN VARCHAR2
    ) RETURN NUMBER IS
        v_slug   VARCHAR2(100) := fn_normalize_slug(pi_slug);
        v_org_id NUMBER;
    BEGIN
        IF v_slug IS NULL THEN
            RETURN NULL;
        END IF;
        IF pkg_aox_util.fn_is_reserved_org_slug(v_slug) = 1 THEN
            RETURN NULL;
        END IF;

        SELECT org_id_organization
          INTO v_org_id
          FROM org_public_directory
         WHERE profile_slug = v_slug
           AND is_listed    = 1;

        RETURN v_org_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_org_id_by_slug;

    FUNCTION fn_slug_taken(
        pi_slug           IN VARCHAR2,
        pi_exclude_org_id IN NUMBER DEFAULT NULL
    ) RETURN NUMBER IS
        v_slug  VARCHAR2(100) := fn_normalize_slug(pi_slug);
        v_taken NUMBER;
    BEGIN
        IF v_slug IS NULL THEN
            RETURN 0;
        END IF;

        SELECT COUNT(*)
          INTO v_taken
          FROM org_public_directory d
         WHERE d.profile_slug = v_slug
           AND (pi_exclude_org_id IS NULL
                OR d.org_id_organization <> pi_exclude_org_id);

        IF v_taken > 0 THEN
            RETURN 1;
        END IF;
        RETURN 0;
    END fn_slug_taken;

    PROCEDURE pr_resolve_token(
        pi_token            IN  VARCHAR2,
        po_org_id           OUT NUMBER,
        po_appointment_id   OUT NUMBER
    ) IS
        v_hash RAW(32) := fn_token_hash(pi_token);
    BEGIN
        po_org_id         := NULL;
        po_appointment_id := NULL;
        IF v_hash IS NULL THEN
            RETURN;
        END IF;

        SELECT org_id_organization,
               app_id_appointment
          INTO po_org_id,
               po_appointment_id
          FROM org_public_token
         WHERE token_hash = v_hash
           AND token_kind = c_kind_appointment_manage;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            po_org_id         := NULL;
            po_appointment_id := NULL;
    END pr_resolve_token;

    PROCEDURE pr_delete_org(
        pi_org_id IN NUMBER
    ) IS
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 THEN
            RETURN;
        END IF;
        DELETE FROM org_public_directory
         WHERE org_id_organization = pi_org_id;
    END pr_delete_org;

    PROCEDURE pr_apply_publication_flags(
        pi_org_id            IN NUMBER,
        pi_enforcement_level IN VARCHAR2
    ) IS
        v_level     VARCHAR2(30) := UPPER(TRIM(NVL(pi_enforcement_level, 'NONE')));
        v_unpub     NUMBER(1) := fn_is_unpublished_level(v_level);
        v_blocks    NUMBER(1) := fn_blocks_booking_level(v_level);
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 THEN
            RETURN;
        END IF;

        UPDATE org_public_directory
           SET is_unpublished        = v_unpub,
               blocks_public_booking = v_blocks,
               updated_at            = CURRENT_TIMESTAMP
         WHERE org_id_organization = pi_org_id;
    END pr_apply_publication_flags;

    PROCEDURE pr_sync_workspace(
        pi_org_id             IN NUMBER,
        pi_slug               IN VARCHAR2,
        pi_enforcement_level  IN VARCHAR2 DEFAULT NULL
    ) IS
        v_slug   VARCHAR2(100) := fn_normalize_slug(pi_slug);
        v_level  VARCHAR2(30);
        v_unpub  NUMBER(1);
        v_blocks NUMBER(1);
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 THEN
            RETURN;
        END IF;

        IF v_slug IS NULL OR pkg_aox_util.fn_is_reserved_org_slug(v_slug) = 1 THEN
            pr_delete_org(pi_org_id);
            RETURN;
        END IF;

        v_level  := fn_enforcement_level(pi_org_id, pi_enforcement_level);
        v_unpub  := fn_is_unpublished_level(v_level);
        v_blocks := fn_blocks_booking_level(v_level);

        MERGE INTO org_public_directory d
        USING (
            SELECT pi_org_id AS org_id_organization
              FROM dual
        ) s
           ON (d.org_id_organization = s.org_id_organization)
         WHEN MATCHED THEN
            UPDATE SET
                d.profile_slug          = v_slug,
                d.is_listed             = 1,
                d.is_unpublished        = v_unpub,
                d.blocks_public_booking = v_blocks,
                d.updated_at            = CURRENT_TIMESTAMP
         WHEN NOT MATCHED THEN
            INSERT (
                org_id_organization,
                profile_slug,
                is_listed,
                is_unpublished,
                blocks_public_booking,
                updated_at
            ) VALUES (
                pi_org_id,
                v_slug,
                1,
                v_unpub,
                v_blocks,
                CURRENT_TIMESTAMP
            );
    END pr_sync_workspace;

    PROCEDURE pr_sync_appointment_token(
        pi_appointment_id IN NUMBER,
        pi_org_id         IN NUMBER,
        pi_token          IN VARCHAR2
    ) IS
        v_hash RAW(32) := fn_token_hash(pi_token);
    BEGIN
        IF NVL(pi_appointment_id, 0) <= 0 OR NVL(pi_org_id, 0) <= 0 THEN
            RETURN;
        END IF;

        IF v_hash IS NULL THEN
            pr_delete_appointment_token(pi_appointment_id);
            RETURN;
        END IF;

        -- Si el hash cambio, liberar la fila vieja de esta cita.
        DELETE FROM org_public_token
         WHERE app_id_appointment = pi_appointment_id
           AND token_kind         = c_kind_appointment_manage
           AND token_hash        <> v_hash;

        MERGE INTO org_public_token t
        USING (
            SELECT v_hash AS token_hash
              FROM dual
        ) s
           ON (t.token_hash = s.token_hash)
         WHEN MATCHED THEN
            UPDATE SET
                t.org_id_organization = pi_org_id,
                t.app_id_appointment  = pi_appointment_id,
                t.token_kind          = c_kind_appointment_manage,
                t.updated_at          = CURRENT_TIMESTAMP
         WHEN NOT MATCHED THEN
            INSERT (
                token_hash,
                org_id_organization,
                app_id_appointment,
                token_kind,
                created_at,
                updated_at
            ) VALUES (
                v_hash,
                pi_org_id,
                pi_appointment_id,
                c_kind_appointment_manage,
                CURRENT_TIMESTAMP,
                CURRENT_TIMESTAMP
            );
    END pr_sync_appointment_token;

    PROCEDURE pr_delete_appointment_token(
        pi_appointment_id IN NUMBER
    ) IS
    BEGIN
        IF NVL(pi_appointment_id, 0) <= 0 THEN
            RETURN;
        END IF;
        DELETE FROM org_public_token
         WHERE app_id_appointment = pi_appointment_id
           AND token_kind         = c_kind_appointment_manage;
    END pr_delete_appointment_token;

    PROCEDURE pr_refresh_all IS
        v_slug workspace_setting.profile_slug%TYPE;
    BEGIN
        -- Con VPD en WORKSPACE_SETTING / APPOINTMENT no se puede MERGE
        -- cross-org. set_org por organizacion y reusar pr_sync_*.
        FOR rec IN (
            SELECT id_organization
              FROM organization
             ORDER BY id_organization
        ) LOOP
            pkg_aox_session.set_org(rec.id_organization);
            BEGIN
                SELECT profile_slug
                  INTO v_slug
                  FROM workspace_setting
                 WHERE org_id_organization = rec.id_organization;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_slug := NULL;
            END;
            pr_sync_workspace(rec.id_organization, v_slug);

            FOR tok IN (
                SELECT id_appointment,
                       org_id_organization,
                       public_manage_token
                  FROM appointment
                 WHERE public_manage_token IS NOT NULL
                   AND TRIM(public_manage_token) IS NOT NULL
            ) LOOP
                pr_sync_appointment_token(
                    tok.id_appointment,
                    tok.org_id_organization,
                    tok.public_manage_token
                );
            END LOOP;
        END LOOP;
        pkg_aox_session.clear;

        DELETE FROM org_public_directory
         WHERE is_listed = 0
            OR profile_slug IS NULL
            OR pkg_aox_util.fn_is_reserved_org_slug(profile_slug) = 1;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                pkg_aox_session.clear;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
            RAISE;
    END pr_refresh_all;

END pkg_aox_public_directory;
/
