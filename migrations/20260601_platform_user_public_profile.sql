-- =============================================================================
-- Perfil público global por platform_user (slug + foto para link in bio)
-- URL futura: /u/{public_slug}
--
-- ORDEN:
--   1) Recompilar packages/PKG_AOX_UTIL.pls
--   2) Ejecutar este script
--   3) Recompilar packages/PKG_AOX_BUCKET.pls, PKG_AOX_USER_API.pls, PKG_AOX_AUTH_API.pls
--
-- ORDS: GET /profile/me/public-slug/suggest -> PKG_AOX_USER_API.PR_SUGGEST_PUBLIC_SLUG
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 1) Columnas en platform_user ===

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE platform_user ADD public_slug VARCHAR2(100)';
    DBMS_OUTPUT.PUT_LINE('Columna public_slug agregada.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN
            DBMS_OUTPUT.PUT_LINE('public_slug ya existe, se omite ADD.');
        ELSE
            RAISE;
        END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE platform_user ADD profile_image_url VARCHAR2(4000)';
    DBMS_OUTPUT.PUT_LINE('Columna profile_image_url agregada.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN
            DBMS_OUTPUT.PUT_LINE('profile_image_url ya existe, se omite ADD.');
        ELSE
            RAISE;
        END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE platform_user ADD profile_image_mime VARCHAR2(100)';
    DBMS_OUTPUT.PUT_LINE('Columna profile_image_mime agregada.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN
            DBMS_OUTPUT.PUT_LINE('profile_image_mime ya existe, se omite ADD.');
        ELSE
            RAISE;
        END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE platform_user ADD profile_image_file_name VARCHAR2(255)';
    DBMS_OUTPUT.PUT_LINE('Columna profile_image_file_name agregada.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN
            DBMS_OUTPUT.PUT_LINE('profile_image_file_name ya existe, se omite ADD.');
        ELSE
            RAISE;
        END IF;
END;
/

PROMPT === 2) Unicidad global de public_slug ===

BEGIN
    EXECUTE IMMEDIATE '
        ALTER TABLE platform_user
        ADD CONSTRAINT uq_pu_public_slug UNIQUE (public_slug)';
    DBMS_OUTPUT.PUT_LINE('Constraint uq_pu_public_slug creado.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -2261 THEN
            DBMS_OUTPUT.PUT_LINE('uq_pu_public_slug ya existe (ok).');
        ELSE
            RAISE;
        END IF;
END;
/

PROMPT === 3) Backfill de public_slug (nombre + apellido normalizado) ===

DECLARE
    v_base  VARCHAR2(200);
    v_final VARCHAR2(200);
    v_count NUMBER;
BEGIN
    FOR rec IN (
        SELECT id_platform_user, first_name, last_name
          FROM platform_user
         WHERE public_slug IS NULL
         ORDER BY id_platform_user
    ) LOOP
        v_base := pkg_aox_util.fn_build_platform_user_public_slug(
            rec.first_name,
            rec.last_name,
            rec.id_platform_user
        );

        v_final := v_base;

        SELECT COUNT(*)
          INTO v_count
          FROM platform_user
         WHERE lower(trim(public_slug)) = lower(trim(v_final))
           AND id_platform_user <> rec.id_platform_user;

        IF v_count > 0 THEN
            v_final := v_base || '-' || rec.id_platform_user;
        END IF;

        UPDATE platform_user
           SET public_slug = v_final
         WHERE id_platform_user = rec.id_platform_user;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('Backfill public_slug completado.');
END;
/

PROMPT === 4) Post-validacion: sin slugs duplicados ===

DECLARE
    v_dup NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_dup
      FROM (
        SELECT lower(trim(public_slug)) AS slug_key, COUNT(*) AS c
          FROM platform_user
         WHERE public_slug IS NOT NULL
           AND trim(public_slug) IS NOT NULL
         GROUP BY lower(trim(public_slug))
        HAVING COUNT(*) > 1
      );

    IF v_dup > 0 THEN
        RAISE_APPLICATION_ERROR(
            -20011,
            'Hay public_slug duplicados en platform_user. Resolver antes de continuar.'
        );
    END IF;

    DBMS_OUTPUT.PUT_LINE('Post-validacion OK: public_slug unicos.');
END;
/

COMMENT ON COLUMN platform_user.public_slug IS 'Slug global unico para /u/{slug} (link in bio del usuario).';
COMMENT ON COLUMN platform_user.profile_image_url IS 'Foto publica global del usuario (OCI).';
COMMENT ON COLUMN platform_user.profile_image_mime IS 'MIME type de la foto publica global.';
COMMENT ON COLUMN platform_user.profile_image_file_name IS 'Nombre de archivo en bucket para la foto global.';

PROMPT === Migracion 20260601_platform_user_public_profile completada ===
