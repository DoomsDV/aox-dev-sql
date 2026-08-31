-- Fixture aislada "QA Billing E2E" para pruebas de suscripcion en aoxdev.
-- Owner: platform_user id=10 (mike.sdk83@gmail.com), rol ADMIN.
-- Premium NO fundador, billing profile de prueba. NO toca org 1 ni BILLING_ENABLED.
--
-- Uso:
--   @@scripts/qa_billing_e2e_seed.sql
--   -- luego ajustar fechas de trial/period segun el escenario E2E
-- Limpieza: @@scripts/qa_billing_e2e_cleanup.sql

SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    c_org_name     CONSTANT VARCHAR2(100) := 'QA Billing E2E';
    c_mike_id      CONSTANT NUMBER := 10;
    c_admin_role   CONSTANT NUMBER := 1;
    c_plan_premium CONSTANT NUMBER := 2; -- ref_plan PREMIUM

    v_org_id       NUMBER;
    v_param_id     NUMBER;
    v_member_id    NUMBER;
    v_email_ok     NUMBER;
    v_sub_count    NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_email_ok
      FROM platform_user
     WHERE id_platform_user = c_mike_id
       AND LOWER(email) = 'mike.sdk83@gmail.com';

    IF v_email_ok = 0 THEN
        RAISE_APPLICATION_ERROR(-20001,
            'platform_user 10 no es mike.sdk83@gmail.com; abortando fixture.');
    END IF;

    -- Preferir ID inmutable ya guardado; el nombre solo como fallback / chequeo.
    BEGIN
        v_param_id := TO_NUMBER(fn_get_parameter('QA_BILLING_E2E_ORG_ID'));
    EXCEPTION
        WHEN OTHERS THEN
            v_param_id := NULL;
    END;

    IF v_param_id IS NOT NULL THEN
        BEGIN
            SELECT id_organization INTO v_org_id
              FROM organization
             WHERE id_organization = v_param_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_org_id := NULL;
        END;
    END IF;

    IF v_org_id IS NULL THEN
        SELECT MAX(id_organization) INTO v_org_id
          FROM organization
         WHERE name = c_org_name;
    END IF;

    IF v_org_id IS NULL THEN
        INSERT INTO organization (name, company_email, org_spe_id_specialty, country_code)
        VALUES (c_org_name, 'mike.sdk83@gmail.com', 9, 'PY')
        RETURNING id_organization INTO v_org_id;
        DBMS_OUTPUT.PUT_LINE('Creada org id=' || v_org_id || ' (' || c_org_name || ')');
    ELSE
        UPDATE organization
           SET name = c_org_name
         WHERE id_organization = v_org_id
           AND name <> c_org_name;
        DBMS_OUTPUT.PUT_LINE('Org fixture id=' || v_org_id || ' (inmutable)');
    END IF;

    -- Membresia ADMIN de Mike
    SELECT MAX(id_org_member) INTO v_member_id
      FROM org_member
     WHERE org_id_organization = v_org_id
       AND platform_user_id = c_mike_id;

    IF v_member_id IS NULL THEN
        INSERT INTO org_member (platform_user_id, org_id_organization, rol_id_role, is_active)
        VALUES (c_mike_id, v_org_id, c_admin_role, 1)
        RETURNING id_org_member INTO v_member_id;
        DBMS_OUTPUT.PUT_LINE('Creada membresia id=' || v_member_id);
    ELSE
        UPDATE org_member
           SET rol_id_role = c_admin_role,
               is_active   = 1
         WHERE id_org_member = v_member_id;
        DBMS_OUTPUT.PUT_LINE('Membresia existente id=' || v_member_id || ' (ADMIN activo)');
    END IF;

    -- Suscripcion Premium NO fundadora (facturable)
    SELECT COUNT(*) INTO v_sub_count
      FROM org_subscription
     WHERE org_id_organization = v_org_id;

    IF v_sub_count = 0 THEN
        INSERT INTO org_subscription (
            org_id_organization,
            pln_id_plan,
            status,
            is_founder,
            billing_exempt,
            storage_used_bytes,
            storage_limit_bytes,
            trial_started_at,
            trial_ends_at,
            current_period_start,
            current_period_end,
            grace_ends_at,
            auto_renew,
            charge_retry_count,
            account_balance
        ) VALUES (
            v_org_id,
            c_plan_premium,
            'ACTIVE',
            0,
            0,
            0,
            (SELECT storage_limit_bytes FROM ref_plan WHERE id_plan = c_plan_premium),
            NULL,
            NULL,
            systimestamp,
            ADD_MONTHS(systimestamp, 1),
            NULL,
            1,
            0,
            0
        );
        DBMS_OUTPUT.PUT_LINE('Suscripcion Premium ACTIVE (no founder) creada');
    ELSE
        UPDATE org_subscription
           SET pln_id_plan          = c_plan_premium,
               status               = 'ACTIVE',
               is_founder           = 0,
               billing_exempt       = 0,
               auto_renew           = 1,
               charge_retry_count   = 0,
               grace_ends_at        = NULL,
               canceled_at          = NULL,
               pending_pln_id_plan  = NULL,
               pending_plan_change_at = NULL,
               current_period_start = NVL(current_period_start, systimestamp),
               current_period_end   = NVL(current_period_end, ADD_MONTHS(systimestamp, 1)),
               updated_at           = systimestamp
         WHERE org_id_organization = v_org_id;
        DBMS_OUTPUT.PUT_LINE('Suscripcion fixture reseteada a Premium ACTIVE (no founder)');
    END IF;

    -- Perfil fiscal de prueba (RUC demo; DV se calcula en emision)
    MERGE INTO org_billing_profile t
    USING (
        SELECT v_org_id AS org_id FROM dual
    ) s
    ON (t.org_id_organization = s.org_id)
    WHEN MATCHED THEN
        UPDATE SET billing_name       = 'QA Billing E2E SRL',
                   billing_doc_type   = 'RUC',
                   billing_doc_number = '80069563',
                   billing_email      = 'mike.sdk83@gmail.com',
                   updated_at         = systimestamp,
                   updated_by_user    = c_mike_id
    WHEN NOT MATCHED THEN
        INSERT (org_id_organization, billing_name, billing_doc_type, billing_doc_number, billing_email, updated_by_user)
        VALUES (v_org_id, 'QA Billing E2E SRL', 'RUC', '80069563', 'mike.sdk83@gmail.com', c_mike_id);

    MERGE INTO app_parameter t
    USING (
        SELECT 'QA_BILLING_E2E_ORG_ID' AS param_key,
               TO_CHAR(v_org_id) AS param_value,
               'id_organization de la fixture QA Billing E2E (solo aoxdev).' AS description
          FROM dual
    ) s
    ON (t.param_key = s.param_key)
    WHEN MATCHED THEN
        UPDATE SET t.param_value = s.param_value, t.description = s.description
    WHEN NOT MATCHED THEN
        INSERT (param_key, param_value, description)
        VALUES (s.param_key, s.param_value, s.description);

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('=== Fixture lista. org_id=' || v_org_id || ' ===');
    DBMS_OUTPUT.PUT_LINE('Escenarios: UPDATE org_subscription SET trial_ends_at / current_period_end / grace_ends_at');
    DBMS_OUTPUT.PUT_LINE('Ciclo: @@scripts/qa_billing_e2e_run_cycle.sql');
END;
/
