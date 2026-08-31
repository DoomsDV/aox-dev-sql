-- Limpieza / restauracion de la fixture QA Billing E2E.
-- Solo borra la org marcada por app_parameter QA_BILLING_E2E_ORG_ID o por nombre.
-- Nunca toca org_id=1 (Consultorio General).

SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    c_org_name CONSTANT VARCHAR2(100) := 'QA Billing E2E';
    v_org_id   NUMBER;
    v_name     organization.name%TYPE;
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
         WHERE name = c_org_name;
    END IF;

    IF v_org_id IS NULL THEN
        DBMS_OUTPUT.PUT_LINE('No hay fixture QA Billing E2E; nada que limpiar.');
        RETURN;
    END IF;

    IF v_org_id = 1 THEN
        RAISE_APPLICATION_ERROR(-20002, 'Abortado: no se puede limpiar org_id=1.');
    END IF;

    SELECT name INTO v_name FROM organization WHERE id_organization = v_org_id;
    IF v_name <> c_org_name THEN
        RAISE_APPLICATION_ERROR(-20003,
            'Abortado: org_id=' || v_org_id || ' se llama "' || v_name || '", no es la fixture.');
    END IF;

    -- Outbox FE
    DELETE FROM subscription_einvoice_outbox WHERE org_id_organization = v_org_id;

    -- Notificaciones de la campanita de miembros de la fixture
    DELETE FROM user_notification
     WHERE org_id_organization = v_org_id
        OR org_member_id IN (
               SELECT id_org_member FROM org_member WHERE org_id_organization = v_org_id
           );

    DELETE FROM org_subscription_invoice WHERE org_id_organization = v_org_id;
    DELETE FROM org_payment_card WHERE org_id_organization = v_org_id;
    DELETE FROM org_billing_profile WHERE org_id_organization = v_org_id;
    DELETE FROM org_storage_addon WHERE org_id_organization = v_org_id;
    DELETE FROM org_subscription WHERE org_id_organization = v_org_id;
    DELETE FROM org_member WHERE org_id_organization = v_org_id;
    DELETE FROM organization WHERE id_organization = v_org_id;

    DELETE FROM app_parameter WHERE param_key = 'QA_BILLING_E2E_ORG_ID';

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Fixture org_id=' || v_org_id || ' eliminada. Consultorio General intacto.');
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END;
/
