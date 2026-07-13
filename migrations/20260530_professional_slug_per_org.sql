-- Migración: slug de profesional único por organización (no global)
-- URL pública: /{org_slug}/p/{profile_slug}
-- Ejecutar después de multi-org; recompilar PKG_AOX_PUBLIC_BOOKING_API y PKG_AOX_PROFESSIONAL_API, PKG_AOX_USER_API

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 1) Eliminar unicidad global de professional.profile_slug ===

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE professional DROP CONSTRAINT uq_pro_slug';
    DBMS_OUTPUT.PUT_LINE('Constraint uq_pro_slug eliminado.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE IN (-2443, -942) THEN
            DBMS_OUTPUT.PUT_LINE('uq_pro_slug no existía (ok).');
        ELSE
            RAISE;
        END IF;
END;
/

PROMPT === 2) Unicidad compuesta (org_id_organization, profile_slug) ===

BEGIN
    EXECUTE IMMEDIATE '
        ALTER TABLE professional
        ADD CONSTRAINT uq_pro_org_slug UNIQUE (org_id_organization, profile_slug)';
    DBMS_OUTPUT.PUT_LINE('Constraint uq_pro_org_slug creado.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -2261 THEN
            DBMS_OUTPUT.PUT_LINE('uq_pro_org_slug ya existe (ok).');
        ELSE
            RAISE;
        END IF;
END;
/

PROMPT === 3) Post-validación: sin slugs duplicados dentro de la misma org ===

DECLARE
    v_dup NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_dup
      FROM (
        SELECT org_id_organization, lower(trim(profile_slug)) AS s, COUNT(*) AS c
          FROM professional
         WHERE profile_slug IS NOT NULL
           AND trim(profile_slug) IS NOT NULL
         GROUP BY org_id_organization, lower(trim(profile_slug))
        HAVING COUNT(*) > 1
      );

    IF v_dup > 0 THEN
        RAISE_APPLICATION_ERROR(-20010,
            'Hay slugs de profesional duplicados dentro de una misma organización. Resolver antes de continuar.');
    END IF;

    DBMS_OUTPUT.PUT_LINE('Post-validación OK: slugs únicos por organización.');
END;
/

PROMPT === Migración 20260530 completada ===
