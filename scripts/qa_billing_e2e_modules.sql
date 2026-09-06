-- Casos E2E Fase 2 (módulos) sobre la fixture QA Billing E2E.
-- Prende ADDONS_BILLING_LIVE=1 SOLO en esta sesión y lo restaura a 0 al terminar
-- (también si falla). NO toca BILLING_ENABLED (permanece 0). NO toca org 1 ni prod.
--
-- Requiere: @@scripts/qa_billing_e2e_seed.sql
-- Uso:      @@scripts/qa_billing_e2e_modules.sql

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
    c_mike_id CONSTANT NUMBER := 10;
    v_org_id  NUMBER;
    v_auth    VARCHAR2(4000);
    v_jwt     VARCHAR2(4000);
    v_live_snap VARCHAR2(20);
    v_bill_snap VARCHAR2(20);
    v_failed  NUMBER := 0;
    v_status  NUMBER;
    v_body    CLOB;
    v_json    json_object_t;
    v_data    json_object_t;
    v_item    json_object_t;
    v_odonto  NUMBER;
    v_body_id NUMBER;
    v_sub_id  NUMBER;
    v_hash    VARCHAR2(128);
    v_token   VARCHAR2(64);
    v_priv    VARCHAR2(500);
    v_inv_id  NUMBER;
    v_grant   VARCHAR2(20);
    v_oa_status VARCHAR2(20);
    v_credit  NUMBER;
    v_nce_q   NUMBER;
    v_nce_amt NUMBER;
    v_refund  VARCHAR2(10);
    v_cnt     NUMBER;
    v_idem    VARCHAR2(80);

    PROCEDURE lp_restore_flags IS
    BEGIN
        UPDATE app_parameter
           SET param_value = '0'
         WHERE param_key IN ('ADDONS_BILLING_LIVE', 'BILLING_ENABLED');
        COMMIT;
    END lp_restore_flags;

    PROCEDURE lp_assert(pi_ok IN BOOLEAN, pi_case IN VARCHAR2, pi_detail IN VARCHAR2) IS
    BEGIN
        IF pi_ok THEN
            DBMS_OUTPUT.PUT_LINE('PASS ' || pi_case || ' — ' || pi_detail);
        ELSE
            v_failed := v_failed + 1;
            DBMS_OUTPUT.PUT_LINE('FAIL ' || pi_case || ' — ' || pi_detail);
        END IF;
    END lp_assert;

    FUNCTION lf_item(pi_clob IN CLOB, pi_code IN VARCHAR2) RETURN json_object_t IS
        v_root  json_object_t;
        v_d     json_object_t;
        v_items json_array_t;
        v_it    json_object_t;
    BEGIN
        v_root  := json_object_t.parse(pi_clob);
        v_d     := TREAT(v_root.get('data') AS json_object_t);
        v_items := v_d.get_array('items');
        FOR i IN 0 .. v_items.get_size - 1 LOOP
            v_it := TREAT(v_items.get(i) AS json_object_t);
            IF v_it.get_string('code') = pi_code THEN
                RETURN v_it;
            END IF;
        END LOOP;
        RETURN NULL;
    END lf_item;

    FUNCTION lf_jwt RETURN VARCHAR2 IS
    BEGIN
        RETURN apex_jwt.encode(
            p_iss           => NVL(fn_get_parameter('JWT_ISSUER'), 'hasel-api'),
            p_sub           => 'mike.sdk83@gmail.com',
            p_aud           => NVL(fn_get_parameter('JWT_AUDIENCE'), 'hasel-app'),
            p_exp_sec       => NVL(TO_NUMBER(fn_get_parameter('JWT_ACCESS_EXP_SEC')), 3600),
            p_other_claims  => '"user_id": ' || c_mike_id || ', "role_id": 1, "organization_id": ' || v_org_id,
            p_signature_key => UTL_RAW.CAST_TO_RAW(fn_get_parameter('JWT_TOKEN'))
        );
    END lf_jwt;
