PROMPT CREATE OR REPLACE PACKAGE pkg_aox_ops_admin_bridge
CREATE OR REPLACE PACKAGE pkg_aox_ops_admin_bridge AS
    -- Puente invocado desde HASEL_ADMIN (JWT ops). Sin HASEL_OPS_USER_IDS ni JWT SaaS.

    /** 1 si DISPUTE_COMPENSATION_ENABLED=1; 0 en cualquier otro valor. */
    FUNCTION fn_dispute_compensation_enabled RETURN NUMBER;

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

    /** Adelanta el lock READ_ONLY del SaaS (escritura + agenda publica). */
    PROCEDURE pr_force_subscription_read_only(
        pi_org_id             IN  NUMBER,
        pi_reason             IN  VARCHAR2,
        pi_actor_employee_id  IN  NUMBER,
        po_status_code        OUT NUMBER,
        po_response_body      OUT CLOB
    );

    /** Deshace un corte OPS y restaura escritura (trial/activa/past_due previo). */
    PROCEDURE pr_restore_subscription_write(
        pi_org_id             IN  NUMBER,
        pi_reason             IN  VARCHAR2,
        pi_actor_employee_id  IN  NUMBER,
        po_status_code        OUT NUMBER,
        po_response_body      OUT CLOB
    );

    /** Encuesta de producto Hasel (WhatsApp Flow SURVEY_APP) disparada desde ops. */
    PROCEDURE pr_send_app_survey_wa(
        pi_phone         IN  VARCHAR2,
        pi_flow_token    IN  VARCHAR2,
        pi_heading       IN  VARCHAR2,
        pi_admin_name    IN  VARCHAR2,
        pi_org_name      IN  VARCHAR2,
        pi_template_name IN  VARCHAR2 DEFAULT NULL,
        pi_flow_id       IN  VARCHAR2 DEFAULT NULL,
        po_success       OUT NUMBER,
        po_error         OUT VARCHAR2
    );
