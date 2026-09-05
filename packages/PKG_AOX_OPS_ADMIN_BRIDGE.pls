PROMPT CREATE OR REPLACE PACKAGE pkg_aox_ops_admin_bridge
CREATE OR REPLACE PACKAGE pkg_aox_ops_admin_bridge AS
    -- Puente invocado desde HASEL_ADMIN (JWT ops). Sin HASEL_OPS_USER_IDS ni JWT SaaS.

    PROCEDURE pr_resolve_dispute(
        pi_dispute_id         IN  NUMBER,
        pi_resolution_code    IN  VARCHAR2,
        pi_notes              IN  VARCHAR2 DEFAULT NULL,
        pi_actor_employee_id  IN  NUMBER,
        po_status_code        OUT NUMBER,
        po_response_body      OUT CLOB
    );

    PROCEDURE pr_restore_enforcement(
        pi_org_id             IN  NUMBER,
        pi_reason             IN  VARCHAR2,
        pi_actor_employee_id  IN  NUMBER,
        po_status_code        OUT NUMBER,
        po_response_body      OUT CLOB
    );

    /** Encola inbox in-app para campana ops. po_inserted=1 si inserto; 0 si dedupe u error. */
    PROCEDURE pr_enqueue_campaign_inbox(
        pi_org_id          IN  NUMBER,
        pi_org_member_id   IN  NUMBER,
        pi_title           IN  VARCHAR2,
        pi_body            IN  VARCHAR2 DEFAULT NULL,
        pi_action_url      IN  VARCHAR2 DEFAULT NULL,
        pi_campaign_id     IN  NUMBER,
        pi_dedupe_key      IN  VARCHAR2,
        po_inserted        OUT NUMBER,
        po_error           OUT VARCHAR2
    );

    /** Envio FCM puntual; expone resultado de pr_send_push_checked. */
    PROCEDURE pr_send_campaign_push(
        pi_token     IN  VARCHAR2,
        pi_title     IN  VARCHAR2,
        pi_body      IN  VARCHAR2,
        pi_url       IN  VARCHAR2 DEFAULT NULL,
        po_success   OUT NUMBER,
        po_error     OUT VARCHAR2
    );
