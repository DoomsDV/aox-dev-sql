-- Ejecuta el ciclo de billing acotado a la org fixture QA Billing E2E.
-- Requiere PKG_AOX_SUBSCRIPTION_BILLING_API.pr_run_billing_cycle_for_org desplegado.
-- No crea scheduler permanente.

SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    v_org_id NUMBER;
BEGIN
    BEGIN
        v_org_id := TO_NUMBER(fn_get_parameter('QA_BILLING_E2E_ORG_ID'));
    EXCEPTION
        WHEN OTHERS THEN
            v_org_id := NULL;
    END;

    IF v_org_id IS NULL THEN
        SELECT MAX(id_organization) INTO v_org_id
          FROM organization
         WHERE name = 'QA Billing E2E';
    END IF;

    IF v_org_id IS NULL THEN
        RAISE_APPLICATION_ERROR(-20004,
            'Fixture no encontrada. Ejecuta primero @@scripts/qa_billing_e2e_seed.sql');
    END IF;

    DBMS_OUTPUT.PUT_LINE('Ejecutando pr_run_billing_cycle_for_org(' || v_org_id || ')...');
    pkg_aox_subscription_billing_api.pr_run_billing_cycle_for_org(v_org_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('OK. Revisar aox_api_log api_name=SUBSCRIPTION_BILLING_CYCLE.');
END;
/