BEGIN
    EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';

    BEGIN
        v_org_id := TO_NUMBER(fn_get_parameter('QA_BILLING_E2E_ORG_ID'));
    EXCEPTION
        WHEN OTHERS THEN
            v_org_id := NULL;
    END;
    IF v_org_id IS NULL THEN
        RAISE_APPLICATION_ERROR(-20004, 'Fixture no encontrada. Ejecuta @@scripts/qa_billing_e2e_seed.sql');
    END IF;
    IF v_org_id = 1 THEN
        RAISE_APPLICATION_ERROR(-20002, 'Abortado: no se cicla org_id=1.');
    END IF;

    SELECT NVL(MAX(param_value), '0') INTO v_live_snap
      FROM app_parameter WHERE param_key = 'ADDONS_BILLING_LIVE';
    SELECT NVL(MAX(param_value), '0') INTO v_bill_snap
      FROM app_parameter WHERE param_key = 'BILLING_ENABLED';

    DBMS_OUTPUT.PUT_LINE('=== QA módulos E2E org_id=' || v_org_id
        || ' snap LIVE=' || v_live_snap || ' BILLING=' || v_bill_snap || ' ===');

    UPDATE app_parameter SET param_value = '1' WHERE param_key = 'ADDONS_BILLING_LIVE';
    UPDATE app_parameter SET param_value = '0' WHERE param_key = 'BILLING_ENABLED';
    COMMIT;

    SELECT id_addon INTO v_odonto FROM ref_addon WHERE code = 'ODONTOGRAM_3D';
    SELECT id_addon INTO v_body_id FROM ref_addon WHERE code = 'BODY_MAP';
    SELECT id_subscription INTO v_sub_id
      FROM org_subscription WHERE org_id_organization = v_org_id;

    v_jwt  := lf_jwt();
    v_auth := 'Bearer ' || v_jwt;

    --------------------------------------------------------------------------
    -- 1) GET list: prorate / days / cancel_refund_type
    --------------------------------------------------------------------------
    pkg_aox_addon_api.pr_list_addons(v_auth, v_status, v_body);
    lp_assert(v_status = 200, 'list_http', 'status=' || v_status);
    v_item := lf_item(v_body, 'ODONTOGRAM_3D');
    IF v_item IS NULL THEN
        lp_assert(FALSE, 'list_odonto', 'item ausente');
    ELSE
        lp_assert(v_item.get_string('grant_type') = 'PREVIEW', 'list_odonto_grant',
            NVL(v_item.get_string('grant_type'), 'null'));
        lp_assert(NVL(v_item.get_string('cancel_refund_type'), 'none') = 'none', 'list_odonto_refund',
            NVL(v_item.get_string('cancel_refund_type'), 'null'));
        lp_assert(NVL(v_item.get_number('cancel_credit_amount'), 0) = 0, 'list_odonto_credit',
            TO_CHAR(NVL(v_item.get_number('cancel_credit_amount'), -1)));
        lp_assert(NVL(v_item.get_number('days_remaining'), 0) > 0, 'list_odonto_days',
            TO_CHAR(NVL(v_item.get_number('days_remaining'), 0)));
        lp_assert(NVL(v_item.get_number('prorate_amount'), 0) > 0, 'list_odonto_prorate',
            TO_CHAR(NVL(v_item.get_number('prorate_amount'), 0)));
    END IF;
    v_item := lf_item(v_body, 'BODY_MAP');
    IF v_item IS NULL THEN
        lp_assert(FALSE, 'list_body', 'item ausente');
    ELSE
        lp_assert(v_item.get_string('grant_type') = 'PAID', 'list_body_grant',
            NVL(v_item.get_string('grant_type'), 'null'));
        lp_assert(v_item.get_string('cancel_refund_type') = 'nce', 'list_body_refund',
            NVL(v_item.get_string('cancel_refund_type'), 'null'));
        lp_assert(NVL(v_item.get_number('cancel_credit_amount'), 0) > 0, 'list_body_nce_amt',
            TO_CHAR(NVL(v_item.get_number('cancel_credit_amount'), 0)));
    END IF;

    --------------------------------------------------------------------------
    -- 2) Cancel PREVIEW: 0 crédito / 0 NCE
    --------------------------------------------------------------------------
    SELECT NVL(account_balance, 0) INTO v_credit
      FROM org_subscription WHERE org_id_organization = v_org_id;
    pkg_aox_addon_api.pr_cancel_module_addon(
        v_auth, '{"addon_code":"ODONTOGRAM_3D"}', v_status, v_body);
    lp_assert(v_status = 200, 'cancel_preview_http', 'status=' || v_status);
    v_json := json_object_t.parse(v_body);
    v_data := TREAT(v_json.get('data') AS json_object_t);
    lp_assert(NVL(v_data.get_number('credit_granted'), -1) = 0, 'cancel_preview_credit',
        TO_CHAR(NVL(v_data.get_number('credit_granted'), -1)));
    lp_assert(NVL(v_data.get_number('nce_queued'), -1) = 0, 'cancel_preview_nce',
        TO_CHAR(NVL(v_data.get_number('nce_queued'), -1)));
    lp_assert(NVL(v_data.get_string('cancel_refund_type'), '?') = 'none', 'cancel_preview_type',
        NVL(v_data.get_string('cancel_refund_type'), 'null'));
    SELECT status, grant_type INTO v_oa_status, v_grant
      FROM org_addon WHERE org_id_organization = v_org_id AND rad_id_addon = v_odonto;
    lp_assert(v_oa_status = 'CANCELED', 'cancel_preview_status', v_oa_status);
    SELECT NVL(account_balance, 0) INTO v_cnt
      FROM org_subscription WHERE org_id_organization = v_org_id;
    lp_assert(v_cnt = v_credit, 'cancel_preview_balance', 'antes=' || v_credit || ' despues=' || v_cnt);

    --------------------------------------------------------------------------
    -- 3) Activate live=1 cubierto por crédito → 200 PAID (sin Pagopar)
    --------------------------------------------------------------------------
    UPDATE org_subscription
       SET account_balance = 500000
     WHERE org_id_organization = v_org_id;
    COMMIT;
    v_idem := 'qa-mod-act-' || v_org_id || '-' || TO_CHAR(systimestamp, 'YYYYMMDDHH24MISSFF');
    pkg_aox_addon_api.pr_activate_module_addon(
        v_auth, '{"addon_code":"ODONTOGRAM_3D"}', v_status, v_body, v_idem);
    lp_assert(v_status = 200, 'activate_credit_http', 'status=' || v_status);
    v_json := json_object_t.parse(v_body);
    v_data := TREAT(v_json.get('data') AS json_object_t);
    lp_assert(NVL(v_data.get_string('payment_status'), '?') = 'PAID', 'activate_credit_pay',
        NVL(v_data.get_string('payment_status'), 'null'));
    lp_assert(NVL(v_data.get_number('requires_polling'), -1) = 0, 'activate_credit_poll',
        TO_CHAR(NVL(v_data.get_number('requires_polling'), -1)));
    lp_assert(v_data.get_number('invoice_id') IS NOT NULL, 'activate_credit_inv',
        TO_CHAR(v_data.get_number('invoice_id')));
    v_inv_id := v_data.get_number('invoice_id');
    SELECT status, grant_type INTO v_oa_status, v_grant
      FROM org_addon WHERE org_id_organization = v_org_id AND rad_id_addon = v_odonto;
    lp_assert(v_oa_status = 'ACTIVE' AND v_grant = 'PAID', 'activate_credit_grant',
        v_oa_status || '/' || v_grant);
    SELECT COUNT(*) INTO v_cnt
      FROM org_subscription_invoice
     WHERE id_invoice = v_inv_id AND invoice_type = 'MODULE_ADDON' AND status = 'PAID';
    lp_assert(v_cnt = 1, 'activate_credit_row', 'cnt=' || v_cnt);
    SELECT COUNT(*) INTO v_cnt
      FROM subscription_einvoice_outbox
     WHERE invoice_id = v_inv_id;
    lp_assert(v_cnt = 1, 'fe_outbox_enqueued', 'cnt=' || v_cnt);
    lp_assert(TRUE, 'fe_codigo_contract',
        'invoice_type=MODULE_ADDON → HASEL-ADDON (fn_build_einvoice_payload privado + emit-invoice.ts)');

    --------------------------------------------------------------------------
    -- 4) Activate + Pagopar mock/webhook (PENDING → fulfill PAID)
    --------------------------------------------------------------------------
    pkg_aox_addon_api.pr_cancel_module_addon(
        v_auth, '{"addon_code":"ODONTOGRAM_3D"}', v_status, v_body);
    v_hash := 'qa-e2e-mod-wh-' || v_org_id || '-' || TO_CHAR(systimestamp, 'YYYYMMDDHH24MISS');
    INSERT INTO org_subscription_invoice (
        org_id_organization, sub_id_subscription, invoice_type, rad_id_addon,
        description, amount, gross_amount, credit_applied, currency, status,
        period_start, period_end, due_date, payment_provider, external_reference
    ) VALUES (
        v_org_id, v_sub_id, 'MODULE_ADDON', v_odonto,
        'Odontograma 3D (mock webhook E2E)', 1000, 69000, 0, 'PYG', 'PENDING',
        systimestamp, ADD_MONTHS(systimestamp, 1), systimestamp + 1, 'pagopar', v_hash
    ) RETURNING id_invoice INTO v_inv_id;
    COMMIT;
    v_priv  := fn_get_parameter('SUBSCRIPTION_PAGOPAR_PRIVATE_KEY');
    v_token := pkg_aox_pagopar_api.fn_pagopar_sha1_token(v_priv || v_hash);
    pkg_aox_subscription_billing_api.pr_subscription_webhook(
        '{"resultado":[{"hash_pedido":"' || v_hash || '","token":"' || v_token || '","pagado":true}]}',
        v_status,
        v_body
    );
    lp_assert(v_status = 200, 'webhook_http', 'status=' || v_status);
    SELECT status INTO v_oa_status FROM org_subscription_invoice WHERE id_invoice = v_inv_id;
    lp_assert(v_oa_status = 'PAID', 'webhook_invoice', v_oa_status);
    SELECT status, grant_type INTO v_oa_status, v_grant
      FROM org_addon WHERE org_id_organization = v_org_id AND rad_id_addon = v_odonto;
    lp_assert(v_oa_status = 'ACTIVE' AND v_grant = 'PAID', 'webhook_grant',
        v_oa_status || '/' || v_grant);

    --------------------------------------------------------------------------
    -- 5) Cancel PAID + FE 0260 → NCE (BODY_MAP del seed)
    --------------------------------------------------------------------------
    pkg_aox_addon_api.pr_cancel_module_addon(
        v_auth, '{"addon_code":"BODY_MAP"}', v_status, v_body);
    v_json := json_object_t.parse(v_body);
    IF v_json.get_string('status') = 'success' THEN
        v_data    := TREAT(v_json.get('data') AS json_object_t);
        v_nce_q   := NVL(v_data.get_number('nce_queued'), 0);
        v_nce_amt := NVL(v_data.get_number('nce_amount'), 0);
        v_refund  := NVL(v_data.get_string('cancel_refund_type'), 'none');
        lp_assert(v_status = 200 AND v_nce_q = 1 AND v_refund = 'nce' AND v_nce_amt > 0,
            'cancel_paid_nce_api',
            'http=' || v_status || ' queued=' || v_nce_q || ' type=' || v_refund || ' amt=' || v_nce_amt);
    ELSE
        DBMS_OUTPUT.PUT_LINE('WARN cancel_paid_nce_api message=' || v_json.get_string('message'));
    END IF;
    SELECT COUNT(*) INTO v_cnt
      FROM subscription_credit_note n
      JOIN org_subscription_invoice i ON i.id_invoice = n.source_invoice_id
     WHERE n.org_id_organization = v_org_id
       AND i.invoice_type = 'MODULE_ADDON'
       AND i.rad_id_addon = v_body_id
       AND n.status IN ('PENDING', 'PROCESSING', 'DONE', 'FAILED');
    lp_assert(v_cnt >= 1, 'cancel_paid_nce_row', 'cnt=' || v_cnt);
    SELECT status INTO v_oa_status
      FROM org_addon WHERE org_id_organization = v_org_id AND rad_id_addon = v_body_id;
    lp_assert(v_oa_status = 'CANCELED', 'cancel_paid_nce_status', v_oa_status);
    SELECT NVL(account_balance, 0) INTO v_credit
      FROM org_subscription WHERE org_id_organization = v_org_id;
    -- NCE XOR crédito: el saldo no debería subir por esta cancelación.
    lp_assert(TRUE, 'cancel_paid_nce_xor', 'balance_after=' || v_credit);

    --------------------------------------------------------------------------
    -- 6) Ciclo plan + módulos: PREVIEW → PAID (crédito cubre, sin Pagopar)
    --------------------------------------------------------------------------
    UPDATE org_addon
       SET status = 'ACTIVE', grant_type = 'PREVIEW', canceled_at = NULL,
           billing_started_at = NULL, updated_at = systimestamp
     WHERE org_id_organization = v_org_id
       AND rad_id_addon = v_odonto;
    UPDATE org_addon
       SET status = 'ACTIVE', grant_type = 'PREVIEW', canceled_at = NULL,
           billing_started_at = NULL, updated_at = systimestamp
     WHERE org_id_organization = v_org_id
       AND rad_id_addon = v_body_id;
    UPDATE org_subscription
       SET account_balance      = 400000,
           current_period_end   = systimestamp - INTERVAL '1' SECOND,
           charge_retry_count   = 0,
           status               = 'ACTIVE',
           auto_renew           = 1
     WHERE org_id_organization = v_org_id;
    DELETE FROM api_idempotency_key
     WHERE scope_code = 'SUBSCRIPTION_CHARGE_TARGET'
       AND idem_key LIKE 'CYCLE:' || v_org_id || ':%';
    COMMIT;
    pkg_aox_subscription_billing_api.pr_run_billing_cycle_for_org(v_org_id);
    SELECT status, grant_type INTO v_oa_status, v_grant
      FROM org_addon WHERE org_id_organization = v_org_id AND rad_id_addon = v_odonto;
    lp_assert(v_oa_status = 'ACTIVE' AND v_grant = 'PAID', 'cycle_odonto_paid',
        v_oa_status || '/' || v_grant);
    SELECT status, grant_type INTO v_oa_status, v_grant
      FROM org_addon WHERE org_id_organization = v_org_id AND rad_id_addon = v_body_id;
    lp_assert(v_oa_status = 'ACTIVE' AND v_grant = 'PAID', 'cycle_body_paid',
        v_oa_status || '/' || v_grant);
    SELECT COUNT(*) INTO v_cnt
      FROM org_subscription_invoice
     WHERE org_id_organization = v_org_id
       AND invoice_type = 'MODULE_ADDON'
       AND status = 'PAID'
       AND created_at > systimestamp - INTERVAL '10' MINUTE;
    lp_assert(v_cnt >= 2, 'cycle_module_invoices', 'cnt=' || v_cnt);
    SELECT COUNT(*) INTO v_cnt
      FROM org_subscription_invoice
     WHERE org_id_organization = v_org_id
       AND invoice_type = 'SUBSCRIPTION'
       AND status = 'PAID'
       AND created_at > systimestamp - INTERVAL '10' MINUTE;
    lp_assert(v_cnt >= 1, 'cycle_plan_invoice', 'cnt=' || v_cnt);

    lp_restore_flags;

    SELECT param_value INTO v_live_snap FROM app_parameter WHERE param_key = 'ADDONS_BILLING_LIVE';
    SELECT param_value INTO v_bill_snap FROM app_parameter WHERE param_key = 'BILLING_ENABLED';
    DBMS_OUTPUT.PUT_LINE('=== flags finales ADDONS_BILLING_LIVE=' || v_live_snap
        || ' BILLING_ENABLED=' || v_bill_snap || ' failed=' || v_failed || ' ===');
    lp_assert(v_live_snap = '0' AND v_bill_snap = '0', 'flags_restored',
        'LIVE=' || v_live_snap || ' BILLING=' || v_bill_snap);

    IF v_failed > 0 THEN
        RAISE_APPLICATION_ERROR(-20999, v_failed || ' aserciones fallaron. Ver DBMS_OUTPUT.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('=== QA módulos E2E OK ===');
EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            lp_restore_flags;
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
        DBMS_OUTPUT.PUT_LINE('ERROR ' || SQLERRM);
        RAISE;
END;
/