END pkg_aox_ops_admin_bridge;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_ops_admin_bridge
CREATE OR REPLACE PACKAGE BODY pkg_aox_ops_admin_bridge AS

    FUNCTION fn_dispute_compensation_enabled RETURN NUMBER IS
    BEGIN
        IF NVL(fn_get_parameter('DISPUTE_COMPENSATION_ENABLED'), '0') = '1' THEN
            RETURN 1;
        END IF;
        RETURN 0;
    END fn_dispute_compensation_enabled;

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
        IF v_code = 'ISSUE_CREDIT' AND fn_dispute_compensation_enabled <> 1 THEN
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
        pkg_aox_session.set_org(v_org_id);

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

        pkg_aox_session.set_org(pi_org_id);

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

        pkg_aox_session.set_org(pi_org_id);

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

    PROCEDURE pr_send_app_survey_wa(
        pi_phone         IN  VARCHAR2,
        pi_flow_token    IN  VARCHAR2,
        pi_heading       IN  VARCHAR2,
        pi_admin_name    IN  VARCHAR2,
        pi_org_name      IN  VARCHAR2,
        pi_template_name IN  VARCHAR2 DEFAULT NULL,
        pi_flow_id       IN  VARCHAR2 DEFAULT NULL,
        po_success       OUT NUMBER,
        po_error         OUT VARCHAR2
    ) IS
    BEGIN
        po_success := 0;
        po_error   := NULL;
        pkg_aox_meta_api.pr_send_app_survey_wa(
            pi_phone         => pi_phone,
            pi_flow_token    => pi_flow_token,
            pi_heading       => pi_heading,
            pi_admin_name    => pi_admin_name,
            pi_org_name      => pi_org_name,
            pi_template_name => pi_template_name,
            pi_flow_id       => pi_flow_id
        );
        po_success := 1;
    EXCEPTION
        WHEN OTHERS THEN
            po_success := 0;
            po_error := SUBSTR(REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''), 1, 4000);
    END pr_send_app_survey_wa;

    PROCEDURE pr_force_subscription_read_only(
        pi_org_id             IN  NUMBER,
        pi_reason             IN  VARCHAR2,
        pi_actor_employee_id  IN  NUMBER,
        po_status_code        OUT NUMBER,
        po_response_body      OUT CLOB
    ) IS
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
        v_actor    NUMBER := NVL(pi_actor_employee_id, 0);
        v_reason   VARCHAR2(400) := SUBSTR(TRIM(pi_reason), 1, 400);
        v_status   VARCHAR2(20);
        v_founder  NUMBER;
        v_exempt   NUMBER;
        v_exists   NUMBER;
    BEGIN
        IF v_actor <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Actor de operaciones invalido.');
        END IF;
        IF v_reason IS NULL OR LENGTH(v_reason) < 5 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El motivo debe tener al menos 5 caracteres.');
        END IF;
        IF NVL(pi_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Organizacion invalida.');
        END IF;

        pkg_aox_session.set_org(pi_org_id);

        SELECT COUNT(*)
          INTO v_exists
          FROM organization
         WHERE id_organization = pi_org_id;
        IF v_exists = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Organizacion no encontrada.');
        END IF;

        BEGIN
            SELECT status, NVL(is_founder, 0), NVL(billing_exempt, 0)
              INTO v_status, v_founder, v_exempt
              FROM org_subscription
             WHERE org_id_organization = pi_org_id
               FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'La organizacion no tiene suscripcion.');
        END;

        IF v_founder = 1 OR v_exempt = 1 OR v_status = 'FOUNDER' THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'No se puede cortar el acceso de un Founder o exento de cobro.'
            );
        END IF;
        IF v_status = 'READ_ONLY' THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El acceso ya está en solo lectura.');
        END IF;
        IF v_status = 'CANCELED' THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'La suscripcion ya está cancelada.');
        END IF;

        UPDATE org_subscription
           SET status        = 'READ_ONLY',
               auto_renew    = 0,
               grace_ends_at = CURRENT_TIMESTAMP,
               updated_at    = CURRENT_TIMESTAMP
         WHERE org_id_organization = pi_org_id;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Acceso cortado: el negocio quedó en solo lectura.');
        v_data.put('org_id_organization', pi_org_id);
        v_data.put('subscription_status', 'READ_ONLY');
        v_data.put('reason', v_reason);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_force_subscription_read_only;

    PROCEDURE pr_insert_access_audit(
        pi_org_id      IN NUMBER,
        pi_action      IN VARCHAR2,
        pi_reason      IN VARCHAR2,
        pi_from_status IN VARCHAR2,
        pi_to_status   IN VARCHAR2,
        pi_from_auto   IN NUMBER,
        pi_to_auto     IN NUMBER,
        pi_from_grace  IN TIMESTAMP WITH TIME ZONE,
        pi_to_grace    IN TIMESTAMP WITH TIME ZONE,
        pi_actor       IN NUMBER
    ) IS
    BEGIN
        INSERT INTO org_subscription_access_audit (
            org_id_organization,
            action,
            reason,
            from_status,
            to_status,
            from_auto_renew,
            to_auto_renew,
            from_grace_ends_at,
            to_grace_ends_at,
            actor_employee_id
        ) VALUES (
            pi_org_id,
            pi_action,
            pi_reason,
            pi_from_status,
            pi_to_status,
            pi_from_auto,
            pi_to_auto,
            pi_from_grace,
            pi_to_grace,
            pi_actor
        );
    END pr_insert_access_audit;

    PROCEDURE pr_restore_subscription_write(
        pi_org_id             IN  NUMBER,
        pi_reason             IN  VARCHAR2,
        pi_actor_employee_id  IN  NUMBER,
        po_status_code        OUT NUMBER,
        po_response_body      OUT CLOB
    ) IS
        v_response     json_object_t := json_object_t();
        v_data         json_object_t := json_object_t();
        v_actor        NUMBER := NVL(pi_actor_employee_id, 0);
        v_reason       VARCHAR2(400) := SUBSTR(TRIM(pi_reason), 1, 400);
        v_status       VARCHAR2(20);
        v_founder      NUMBER;
        v_exempt       NUMBER;
        v_exists       NUMBER;
        v_auto         NUMBER;
        v_grace        TIMESTAMP WITH TIME ZONE;
        v_trial_ends   TIMESTAMP WITH TIME ZONE;
        v_period_end   TIMESTAMP WITH TIME ZONE;
        v_from_status  VARCHAR2(20);
        v_from_auto    NUMBER;
        v_from_grace   TIMESTAMP WITH TIME ZONE;
        v_last_action  VARCHAR2(20);
        v_effective    VARCHAR2(20);
        v_can_write    NUMBER;
        v_label        VARCHAR2(40);
        v_message      VARCHAR2(400);
    BEGIN
        IF v_actor <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Actor de operaciones invalido.');
        END IF;
        IF v_reason IS NULL OR LENGTH(v_reason) < 5 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El motivo debe tener al menos 5 caracteres.');
        END IF;
        IF NVL(pi_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Organizacion invalida.');
        END IF;

        pkg_aox_session.set_org(pi_org_id);

        SELECT COUNT(*)
          INTO v_exists
          FROM organization
         WHERE id_organization = pi_org_id;
        IF v_exists = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Organizacion no encontrada.');
        END IF;

        BEGIN
            SELECT status,
                   NVL(is_founder, 0),
                   NVL(billing_exempt, 0),
                   NVL(auto_renew, 1),
                   grace_ends_at,
                   trial_ends_at,
                   current_period_end
              INTO v_status, v_founder, v_exempt, v_auto, v_grace, v_trial_ends, v_period_end
              FROM org_subscription
             WHERE org_id_organization = pi_org_id
               FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'La organizacion no tiene suscripcion.');
        END;

        IF v_founder = 1 OR v_exempt = 1 OR v_status = 'FOUNDER' THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'No se puede restaurar el acceso de un Founder o exento de cobro.'
            );
        END IF;
        IF v_status <> 'READ_ONLY' THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'No hay un corte de acceso de OPS para restaurar.'
            );
        END IF;

        BEGIN
            SELECT action, from_status, from_auto_renew, from_grace_ends_at
              INTO v_last_action, v_from_status, v_from_auto, v_from_grace
              FROM (
                SELECT action, from_status, from_auto_renew, from_grace_ends_at
                  FROM org_subscription_access_audit
                 WHERE org_id_organization = pi_org_id
                 ORDER BY created_at DESC, id_access_audit DESC
                 FETCH FIRST 1 ROW ONLY
              );
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_last_action := NULL;
                v_from_status := NULL;
        END;

        IF v_last_action = 'REVOKE' AND v_from_status IS NOT NULL AND v_from_status <> 'READ_ONLY' THEN
            NULL;
        ELSE
            IF v_trial_ends IS NOT NULL AND v_trial_ends > SYSTIMESTAMP THEN
                v_from_status := 'TRIAL';
                v_from_auto := 1;
                v_from_grace := v_grace;
            ELSIF v_period_end IS NULL OR v_period_end > SYSTIMESTAMP THEN
                v_from_status := 'ACTIVE';
                v_from_auto := 1;
                v_from_grace := CASE
                    WHEN v_period_end IS NULL THEN NULL
                    ELSE v_period_end + NUMTODSINTERVAL(3, 'DAY')
                END;
            ELSE
                RAISE_APPLICATION_ERROR(
                    pkg_aox_util.c_sqlcode_validation,
                    'No hay un estado previo para restaurar; el período o trial ya venció.'
                );
            END IF;
        END IF;

        UPDATE org_subscription
           SET status        = v_from_status,
               auto_renew    = NVL(v_from_auto, 1),
               grace_ends_at = v_from_grace,
               updated_at    = CURRENT_TIMESTAMP
         WHERE org_id_organization = pi_org_id;

        pr_insert_access_audit(
            pi_org_id      => pi_org_id,
            pi_action      => 'RESTORE',
            pi_reason      => v_reason,
            pi_from_status => 'READ_ONLY',
            pi_to_status   => v_from_status,
            pi_from_auto   => v_auto,
            pi_to_auto     => NVL(v_from_auto, 1),
            pi_from_grace  => v_grace,
            pi_to_grace    => v_from_grace,
            pi_actor       => v_actor
        );

        COMMIT;

        v_effective := pkg_aox_subscription_api.fn_get_subscription_state(pi_org_id);
        v_can_write := pkg_aox_subscription_api.fn_org_can_write(pi_org_id);
        v_label := CASE v_from_status
                     WHEN 'TRIAL' THEN 'trial'
                     WHEN 'ACTIVE' THEN 'activa'
                     WHEN 'PAST_DUE' THEN 'vencida (con gracia)'
                     ELSE LOWER(v_from_status)
                   END;
        IF NVL(v_can_write, 0) = 1 THEN
            v_message := 'Escritura restaurada: el negocio volvió a ' || v_label || '.';
        ELSE
            v_message := 'Se deshizo el corte de OPS, pero el negocio sigue sin escritura porque el período o trial ya venció.';
        END IF;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', v_message);
        v_data.put('org_id_organization', pi_org_id);
        v_data.put('subscription_status', v_from_status);
        v_data.put('effective_status', v_effective);
        v_data.put('can_write', NVL(v_can_write, 0));
        v_data.put('ops_access_locked', 0);
        v_data.put('reason', v_reason);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_restore_subscription_write;

END pkg_aox_ops_admin_bridge;
/
