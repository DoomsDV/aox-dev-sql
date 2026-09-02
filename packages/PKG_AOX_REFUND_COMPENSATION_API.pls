PROMPT CREATE OR REPLACE PACKAGE pkg_aox_refund_compensation_api
CREATE OR REPLACE PACKAGE pkg_aox_refund_compensation_api IS

    FUNCTION fn_compensation_enabled RETURN NUMBER;

    PROCEDURE pr_issue_customer_compensation(
        pi_dispute_id    IN NUMBER,
        pi_actor_user_id IN NUMBER,
        pi_notes         IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE pr_record_recovery_payment(
        pi_org_id        IN NUMBER,
        pi_dispute_id    IN NUMBER,
        pi_amount_gs     IN NUMBER,
        pi_actor_user_id IN NUMBER,
        pi_idempotency_key IN VARCHAR2,
        pi_notes         IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE pr_reverse_unused_credit(
        pi_dispute_id    IN NUMBER,
        pi_actor_user_id IN NUMBER,
        pi_notes         IN VARCHAR2 DEFAULT NULL
    );

END pkg_aox_refund_compensation_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_refund_compensation_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_refund_compensation_api IS

    FUNCTION fn_compensation_enabled RETURN NUMBER IS
    BEGIN
        RETURN CASE
            WHEN NVL(TRIM(fn_get_parameter('DISPUTE_COMPENSATION_ENABLED')), '0') IN ('1', 'true', 'TRUE', 'YES')
            THEN 1 ELSE 0
        END;
    END fn_compensation_enabled;

    PROCEDURE pr_assert_enabled IS
    BEGIN
        IF fn_compensation_enabled <> 1 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'La compensacion de disputas no esta habilitada. Requiere gate financiero, identidad y riel de recupero.'
            );
        END IF;
    END pr_assert_enabled;

    PROCEDURE pr_lock_dispute(
        pi_dispute_id IN NUMBER,
        po_org_id     OUT NUMBER,
        po_app_id     OUT NUMBER,
        po_cus_id     OUT NUMBER,
        po_amount     OUT NUMBER,
        po_status     OUT VARCHAR2
    ) IS
    BEGIN
        SELECT d.org_id_organization,
               d.app_id_appointment,
               a.cus_id_customer,
               NVL(a.refund_amount, 0),
               d.dispute_status
          INTO po_org_id, po_app_id, po_cus_id, po_amount, po_status
          FROM org_refund_dispute d
          JOIN appointment a ON a.id_appointment = d.app_id_appointment
         WHERE d.id_dispute = pi_dispute_id
         FOR UPDATE OF d.id_dispute;
    END pr_lock_dispute;

    PROCEDURE pr_append_ledger(
        pi_org_id         IN NUMBER,
        pi_dispute_id     IN NUMBER,
        pi_compensation_id IN NUMBER,
        pi_event_type     IN VARCHAR2,
        pi_amount_gs      IN NUMBER,
        pi_delta_due      IN NUMBER,
        pi_balance_after  IN NUMBER,
        pi_idem_key       IN VARCHAR2,
        pi_actor_user_id  IN NUMBER,
        pi_notes          IN VARCHAR2
    ) IS
    BEGIN
        INSERT INTO org_refund_dispute_ledger (
            org_id_organization,
            dispute_id,
            compensation_id,
            event_type,
            amount_gs,
            delta_due,
            balance_due_after,
            idempotency_key,
            actor_user_id,
            metadata
        ) VALUES (
            pi_org_id,
            pi_dispute_id,
            pi_compensation_id,
            pi_event_type,
            pi_amount_gs,
            pi_delta_due,
            pi_balance_after,
            pi_idem_key,
            pi_actor_user_id,
            CASE WHEN pi_notes IS NOT NULL THEN '{"notes":"' || REPLACE(SUBSTR(pi_notes, 1, 200), '"', '') || '"}' ELSE NULL END
        );
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            NULL;
    END pr_append_ledger;

    PROCEDURE pr_issue_customer_compensation(
        pi_dispute_id    IN NUMBER,
        pi_actor_user_id IN NUMBER,
        pi_notes         IN VARCHAR2 DEFAULT NULL
    ) IS
        v_org_id   NUMBER;
        v_app_id   NUMBER;
        v_cus_id   NUMBER;
        v_amount   NUMBER;
        v_status   VARCHAR2(30);
        v_comp_id  NUMBER;
        v_cap      NUMBER;
        v_period   NUMBER;
        v_used     NUMBER;
    BEGIN
        pr_assert_enabled;
        pr_lock_dispute(pi_dispute_id, v_org_id, v_app_id, v_cus_id, v_amount, v_status);

        IF NVL(v_amount, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'No hay monto de reembolso para compensar.');
        END IF;

        v_cap := NVL(pkg_aox_util.fn_param_number('DISPUTE_COMPENSATION_CAP_GS', 500000), 500000);
        IF v_amount > v_cap THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'El monto supera el tope de compensacion por caso.'
            );
        END IF;

        v_period := NVL(pkg_aox_util.fn_param_number('DISPUTE_COMPENSATION_ORG_MONTH_CAP_GS', 2000000), 2000000);
        SELECT NVL(SUM(amount_gs), 0)
          INTO v_used
          FROM org_refund_dispute_compensation
         WHERE org_id_organization = v_org_id
           AND credit_status IN ('ISSUED', 'REDEEMED')
           AND issued_at >= TRUNC(CURRENT_TIMESTAMP, 'MM');
        IF v_used + v_amount > v_period THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'La organizacion alcanzo el tope mensual de compensacion.'
            );
        END IF;

        BEGIN
            INSERT INTO org_refund_dispute_compensation (
                dispute_id,
                org_id_organization,
                app_id_appointment,
                cus_id_customer,
                amount_gs,
                credit_status,
                debt_status,
                issued_at,
                issued_by,
                notes
            ) VALUES (
                pi_dispute_id,
                v_org_id,
                v_app_id,
                v_cus_id,
                v_amount,
                'ISSUED',
                'OPEN',
                CURRENT_TIMESTAMP,
                pi_actor_user_id,
                SUBSTR(pi_notes, 1, 500)
            ) RETURNING id_compensation INTO v_comp_id;
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                SELECT id_compensation
                  INTO v_comp_id
                  FROM org_refund_dispute_compensation
                 WHERE dispute_id = pi_dispute_id;
                RETURN;
        END;

        pr_append_ledger(
            v_org_id, pi_dispute_id, v_comp_id,
            'CUSTOMER_CREDIT_ISSUED', v_amount, 0, v_amount,
            'COMP:' || pi_dispute_id, pi_actor_user_id, pi_notes
        );
        pr_append_ledger(
            v_org_id, pi_dispute_id, v_comp_id,
            'ORG_DEBT_OPENED', v_amount, v_amount, v_amount,
            'DEBT:' || pi_dispute_id, pi_actor_user_id, pi_notes
        );
    END pr_issue_customer_compensation;

    PROCEDURE pr_record_recovery_payment(
        pi_org_id        IN NUMBER,
        pi_dispute_id    IN NUMBER,
        pi_amount_gs     IN NUMBER,
        pi_actor_user_id IN NUMBER,
        pi_idempotency_key IN VARCHAR2,
        pi_notes         IN VARCHAR2 DEFAULT NULL
    ) IS
        v_comp_id  NUMBER;
        v_due      NUMBER;
        v_recovered NUMBER;
        v_amount   NUMBER := NVL(pi_amount_gs, 0);
        v_new_rec  NUMBER;
        v_status   VARCHAR2(20);
    BEGIN
        pr_assert_enabled;
        IF TRIM(pi_idempotency_key) IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'idempotency_key obligatorio.');
        END IF;
        IF v_amount <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Monto de recupero invalido.');
        END IF;

        SELECT id_compensation, amount_gs, recovered_amount_gs, debt_status
          INTO v_comp_id, v_due, v_recovered, v_status
          FROM org_refund_dispute_compensation
         WHERE dispute_id = pi_dispute_id
           AND org_id_organization = pi_org_id
         FOR UPDATE;

        IF v_status IN ('RECOVERED', 'WAIVED') THEN
            RETURN;
        END IF;

        v_new_rec := LEAST(v_due, NVL(v_recovered, 0) + v_amount);

        UPDATE org_refund_dispute_compensation
           SET recovered_amount_gs = v_new_rec,
               debt_status = CASE WHEN v_new_rec >= amount_gs THEN 'RECOVERED' ELSE 'OPEN' END,
               recovered_at = CASE WHEN v_new_rec >= amount_gs THEN CURRENT_TIMESTAMP ELSE recovered_at END,
               updated_at = CURRENT_TIMESTAMP,
               notes = SUBSTR(NVL(notes || ' | ', '') || NVL(pi_notes, 'Recupero'), 1, 500)
         WHERE id_compensation = v_comp_id;

        pr_append_ledger(
            pi_org_id, pi_dispute_id, v_comp_id,
            'DEBT_RECOVERED', v_amount, -v_amount, GREATEST(v_due - v_new_rec, 0),
            TRIM(pi_idempotency_key), pi_actor_user_id, pi_notes
        );
    END pr_record_recovery_payment;

    PROCEDURE pr_reverse_unused_credit(
        pi_dispute_id    IN NUMBER,
        pi_actor_user_id IN NUMBER,
        pi_notes         IN VARCHAR2 DEFAULT NULL
    ) IS
        v_comp_id NUMBER;
        v_org_id  NUMBER;
        v_amount  NUMBER;
        v_credit  VARCHAR2(20);
    BEGIN
        pr_assert_enabled;

        SELECT id_compensation, org_id_organization, amount_gs, credit_status
          INTO v_comp_id, v_org_id, v_amount, v_credit
          FROM org_refund_dispute_compensation
         WHERE dispute_id = pi_dispute_id
         FOR UPDATE;

        IF v_credit <> 'ISSUED' THEN
            RETURN;
        END IF;

        UPDATE org_refund_dispute_compensation
           SET credit_status = 'REVERSED',
               debt_status   = CASE WHEN debt_status = 'OPEN' THEN 'WAIVED' ELSE debt_status END,
               updated_at    = CURRENT_TIMESTAMP,
               notes         = SUBSTR(NVL(notes || ' | ', '') || NVL(pi_notes, 'Reverso por reembolso tardio'), 1, 500)
         WHERE id_compensation = v_comp_id;

        pr_append_ledger(
            v_org_id, pi_dispute_id, v_comp_id,
            'CREDIT_REVERSED', v_amount, 0, 0,
            'REV:' || pi_dispute_id, pi_actor_user_id, pi_notes
        );
        pr_append_ledger(
            v_org_id, pi_dispute_id, v_comp_id,
            'DEBT_WAIVED', v_amount, -v_amount, 0,
            'WAIVE:' || pi_dispute_id, pi_actor_user_id, pi_notes
        );
    END pr_reverse_unused_credit;

END pkg_aox_refund_compensation_api;
/
