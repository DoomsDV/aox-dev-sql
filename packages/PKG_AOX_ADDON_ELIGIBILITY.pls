PROMPT CREATE OR REPLACE PACKAGE pkg_aox_addon_eligibility
CREATE OR REPLACE PACKAGE pkg_aox_addon_eligibility IS

    FUNCTION fn_addon_eligible(
        pi_org_id   IN NUMBER,
        pi_addon_id IN NUMBER
    ) RETURN NUMBER;

    FUNCTION fn_list_eligible_feature_codes(
        pi_org_id IN NUMBER
    ) RETURN SYS.ODCIVARCHAR2LIST;

    PROCEDURE pr_set_org_specialties(
        pi_org_id        IN NUMBER,
        pi_specialty_ids IN SYS.ODCINUMBERLIST,
        pi_primary_id    IN NUMBER
    );

END pkg_aox_addon_eligibility;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_addon_eligibility
CREATE OR REPLACE PACKAGE BODY pkg_aox_addon_eligibility IS

    FUNCTION fn_addon_eligible(
        pi_org_id   IN NUMBER,
        pi_addon_id IN NUMBER
    ) RETURN NUMBER IS
        v_active          NUMBER := 0;
        v_bridge_count    NUMBER := 0;
        v_requires_bridge NUMBER := 0;
        v_match           NUMBER := 0;
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 OR NVL(pi_addon_id, 0) <= 0 THEN
            RETURN 0;
        END IF;

        SELECT COUNT(*)
          INTO v_active
          FROM org_addon
         WHERE org_id_organization = pi_org_id
           AND rad_id_addon = pi_addon_id
           AND status = 'ACTIVE';
        IF v_active > 0 THEN
            RETURN 1;
        END IF;

        BEGIN
            SELECT NVL(ra.requires_specialty_bridge, 0)
              INTO v_requires_bridge
              FROM ref_addon ra
             WHERE ra.id_addon = pi_addon_id
               AND ra.is_active = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN 0;
        END;

        SELECT COUNT(*)
          INTO v_bridge_count
          FROM ref_addon_specialty
         WHERE rad_id_addon = pi_addon_id;

        IF v_requires_bridge = 0 AND v_bridge_count = 0 THEN
            RETURN 1;
        END IF;

        IF v_requires_bridge = 1 AND v_bridge_count = 0 THEN
            RETURN 0;
        END IF;

        SELECT COUNT(*)
          INTO v_match
          FROM ref_addon_specialty ras
         WHERE ras.rad_id_addon = pi_addon_id
           AND EXISTS (
                 SELECT 1
                   FROM organization_specialty os
                  WHERE os.org_id_organization = pi_org_id
                    AND os.osp_id_org_specialty = ras.osp_id_org_specialty
               );

        IF v_match = 0 THEN
            SELECT COUNT(*)
              INTO v_match
              FROM ref_addon_specialty ras
             WHERE ras.rad_id_addon = pi_addon_id
               AND EXISTS (
                     SELECT 1
                       FROM organization o
                      WHERE o.id_organization = pi_org_id
                        AND o.org_spe_id_specialty = ras.osp_id_org_specialty
                   );
        END IF;

        RETURN CASE WHEN v_match > 0 THEN 1 ELSE 0 END;
    END fn_addon_eligible;

    FUNCTION fn_list_eligible_feature_codes(
        pi_org_id IN NUMBER
    ) RETURN SYS.ODCIVARCHAR2LIST IS
        v_codes SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
        v_seen  VARCHAR2(4000) := '|';
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 THEN
            RETURN v_codes;
        END IF;

        FOR rec IN (
            SELECT DISTINCT ra.feature_code
              FROM ref_addon ra
             WHERE ra.is_active = 1
               AND pkg_aox_addon_eligibility.fn_addon_eligible(pi_org_id, ra.id_addon) = 1
             ORDER BY ra.feature_code
        ) LOOP
            IF INSTR(v_seen, '|' || rec.feature_code || '|') = 0 THEN
                v_codes.EXTEND;
                v_codes(v_codes.COUNT) := rec.feature_code;
                v_seen := v_seen || rec.feature_code || '|';
            END IF;
        END LOOP;

        RETURN v_codes;
    END fn_list_eligible_feature_codes;

    PROCEDURE pr_set_org_specialties(
        pi_org_id        IN NUMBER,
        pi_specialty_ids IN SYS.ODCINUMBERLIST,
        pi_primary_id    IN NUMBER
    ) IS
        v_count      PLS_INTEGER;
        v_spec_id    NUMBER;
        v_active_cnt NUMBER;
        v_primary_ok NUMBER := 0;
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Organización inválida.');
        END IF;

        IF pi_specialty_ids IS NULL OR pi_specialty_ids.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20005, 'Debe seleccionar al menos un rubro.');
        END IF;

        IF NVL(pi_primary_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(-20005, 'Debe indicar el rubro principal.');
        END IF;

        FOR i IN 1 .. pi_specialty_ids.COUNT LOOP
            v_spec_id := pi_specialty_ids(i);
            IF NVL(v_spec_id, 0) <= 0 THEN
                RAISE_APPLICATION_ERROR(-20005, 'Rubro inválido en la lista.');
            END IF;

            SELECT COUNT(*)
              INTO v_active_cnt
              FROM org_specialty
             WHERE id_org_specialty = v_spec_id
               AND is_active = 1;
            IF v_active_cnt = 0 THEN
                RAISE_APPLICATION_ERROR(-20005, 'La categoría del negocio no es válida.');
            END IF;

            IF v_spec_id = pi_primary_id THEN
                v_primary_ok := 1;
            END IF;
        END LOOP;

        IF v_primary_ok = 0 THEN
            RAISE_APPLICATION_ERROR(-20005, 'El rubro principal debe estar entre los rubros seleccionados.');
        END IF;

        DELETE FROM organization_specialty
         WHERE org_id_organization = pi_org_id;

        FOR i IN 1 .. pi_specialty_ids.COUNT LOOP
            v_spec_id := pi_specialty_ids(i);
            INSERT INTO organization_specialty (org_id_organization, osp_id_org_specialty)
            SELECT pi_org_id, v_spec_id
              FROM dual
             WHERE NOT EXISTS (
                     SELECT 1
                       FROM organization_specialty os
                      WHERE os.org_id_organization = pi_org_id
                        AND os.osp_id_org_specialty = v_spec_id
                   );
        END LOOP;

        UPDATE organization
           SET org_spe_id_specialty = pi_primary_id
         WHERE id_organization = pi_org_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20009, 'Organización no encontrada.');
        END IF;
    END pr_set_org_specialties;

END pkg_aox_addon_eligibility;
/
