-- Activación operativa explícita del preview por organización.
-- Ejecutar como AOXDEV con un bind definido:
--   VARIABLE org_id NUMBER
--   EXEC :org_id := 123
--   @scripts/grant_ai_assistant_preview.sql
-- No ejecutar sin revisar el organization_id objetivo.

DECLARE
    v_org_id   NUMBER := :org_id;
    v_addon_id NUMBER;
BEGIN
    IF NVL(v_org_id, 0) <= 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'Debe definirse un :org_id positivo.');
    END IF;

    -- ORG_ADDON es tenant-scoped con VPD habilitado. El contexto se fija solo
    -- para esta organización y se limpia tanto en éxito como en error.
    pkg_aox_session.set_org(v_org_id);

    SELECT id_addon
      INTO v_addon_id
      FROM ref_addon
     WHERE feature_code = 'AI_ASSISTANT'
       AND code = 'AI_ASSISTANT'
       AND is_active = 1;

    MERGE INTO org_addon t
    USING (
        SELECT v_org_id AS org_id,
               v_addon_id AS addon_id,
               0 AS price_amount,
               'PYG' AS currency
          FROM dual
    ) s
    ON (t.org_id_organization = s.org_id AND t.rad_id_addon = s.addon_id)
    WHEN MATCHED THEN UPDATE SET
        t.status = 'ACTIVE',
        t.grant_type = 'PREVIEW',
        t.price_snapshot_amount = s.price_amount,
        t.currency = s.currency,
        t.canceled_at = NULL,
        t.billing_started_at = NULL,
        t.updated_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED THEN INSERT (
        org_id_organization, rad_id_addon, status, grant_type,
        price_snapshot_amount, currency, started_at, created_at, updated_at
    ) VALUES (
        s.org_id, s.addon_id, 'ACTIVE', 'PREVIEW', s.price_amount,
        s.currency, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    );

    COMMIT;
    pkg_aox_session.clear;
    DBMS_OUTPUT.PUT_LINE('AI_ASSISTANT preview ACTIVE para org_id=' || v_org_id);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        ROLLBACK;
        pkg_aox_session.clear;
        RAISE_APPLICATION_ERROR(-20002, 'No existe el addon AI_ASSISTANT activo. Ejecutar primero la foundation.');
    WHEN OTHERS THEN
        ROLLBACK;
        pkg_aox_session.clear;
        RAISE;
END;
/
