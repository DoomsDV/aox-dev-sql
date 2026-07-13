PROMPT CREATE OR REPLACE PACKAGE pkg_aox_refund_claims_api
CREATE OR REPLACE PACKAGE pkg_aox_refund_claims_api IS

    -- SLA plataforma: 48 horas habiles (lun-vie) desde refund_alias_submitted_at.
    c_sla_business_hours CONSTANT NUMBER := 48;
    c_max_strikes        CONSTANT NUMBER := 3;

    FUNCTION fn_add_business_hours(
        pi_from  IN TIMESTAMP WITH TIME ZONE,
        pi_hours IN NUMBER
    ) RETURN TIMESTAMP WITH TIME ZONE;

    FUNCTION fn_refund_sla_deadline(
        pi_alias_submitted_at IN TIMESTAMP WITH TIME ZONE
    ) RETURN TIMESTAMP WITH TIME ZONE;

    FUNCTION fn_is_refund_sla_breached(
        pi_alias_submitted_at IN TIMESTAMP WITH TIME ZONE
    ) RETURN NUMBER;

    -- Cliente reclama desde /r/:token cuando PENDING y SLA vencido.
    PROCEDURE pr_submit_public_claim(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Staff: marcar reembolso como WAIVED (motivo obligatorio).
    PROCEDURE pr_waive_refund(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        pi_body           IN  CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );

    -- Job: abre reclamos automaticos + strikes por SLA vencido.
    PROCEDURE pr_process_refund_sla(
        pi_batch_size IN NUMBER DEFAULT 100
    );

END pkg_aox_refund_claims_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_refund_claims_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_refund_claims_api IS

    FUNCTION fn_add_business_hours(
        pi_from  IN TIMESTAMP WITH TIME ZONE,
        pi_hours IN NUMBER
    ) RETURN TIMESTAMP WITH TIME ZONE IS
        v_ts    TIMESTAMP WITH TIME ZONE := pi_from;
        v_left  NUMBER := GREATEST(NVL(pi_hours, 0), 0);
    BEGIN
        IF pi_from IS NULL OR v_left = 0 THEN
            RETURN pi_from;
        END IF;

        WHILE v_left > 0 LOOP
            v_ts := v_ts + NUMTODSINTERVAL(1, 'HOUR');
            -- Saltar sabado/domingo (America/Asuncion).
            IF TO_CHAR(v_ts AT TIME ZONE 'America/Asuncion', 'DY', 'NLS_DATE_LANGUAGE=AMERICAN')
               NOT IN ('SAT', 'SUN') THEN
                v_left := v_left - 1;
            END IF;
        END LOOP;

        RETURN v_ts;
    END fn_add_business_hours;

    FUNCTION fn_refund_sla_deadline(
        pi_alias_submitted_at IN TIMESTAMP WITH TIME ZONE
    ) RETURN TIMESTAMP WITH TIME ZONE IS
    BEGIN
        IF pi_alias_submitted_at IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN fn_add_business_hours(pi_alias_submitted_at, c_sla_business_hours);
    END fn_refund_sla_deadline;

    FUNCTION fn_is_refund_sla_breached(
        pi_alias_submitted_at IN TIMESTAMP WITH TIME ZONE
    ) RETURN NUMBER IS
        v_deadline TIMESTAMP WITH TIME ZONE;
    BEGIN
        v_deadline := fn_refund_sla_deadline(pi_alias_submitted_at);
        IF v_deadline IS NULL THEN
            RETURN 0;
        END IF;
        IF CURRENT_TIMESTAMP > v_deadline THEN
            RETURN 1;
        END IF;
        RETURN 0;
    END fn_is_refund_sla_breached;

    PROCEDURE pr_ensure_settings_row(pi_org_id IN NUMBER) IS
    BEGIN
        INSERT INTO org_payment_settings (org_id_organization, deposits_enabled)
        SELECT pi_org_id, 0
          FROM dual
         WHERE NOT EXISTS (
            SELECT 1 FROM org_payment_settings WHERE org_id_organization = pi_org_id
         );
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            NULL;
    END pr_ensure_settings_row;

    PROCEDURE pr_apply_strike(
        pi_org_id IN NUMBER,
        pi_notes  IN VARCHAR2
    ) IS
        v_count NUMBER;
    BEGIN
        pr_ensure_settings_row(pi_org_id);

        UPDATE org_payment_settings
           SET refund_strike_count = NVL(refund_strike_count, 0) + 1,
               updated_at          = CURRENT_TIMESTAMP
         WHERE org_id_organization = pi_org_id
        RETURNING refund_strike_count INTO v_count;

        IF v_count >= c_max_strikes THEN
            UPDATE org_payment_settings
               SET deposits_suspended        = 1,
                   deposits_enabled          = 0,
                   deposits_suspended_at     = CURRENT_TIMESTAMP,
                   deposits_suspended_reason = SUBSTR(
                       NVL(pi_notes, 'Suspension automatica: 3 strikes por reembolsos fuera de SLA.'),
                       1, 400
                   ),
                   updated_at                = CURRENT_TIMESTAMP
             WHERE org_id_organization = pi_org_id
               AND NVL(deposits_suspended, 0) = 0;
        END IF;
    END pr_apply_strike;

    PROCEDURE pr_open_claim(
        pi_org_id   IN NUMBER,
        pi_app_id   IN NUMBER,
        pi_source   IN VARCHAR2,
        pi_notes    IN VARCHAR2,
        po_claim_id OUT NUMBER,
        po_created  OUT NUMBER
    ) IS
        v_exists NUMBER := 0;
    BEGIN
        po_created := 0;
        po_claim_id := NULL;

        SELECT /*+ no_parallel */ COUNT(*)
          INTO v_exists
          FROM org_refund_claim
         WHERE app_id_appointment = pi_app_id
           AND claim_status = 'OPEN';

        IF v_exists > 0 THEN
            SELECT id_claim
              INTO po_claim_id
              FROM org_refund_claim
             WHERE app_id_appointment = pi_app_id
               AND claim_status = 'OPEN'
               AND ROWNUM = 1;
            RETURN;
        END IF;

        INSERT INTO org_refund_claim (
            org_id_organization,
            app_id_appointment,
            claim_source,
            claim_status,
            strike_counted,
            notes
        ) VALUES (
            pi_org_id,
            pi_app_id,
            pi_source,
            'OPEN',
            1,
            SUBSTR(pi_notes, 1, 500)
        ) RETURNING id_claim INTO po_claim_id;

        pr_apply_strike(pi_org_id, pi_notes);
        po_created := 1;
    END pr_open_claim;

    PROCEDURE pr_submit_public_claim(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response   json_object_t := json_object_t();
        v_data       json_object_t := json_object_t();
        v_json       json_object_t;
        v_app_id     NUMBER;
        v_org_id     NUMBER;
        v_refund_st  VARCHAR2(20);
        v_alias_at   TIMESTAMP WITH TIME ZONE;
        v_notes      VARCHAR2(500);
        v_claim_id   NUMBER;
        v_created    NUMBER;
        v_deadline   TIMESTAMP WITH TIME ZONE;
    BEGIN
        IF pi_body IS NOT NULL AND DBMS_LOB.GETLENGTH(pi_body) > 0 THEN
            BEGIN
                v_json := json_object_t.parse(pi_body);
                v_notes := SUBSTR(TRIM(v_json.get_string('notes')), 1, 500);
            EXCEPTION
                WHEN OTHERS THEN
                    v_notes := NULL;
            END;
        END IF;

        SELECT a.id_appointment,
               a.org_id_organization,
               a.refund_status,
               a.refund_alias_submitted_at
          INTO v_app_id, v_org_id, v_refund_st, v_alias_at
          FROM appointment a
         WHERE a.public_manage_token = TRIM(pi_public_token)
         FOR UPDATE;

        IF v_refund_st <> 'PENDING' THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Solo podes reclamar un reembolso pendiente.'
            );
        END IF;

        IF fn_is_refund_sla_breached(v_alias_at) = 0 THEN
            v_deadline := fn_refund_sla_deadline(v_alias_at);
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Aun esta dentro del plazo de 48 horas habiles'
                || CASE WHEN v_deadline IS NOT NULL
                        THEN ' (vence ' || TO_CHAR(v_deadline AT TIME ZONE 'America/Asuncion', 'DD/MM/YYYY HH24:MI') || ').'
                        ELSE '.'
                   END
            );
        END IF;

        pr_open_claim(
            pi_org_id   => v_org_id,
            pi_app_id   => v_app_id,
            pi_source   => 'CUSTOMER',
            pi_notes    => NVL(v_notes, 'Reclamo del cliente por reembolso fuera de SLA.'),
            po_claim_id => v_claim_id,
            po_created  => v_created
        );

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put(
            'message',
            CASE WHEN v_created = 1
                 THEN 'Reclamo registrado. Hasel y el comercio fueron notificados.'
                 ELSE 'Ya tenias un reclamo abierto para este reembolso.'
            END
        );
        v_data.put('id_claim', v_claim_id);
        v_data.put('claim_status', 'OPEN');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'Reserva no encontrada.',
                po_response_body => po_response_body
            );
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_submit_public_claim;

    PROCEDURE pr_waive_refund(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        pi_body           IN  CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_org_id     NUMBER;
        v_user_id    NUMBER;
        v_role_id    NUMBER;
        v_app_id     NUMBER;
        v_refund_st  VARCHAR2(20);
        v_reason     VARCHAR2(400);
        v_json       json_object_t;
        v_response   json_object_t := json_object_t();
        v_data       json_object_t := json_object_t();
    BEGIN
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        IF v_role_id NOT IN (
            pkg_aox_util.fn_rol('ADMIN'),
            pkg_aox_util.fn_rol('RECEPCIONISTA')
        ) THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;
        IF pkg_aox_subscription_api.fn_org_has_feature(v_org_id, 'DEPOSIT_COLLECTION') <> 1 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Tu plan no incluye cobro de senas.');
        END IF;
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        IF pi_body IS NULL OR DBMS_LOB.GETLENGTH(pi_body) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Indica el motivo del waiver.');
        END IF;
        v_json := json_object_t.parse(pi_body);
        v_reason := SUBSTR(TRIM(v_json.get_string('reason')), 1, 400);
        IF v_reason IS NULL OR LENGTH(v_reason) < 5 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El motivo debe tener al menos 5 caracteres.');
        END IF;

        SELECT pt.app_id_appointment, a.refund_status
          INTO v_app_id, v_refund_st
          FROM payment_transaction pt
          JOIN appointment a ON a.id_appointment = pt.app_id_appointment
         WHERE pt.id_transaction = pi_transaction_id
           AND pt.org_id_organization = v_org_id
           AND pt.provider = 'sipap'
         FOR UPDATE OF a.refund_status;

        IF v_refund_st NOT IN ('PENDING', 'AWAITING_ALIAS') THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Solo se pueden renunciar reembolsos pendientes o esperando alias.'
            );
        END IF;

        UPDATE appointment
           SET refund_status    = 'WAIVED',
               updated_at       = CURRENT_TIMESTAMP
         WHERE id_appointment = v_app_id;

        UPDATE org_refund_claim
           SET claim_status = 'DISMISSED',
               resolved_at  = CURRENT_TIMESTAMP,
               resolved_by  = v_user_id,
               notes        = SUBSTR(NVL(notes || ' | ', '') || 'WAIVED: ' || v_reason, 1, 500)
         WHERE app_id_appointment = v_app_id
           AND claim_status = 'OPEN';

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Reembolso marcado como renunciado (WAIVED).');
        v_data.put('id_transaction', pi_transaction_id);
        v_data.put('id_appointment', v_app_id);
        v_data.put('refund_status', 'WAIVED');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            RAISE_APPLICATION_ERROR(-20004, 'Cobro no encontrado.');
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_waive_refund;

    PROCEDURE pr_process_refund_sla(
        pi_batch_size IN NUMBER DEFAULT 100
    ) IS
        v_limit    NUMBER := LEAST(GREATEST(NVL(pi_batch_size, 100), 1), 500);
        v_claim_id NUMBER;
        v_created  NUMBER;
        v_count    NUMBER := 0;
    BEGIN
        FOR rec IN (
            SELECT /*+ no_parallel */
                   a.id_appointment,
                   a.org_id_organization,
                   a.refund_alias_submitted_at
              FROM appointment a
             WHERE a.refund_status = 'PENDING'
               AND a.refund_alias_submitted_at IS NOT NULL
               AND NOT EXISTS (
                    SELECT 1
                      FROM org_refund_claim c
                     WHERE c.app_id_appointment = a.id_appointment
                       AND c.claim_status = 'OPEN'
               )
             ORDER BY a.refund_alias_submitted_at
             FETCH FIRST v_limit ROWS ONLY
        ) LOOP
            IF fn_is_refund_sla_breached(rec.refund_alias_submitted_at) = 1 THEN
                pr_open_claim(
                    pi_org_id   => rec.org_id_organization,
                    pi_app_id   => rec.id_appointment,
                    pi_source   => 'SLA_JOB',
                    pi_notes    => 'Reclamo automatico: reembolso PENDING fuera de SLA (48h habiles).',
                    po_claim_id => v_claim_id,
                    po_created  => v_created
                );
                IF v_created = 1 THEN
                    v_count := v_count + 1;
                END IF;
            END IF;
        END LOOP;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END pr_process_refund_sla;

END pkg_aox_refund_claims_api;
/