END pkg_aox_ops_admin_bridge;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_ops_admin_bridge
CREATE OR REPLACE PACKAGE BODY pkg_aox_ops_admin_bridge AS

    FUNCTION fn_is_terminal_status(pi_status IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF pi_status IN ('REFUND_SETTLED', 'TIMED_OUT', 'RESOLVED_BY_OPS', 'DISMISSED') THEN
            RETURN 1;
        END IF;
        RETURN 0;
    END fn_is_terminal_status;

    PROCEDURE pr_resolve_dispute(
        pi_dispute_id         IN  NUMBER,
        pi_resolution_code    IN  VARCHAR2,
        pi_notes              IN  VARCHAR2 DEFAULT NULL,
        pi_actor_employee_id  IN  NUMBER,
        po_status_code        OUT NUMBER,
        po_response_body      OUT CLOB
    ) IS
        v_code     VARCHAR2(40) := UPPER(TRIM(pi_resolution_code));
        v_notes    VARCHAR2(500) := SUBSTR(TRIM(pi_notes), 1, 500);
        v_status   VARCHAR2(30);
        v_org_id   NUMBER;
        v_app_id   NUMBER;
        v_next     VARCHAR2(30);
        v_close    VARCHAR2(40);
        v_updated  NUMBER;
        v_ev_id    NUMBER;
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
        v_actor    NUMBER := NVL(pi_actor_employee_id, 0);
    BEGIN
        IF v_actor <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Actor de operaciones invalido.');
        END IF;
        IF v_code NOT IN ('SETTLED', 'DISMISS', 'ADVERSE', 'ISSUE_CREDIT') THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'resolution_code invalido. Usa SETTLED, DISMISS, ADVERSE o ISSUE_CREDIT.'
            );
        END IF;
        IF v_code = 'ISSUE_CREDIT' AND NVL(fn_get_parameter('DISPUTE_COMPENSATION_ENABLED'), '0') <> '1' THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'ISSUE_CREDIT no esta habilitado (DISPUTE_COMPENSATION_ENABLED=0).'
            );
        END IF;

        SELECT org_id_organization, app_id_appointment, dispute_status, current_evidence_id
          INTO v_org_id, v_app_id, v_status, v_ev_id
          FROM org_refund_dispute
         WHERE id_dispute = pi_dispute_id
         FOR UPDATE;

        IF fn_is_terminal_status(v_status) = 1 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El caso ya esta cerrado.');
        END IF;

        IF v_code = 'SETTLED' THEN
            v_next := 'REFUND_SETTLED';
            v_close := 'OPS_SETTLED';
        ELSIF v_code = 'DISMISS' THEN
            v_next := 'DISMISSED';
            v_close := 'OPS_DISMISSED';
        ELSIF v_code = 'ADVERSE' THEN
            v_next := 'TIMED_OUT';
            v_close := 'OPS_ADVERSE';
        ELSE
            v_next := 'RESOLVED_BY_OPS';
            v_close := 'OPS_CREDIT';
        END IF;

        UPDATE org_refund_dispute
           SET dispute_status  = v_next,
               close_reason    = v_close,
               resolution_code = v_code,
               notes           = SUBSTR(NVL(notes || ' | ', '') || NVL(v_notes, v_code), 1, 500),
               closed_at       = CURRENT_TIMESTAMP,
               closed_by       = v_actor,
               resolved_at     = CURRENT_TIMESTAMP,
               resolved_by     = v_actor,
               updated_at      = CURRENT_TIMESTAMP
         WHERE id_dispute = pi_dispute_id
           AND dispute_status NOT IN ('REFUND_SETTLED', 'TIMED_OUT', 'RESOLVED_BY_OPS', 'DISMISSED')
        RETURNING 1 INTO v_updated;

        IF NVL(v_updated, 0) <> 1 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'No se pudo resolver el caso.');
        END IF;

        IF v_ev_id IS NOT NULL THEN
            UPDATE org_refund_dispute_evidence
               SET review_decision = CASE
                                       WHEN v_code = 'SETTLED' THEN 'SETTLED'
                                       WHEN v_code = 'ADVERSE' THEN 'ADVERSE'
                                       WHEN v_code = 'DISMISS' THEN 'REJECTED'
                                       ELSE review_decision
                                     END,
                   reviewed_by     = v_actor,
                   reviewed_at     = CURRENT_TIMESTAMP,
                   review_notes    = v_notes
             WHERE id_evidence = v_ev_id;
        END IF;

        IF v_code = 'ADVERSE' THEN
            BEGIN
                INSERT INTO org_refund_strike (org_id_organization, dispute_id, reason)
                VALUES (v_org_id, pi_dispute_id, 'OPS_ADVERSE');
                UPDATE org_payment_settings
                   SET refund_strike_count = NVL(refund_strike_count, 0) + 1,
                       updated_at          = CURRENT_TIMESTAMP
                 WHERE org_id_organization = v_org_id;
                pkg_aox_payment_settings_api.pr_escalate_refund_enforcement(
                    pi_org_id        => v_org_id,
                    pi_reason        => NVL(v_notes, 'Resolucion adversa de Operaciones.'),
                    pi_dispute_id    => pi_dispute_id,
                    pi_actor_user_id => v_actor,
                    pi_max_level     => 'PUBLIC_UNPUBLISHED'
                );
            EXCEPTION
                WHEN DUP_VAL_ON_INDEX THEN
                    NULL;
            END;
        ELSIF v_code = 'ISSUE_CREDIT' THEN
            pkg_aox_refund_compensation_api.pr_issue_customer_compensation(
                pi_dispute_id    => pi_dispute_id,
                pi_actor_user_id => v_actor,
                pi_notes         => v_notes
            );
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Caso resuelto por Operaciones.');
        v_data.put('id_dispute', pi_dispute_id);
        v_data.put('dispute_status', v_next);
        v_data.put('resolution_code', v_code);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'Disputa no encontrada.',
                po_response_body => po_response_body
            );
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_resolve_dispute;

    PROCEDURE pr_restore_enforcement(
        pi_org_id             IN  NUMBER,
        pi_reason             IN  VARCHAR2,
        pi_actor_employee_id  IN  NUMBER,
        po_status_code        OUT NUMBER,
        po_response_body      OUT CLOB
    ) IS
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
        v_actor    NUMBER := NVL(pi_actor_employee_id, 0);
    BEGIN
        IF v_actor <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Actor de operaciones invalido.');
        END IF;

        pkg_aox_payment_settings_api.pr_restore_refund_enforcement(
            pi_org_id        => pi_org_id,
            pi_reason        => pi_reason,
            pi_actor_user_id => v_actor
        );
        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Sancion operativa restaurada.');
        v_data.put('org_id_organization', pi_org_id);
        v_data.put('refund_enforcement_level', 'NONE');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_restore_enforcement;

    PROCEDURE pr_enqueue_campaign_inbox(
        pi_org_id          IN  NUMBER,
        pi_org_member_id   IN  NUMBER,
        pi_title           IN  VARCHAR2,
        pi_body            IN  VARCHAR2 DEFAULT NULL,
        pi_action_url      IN  VARCHAR2 DEFAULT NULL,
        pi_campaign_id     IN  NUMBER,
        pi_dedupe_key      IN  VARCHAR2,
        po_inserted        OUT NUMBER,
        po_error           OUT VARCHAR2
    ) IS
        v_title VARCHAR2(500) := SUBSTR(TRIM(pi_title), 1, 500);
        v_key   VARCHAR2(200) := NULLIF(TRIM(pi_dedupe_key), '');
    BEGIN
        po_inserted := 0;
        po_error    := NULL;

        IF pi_org_id IS NULL OR pi_org_id <= 0
           OR pi_org_member_id IS NULL OR pi_org_member_id <= 0
           OR v_title IS NULL
        THEN
            po_error := 'Parametros de inbox invalidos.';
            RETURN;
        END IF;

        INSERT INTO user_notification (
            org_id_organization,
            org_member_id,
            ntype,
            title,
            body,
            action_type,
            action_url,
            campaign_id,
            dedupe_key
        ) VALUES (
            pi_org_id,
            pi_org_member_id,
            'SYSTEM',
            v_title,
            SUBSTR(pi_body, 1, 4000),
            'OPEN_URL',
            SUBSTR(TRIM(pi_action_url), 1, 1000),
            pi_campaign_id,
            v_key
        );

        po_inserted := 1;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            po_inserted := 0;
        WHEN OTHERS THEN
            po_inserted := 0;
            po_error := SUBSTR(SQLERRM, 1, 4000);
            pkg_aox_util.pr_log_push_fcm(
                pi_process_name  => 'PKG_AOX_OPS_ADMIN_BRIDGE.PR_ENQUEUE_CAMPAIGN_INBOX',
                pi_status        => 'ERROR',
                pi_error_code    => SQLCODE,
                pi_error_message => SQLERRM,
                pi_parameters    => 'org_member_id=' || pi_org_member_id
            );
    END pr_enqueue_campaign_inbox;

    PROCEDURE pr_send_campaign_push(
        pi_token     IN  VARCHAR2,
        pi_title     IN  VARCHAR2,
        pi_body      IN  VARCHAR2,
        pi_url       IN  VARCHAR2 DEFAULT NULL,
        po_success   OUT NUMBER,
        po_error     OUT VARCHAR2
    ) IS
    BEGIN
        pkg_aox_fcm_api.pr_send_push_checked(
            pi_token   => pi_token,
            pi_title   => pi_title,
            pi_body    => pi_body,
            pi_url     => pi_url,
            po_success => po_success,
            po_error   => po_error
        );
    END pr_send_campaign_push;

END pkg_aox_ops_admin_bridge;
/
