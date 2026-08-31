PROMPT CREATE OR REPLACE PACKAGE pkg_aox_refund_disputes_api
CREATE OR REPLACE PACKAGE pkg_aox_refund_disputes_api IS

    c_sla_business_hours CONSTANT NUMBER := 48;
    c_max_strikes        CONSTANT NUMBER := 3;
    c_extractor_version  CONSTANT VARCHAR2(40) := 'refund_proof_v1';

    FUNCTION fn_iso_ts(pi_ts IN TIMESTAMP WITH TIME ZONE) RETURN VARCHAR2;

    FUNCTION fn_build_public_dto(
        pi_app_id            IN NUMBER,
        pi_refund_status     IN VARCHAR2,
        pi_refund_sent_at    IN TIMESTAMP WITH TIME ZONE,
        pi_alias_submitted_at IN TIMESTAMP WITH TIME ZONE,
        pi_public_whatsapp   IN VARCHAR2,
        pi_customer_phone    IN VARCHAR2
    ) RETURN json_object_t;

    PROCEDURE pr_open_public_dispute(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_insist_public(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_get_public_proof(
        pi_public_token  IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_upload_staff_proof(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        pi_body           IN  CLOB,
        pi_idempotency_key IN VARCHAR2 DEFAULT NULL,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );

    PROCEDURE pr_get_staff_proof(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );

    PROCEDURE pr_process_dispute_timeouts(
        pi_batch_size IN NUMBER DEFAULT 100
    );

    PROCEDURE pr_process_notify_outbox(
        pi_batch_size IN NUMBER DEFAULT 50
    );

    PROCEDURE pr_dismiss_for_appointment(
        pi_app_id  IN NUMBER,
        pi_user_id IN NUMBER,
        pi_reason  IN VARCHAR2
    );

END pkg_aox_refund_disputes_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_refund_disputes_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_refund_disputes_api IS

    FUNCTION fn_iso_ts(pi_ts IN TIMESTAMP WITH TIME ZONE) RETURN VARCHAR2 IS
    BEGIN
        IF pi_ts IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN TO_CHAR(pi_ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    END fn_iso_ts;

    FUNCTION fn_digits(pi_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REGEXP_REPLACE(NVL(pi_value, ''), '[^0-9]', '');
    END fn_digits;

    FUNCTION fn_phone_last4(pi_phone IN VARCHAR2) RETURN VARCHAR2 IS
        v_digits VARCHAR2(40) := fn_digits(pi_phone);
    BEGIN
        IF v_digits IS NULL OR LENGTH(v_digits) < 4 THEN
            RETURN NULL;
        END IF;
        RETURN SUBSTR(v_digits, -4);
    END fn_phone_last4;

    FUNCTION fn_active_status(pi_status IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF pi_status IN ('OPEN', 'EVIDENCE_PROCESSING') THEN
            RETURN 1;
        END IF;
        RETURN 0;
    END fn_active_status;

    FUNCTION fn_viewable_status(pi_status IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF pi_status IN ('EVIDENCE_ACCEPTED', 'CUSTOMER_FOLLOW_UP') THEN
            RETURN 1;
        END IF;
        RETURN 0;
    END fn_viewable_status;

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

    PROCEDURE pr_enqueue_notify(
        pi_org_id     IN NUMBER,
        pi_dispute_id IN NUMBER,
        pi_event      IN VARCHAR2,
        pi_payload    IN CLOB
    ) IS
    BEGIN
        INSERT INTO org_refund_notify_outbox (
            org_id_organization,
            dispute_id,
            channel,
            event_code,
            dedupe_key,
            status,
            payload
        ) VALUES (
            pi_org_id,
            pi_dispute_id,
            'FCM',
            pi_event,
            'DISPUTE:' || pi_dispute_id || ':' || pi_event || ':FCM',
            'PENDING',
            pi_payload
        );
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            NULL;
    END pr_enqueue_notify;

    FUNCTION fn_build_public_dto(
        pi_app_id             IN NUMBER,
        pi_refund_status      IN VARCHAR2,
        pi_refund_sent_at     IN TIMESTAMP WITH TIME ZONE,
        pi_alias_submitted_at IN TIMESTAMP WITH TIME ZONE,
        pi_public_whatsapp    IN VARCHAR2,
        pi_customer_phone     IN VARCHAR2
    ) RETURN json_object_t IS
        v_obj            json_object_t := json_object_t();
        v_status         VARCHAR2(30);
        v_due            TIMESTAMP WITH TIME ZONE;
        v_source         VARCHAR2(20);
        v_can_open       NUMBER := 0;
        v_wait_modal     NUMBER := 0;
        v_has_proof      NUMBER := 0;
        v_pending_sla    NUMBER := 0;
        v_refund_st      VARCHAR2(20) := UPPER(TRIM(NVL(pi_refund_status, 'NONE')));
        v_last4          VARCHAR2(4);
    BEGIN
        BEGIN
            SELECT d.dispute_status, d.proof_due_at, d.dispute_source
              INTO v_status, v_due, v_source
              FROM org_refund_dispute d
             WHERE d.app_id_appointment = pi_app_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_status := NULL;
        END;

        IF v_refund_st = 'PENDING' THEN
            v_pending_sla := pkg_aox_refund_claims_api.fn_is_refund_sla_breached(pi_alias_submitted_at);
        END IF;

        IF v_status IS NULL THEN
            IF v_refund_st = 'SENT' THEN
                v_can_open := 1;
                IF pi_refund_sent_at IS NOT NULL
                   AND pkg_aox_refund_claims_api.fn_is_refund_sla_breached(pi_refund_sent_at) = 0 THEN
                    v_wait_modal := 1;
                END IF;
            ELSIF v_refund_st = 'PENDING' AND v_pending_sla = 1 THEN
                v_can_open := 1;
            END IF;
        END IF;

        IF fn_viewable_status(v_status) = 1 THEN
            v_has_proof := 1;
        END IF;

        v_last4 := fn_phone_last4(pi_customer_phone);

        v_obj.put('status', v_status);
        v_obj.put('can_open', v_can_open);
        v_obj.put('wait_modal_required', v_wait_modal);
        v_obj.put('has_viewable_proof', v_has_proof);
        v_obj.put('proof_due_at', fn_iso_ts(v_due));
        v_obj.put('refund_sent_at', fn_iso_ts(pi_refund_sent_at));
        v_obj.put('public_whatsapp', NVL(TRIM(pi_public_whatsapp), ''));
        v_obj.put('phone_last4_hint', v_last4);
        v_obj.put('source', v_source);
        RETURN v_obj;
    END fn_build_public_dto;

    PROCEDURE pr_apply_timeout_strike(
        pi_dispute_id IN NUMBER
    ) IS
        v_org_id     NUMBER;
        v_app_id     NUMBER;
        v_status     VARCHAR2(30);
        v_due        TIMESTAMP WITH TIME ZONE;
        v_ocr        VARCHAR2(30);
        v_updated    NUMBER;
        v_count      NUMBER;
    BEGIN
        SELECT /*+ no_parallel */
               org_id_organization, app_id_appointment, dispute_status, proof_due_at
          INTO v_org_id, v_app_id, v_status, v_due
          FROM org_refund_dispute
         WHERE id_dispute = pi_dispute_id
         FOR UPDATE SKIP LOCKED;

        IF v_status NOT IN ('OPEN', 'EVIDENCE_PROCESSING') THEN
            RETURN;
        END IF;
        IF v_due IS NULL OR CURRENT_TIMESTAMP <= v_due THEN
            RETURN;
        END IF;

        BEGIN
            SELECT e.ocr_status
              INTO v_ocr
              FROM org_refund_dispute d
              JOIN org_refund_dispute_evidence e ON e.id_evidence = d.current_evidence_id
             WHERE d.id_dispute = pi_dispute_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_ocr := NULL;
        END;

        IF v_ocr IN ('PROCESSING', 'ACCEPTED', 'MANUAL_REVIEW') THEN
            RETURN;
        END IF;

        UPDATE org_refund_dispute
           SET dispute_status = 'EXPIRED_STRIKE',
               close_reason   = 'TIMEOUT',
               closed_at      = CURRENT_TIMESTAMP,
               updated_at     = CURRENT_TIMESTAMP
         WHERE id_dispute = pi_dispute_id
           AND dispute_status IN ('OPEN', 'EVIDENCE_PROCESSING')
        RETURNING 1 INTO v_updated;

        IF NVL(v_updated, 0) <> 1 THEN
            RETURN;
        END IF;

        BEGIN
            INSERT INTO org_refund_strike (
                org_id_organization, dispute_id, reason
            ) VALUES (
                v_org_id, pi_dispute_id, 'TIMEOUT'
            );
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                RETURN;
        END;

        pr_ensure_settings_row(v_org_id);
        UPDATE org_payment_settings
           SET refund_strike_count = NVL(refund_strike_count, 0) + 1,
               updated_at          = CURRENT_TIMESTAMP
         WHERE org_id_organization = v_org_id
        RETURNING refund_strike_count INTO v_count;

        IF v_count >= c_max_strikes THEN
            UPDATE org_payment_settings
               SET deposits_suspended        = 1,
                   deposits_enabled          = 0,
                   deposits_suspended_at     = CURRENT_TIMESTAMP,
                   deposits_suspended_reason = 'Suspension automatica: 3 strikes por disputa de reembolso vencida.',
                   updated_at                = CURRENT_TIMESTAMP
             WHERE org_id_organization = v_org_id
               AND NVL(deposits_suspended, 0) = 0;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            NULL;
    END pr_apply_timeout_strike;

    PROCEDURE pr_open_public_dispute(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_json         json_object_t;
        v_response     json_object_t := json_object_t();
        v_data         json_object_t := json_object_t();
        v_app_id       NUMBER;
        v_org_id       NUMBER;
        v_refund_st    VARCHAR2(20);
        v_alias_at     TIMESTAMP WITH TIME ZONE;
        v_sent_at      TIMESTAMP WITH TIME ZONE;
        v_phone        VARCHAR2(40);
        v_confirm      VARCHAR2(20);
        v_force_open   NUMBER := 0;
        v_source       VARCHAR2(20);
        v_dispute_id   NUMBER;
        v_created      NUMBER := 0;
        v_due          TIMESTAMP WITH TIME ZONE;
        v_existing_st  VARCHAR2(30);
        v_whatsapp     VARCHAR2(20);
    BEGIN
        pkg_aox_util.pr_assert_rate_limit(
            pi_scope        => 'PUBLIC_REFUND_DISPUTE',
            pi_key          => TRIM(pi_public_token),
            pi_max_attempts => 5,
            pi_window_sec   => 86400
        );
        pkg_aox_util.pr_assert_rate_limit(
            pi_scope        => 'PUBLIC_REFUND_DISPUTE_IP',
            pi_key          => pkg_aox_util.fn_client_ip,
            pi_max_attempts => 20,
            pi_window_sec   => 3600
        );

        IF pi_body IS NULL OR DBMS_LOB.GETLENGTH(pi_body) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Confirma que sos el titular de la reserva.');
        END IF;
        v_json := json_object_t.parse(pi_body);
        v_confirm := fn_digits(v_json.get_string('phone_last4'));
        BEGIN
            IF v_json.get_boolean('confirm_open') THEN
                v_force_open := 1;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                v_force_open := NVL(v_json.get_number('confirm_open'), 0);
        END;

        SELECT a.id_appointment,
               a.org_id_organization,
               a.refund_status,
               a.refund_alias_submitted_at,
               a.refund_sent_at,
               c.phone_number,
               ws.public_whatsapp
          INTO v_app_id, v_org_id, v_refund_st, v_alias_at, v_sent_at, v_phone, v_whatsapp
          FROM appointment a
          JOIN customer c ON c.id_customer = a.cus_id_customer
          JOIN workspace_setting ws ON ws.org_id_organization = a.org_id_organization
         WHERE a.public_manage_token = TRIM(pi_public_token)
         FOR UPDATE OF a.refund_status;

        IF fn_phone_last4(v_phone) IS NULL OR v_confirm IS NULL OR v_confirm <> fn_phone_last4(v_phone) THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Los ultimos 4 digitos del telefono no coinciden.'
            );
        END IF;

        BEGIN
            SELECT id_dispute, dispute_status
              INTO v_dispute_id, v_existing_st
              FROM org_refund_dispute
             WHERE app_id_appointment = v_app_id;

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            v_response.put('message', 'Ya tenias una disputa abierta para este reembolso.');
            v_data.put('id_dispute', v_dispute_id);
            v_data.put('dispute_status', v_existing_st);
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                NULL;
        END;

        IF v_refund_st = 'SENT' THEN
            v_source := 'CUSTOMER_SENT';
        ELSIF v_refund_st = 'PENDING'
          AND pkg_aox_refund_claims_api.fn_is_refund_sla_breached(v_alias_at) = 1 THEN
            v_source := 'CUSTOMER_PENDING';
        ELSE
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Todavia no podes abrir una disputa para este reembolso.'
            );
        END IF;

        v_due := pkg_aox_refund_claims_api.fn_add_business_hours(CURRENT_TIMESTAMP, c_sla_business_hours);

        INSERT INTO org_refund_dispute (
            org_id_organization,
            app_id_appointment,
            dispute_source,
            dispute_status,
            proof_due_at,
            notes
        ) VALUES (
            v_org_id,
            v_app_id,
            v_source,
            'OPEN',
            v_due,
            CASE WHEN v_force_open = 1 THEN 'Cliente abrio disputa antes del plazo de espera bancaria.' ELSE NULL END
        ) RETURNING id_dispute INTO v_dispute_id;
        v_created := 1;

        pr_enqueue_notify(
            pi_org_id     => v_org_id,
            pi_dispute_id => v_dispute_id,
            pi_event      => 'DISPUTE_OPENED',
            pi_payload    => '{"appointment_id":' || v_app_id || '}'
        );

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put(
            'message',
            CASE WHEN v_created = 1
                 THEN 'Disputa abierta. El comercio tiene 48 horas habiles para adjuntar el comprobante.'
                 ELSE 'Ya tenias una disputa para este reembolso.'
            END
        );
        v_data.put('id_dispute', v_dispute_id);
        v_data.put('dispute_status', 'OPEN');
        v_data.put('proof_due_at', fn_iso_ts(v_due));
        v_data.put('notified', 1);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            ROLLBACK;
            BEGIN
                SELECT id_dispute, dispute_status
                  INTO v_dispute_id, v_existing_st
                  FROM org_refund_dispute
                 WHERE app_id_appointment = v_app_id;
                po_status_code := pkg_aox_util.c_success_ok_code;
                v_response.put('status', 'success');
                v_response.put('message', 'Ya tenias una disputa abierta para este reembolso.');
                v_data.put('id_dispute', v_dispute_id);
                v_data.put('dispute_status', v_existing_st);
                v_response.put('data', v_data);
                po_response_body := v_response.to_clob();
            EXCEPTION
                WHEN OTHERS THEN
                    pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
            END;
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
    END pr_open_public_dispute;

    PROCEDURE pr_insist_public(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response   json_object_t := json_object_t();
        v_data       json_object_t := json_object_t();
        v_app_id     NUMBER;
        v_org_id     NUMBER;
        v_dispute_id NUMBER;
        v_status     VARCHAR2(30);
        v_whatsapp   VARCHAR2(20);
    BEGIN
        pkg_aox_util.pr_assert_rate_limit(
            pi_scope        => 'PUBLIC_REFUND_INSIST',
            pi_key          => TRIM(pi_public_token),
            pi_max_attempts => 5,
            pi_window_sec   => 86400
        );

        SELECT a.id_appointment, a.org_id_organization, ws.public_whatsapp
          INTO v_app_id, v_org_id, v_whatsapp
          FROM appointment a
          JOIN workspace_setting ws ON ws.org_id_organization = a.org_id_organization
         WHERE a.public_manage_token = TRIM(pi_public_token)
         FOR UPDATE OF a.id_appointment;

        SELECT id_dispute, dispute_status
          INTO v_dispute_id, v_status
          FROM org_refund_dispute
         WHERE app_id_appointment = v_app_id
         FOR UPDATE;

        IF v_status NOT IN ('EVIDENCE_ACCEPTED', 'CUSTOMER_FOLLOW_UP') THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Todavia no hay una prueba aceptada para insistir.'
            );
        END IF;

        IF v_status = 'EVIDENCE_ACCEPTED' THEN
            UPDATE org_refund_dispute
               SET dispute_status = 'CUSTOMER_FOLLOW_UP',
                   close_reason   = 'CUSTOMER_INSISTED',
                   notes          = SUBSTR(NVL(notes || ' | ', '') || 'Cliente insiste: el dinero no aparece.', 1, 500),
                   updated_at     = CURRENT_TIMESTAMP
             WHERE id_dispute = v_dispute_id;
            pr_enqueue_notify(
                pi_org_id     => v_org_id,
                pi_dispute_id => v_dispute_id,
                pi_event      => 'CUSTOMER_INSISTED',
                pi_payload    => '{"appointment_id":' || v_app_id || '}'
            );
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Registramos que el dinero sigue sin aparecer. Contacta al comercio o a Hasel.');
        v_data.put('id_dispute', v_dispute_id);
        v_data.put('dispute_status', 'CUSTOMER_FOLLOW_UP');
        v_data.put('public_whatsapp', NVL(TRIM(v_whatsapp), ''));
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'No hay una disputa con prueba para este reembolso.',
                po_response_body => po_response_body
            );
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_insist_public;

    PROCEDURE pr_put_proof_payload(
        pi_object_key    IN VARCHAR2,
        pi_mime_type     IN VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
        v_url      VARCHAR2(1000);
    BEGIN
        IF pi_object_key IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'No hay prueba para mostrar.');
        END IF;
        v_url := pkg_aox_bucket.fn_public_object_url(pi_object_key);
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_data.put('object_key', pi_object_key);
        v_data.put('mime_type', NVL(pi_mime_type, 'application/octet-stream'));
        v_data.put('url', v_url);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    END pr_put_proof_payload;

    PROCEDURE pr_get_public_proof(
        pi_public_token  IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_app_id     NUMBER;
        v_status     VARCHAR2(30);
        v_object_key VARCHAR2(500);
        v_mime       VARCHAR2(150);
    BEGIN
        SELECT a.id_appointment
          INTO v_app_id
          FROM appointment a
         WHERE a.public_manage_token = TRIM(pi_public_token);

        SELECT d.dispute_status, e.object_key, e.mime_type
          INTO v_status, v_object_key, v_mime
          FROM org_refund_dispute d
          JOIN org_refund_dispute_evidence e ON e.id_evidence = d.current_evidence_id
         WHERE d.app_id_appointment = v_app_id;

        IF fn_viewable_status(v_status) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'La prueba todavia no esta disponible.');
        END IF;

        pr_put_proof_payload(v_object_key, v_mime, po_status_code, po_response_body);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'Prueba no encontrada.',
                po_response_body => po_response_body
            );
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_public_proof;

    FUNCTION fn_classify_refund_ocr(
        pi_ocr_clob          IN CLOB,
        pi_expected_amount   IN NUMBER,
        pi_refund_requested  IN TIMESTAMP WITH TIME ZONE,
        pi_is_image          IN BOOLEAN
    ) RETURN VARCHAR2 IS
        v_obj        json_object_t;
        v_status     VARCHAR2(30);
        v_amount     NUMBER;
        v_conf       NUMBER;
        v_dt_str     VARCHAR2(80);
        v_dt         TIMESTAMP WITH TIME ZONE;
        v_blank      VARCHAR2(10);
    BEGIN
        IF NOT pi_is_image THEN
            RETURN 'MANUAL_REVIEW';
        END IF;
        IF pi_ocr_clob IS NULL THEN
            RETURN 'TECHNICAL_FAILURE';
        END IF;

        v_obj := json_object_t.parse(pi_ocr_clob);
        v_status := LOWER(NVL(v_obj.get_string('status'), 'ok'));
        IF v_status NOT IN ('ok') THEN
            RETURN 'TECHNICAL_FAILURE';
        END IF;

        BEGIN
            v_conf := NVL(v_obj.get_number('confidence'), 0);
        EXCEPTION WHEN OTHERS THEN v_conf := 0;
        END;
        BEGIN
            v_amount := v_obj.get_number('amount');
        EXCEPTION WHEN OTHERS THEN v_amount := NULL;
        END;
        BEGIN
            v_blank := LOWER(NVL(v_obj.get_string('blank_image'), 'false'));
        EXCEPTION WHEN OTHERS THEN v_blank := 'false';
        END;
        BEGIN
            v_dt_str := TRIM(v_obj.get_string('transfer_datetime'));
        EXCEPTION WHEN OTHERS THEN v_dt_str := NULL;
        END;

        IF v_dt_str IS NOT NULL THEN
            BEGIN
                v_dt := TO_TIMESTAMP_TZ(REGEXP_REPLACE(v_dt_str, 'T', ' '), 'YYYY-MM-DD HH24:MI:SS TZH:TZM');
            EXCEPTION
                WHEN OTHERS THEN
                    BEGIN
                        v_dt := CAST(TO_TIMESTAMP(SUBSTR(v_dt_str, 1, 19), 'YYYY-MM-DD HH24:MI:SS') AS TIMESTAMP WITH TIME ZONE);
                    EXCEPTION
                        WHEN OTHERS THEN v_dt := NULL;
                    END;
            END;
        END IF;

        IF v_blank IN ('true', '1', 'yes') OR v_conf < 0.4 THEN
            RETURN 'REJECTED_DEFINITE';
        END IF;

        IF v_dt IS NOT NULL
           AND pi_refund_requested IS NOT NULL
           AND v_dt < (pi_refund_requested - NUMTODSINTERVAL(1, 'DAY')) THEN
            RETURN 'REJECTED_DEFINITE';
        END IF;

        IF v_amount IS NOT NULL AND pi_expected_amount IS NOT NULL
           AND ABS(v_amount - pi_expected_amount) <= 1 THEN
            RETURN 'ACCEPTED';
        END IF;

        IF v_amount IS NOT NULL AND pi_expected_amount IS NOT NULL
           AND ABS(v_amount - pi_expected_amount) > 1 THEN
            IF v_conf >= 0.7 THEN
                RETURN 'REJECTED_DEFINITE';
            END IF;
            RETURN 'MANUAL_REVIEW';
        END IF;

        RETURN 'MANUAL_REVIEW';
    EXCEPTION
        WHEN OTHERS THEN
            RETURN 'TECHNICAL_FAILURE';
    END fn_classify_refund_ocr;

    PROCEDURE pr_upload_staff_proof(
        pi_auth_header     IN  VARCHAR2,
        pi_transaction_id  IN  NUMBER,
        pi_body            IN  CLOB,
        pi_idempotency_key IN VARCHAR2 DEFAULT NULL,
        po_status_code     OUT NUMBER,
        po_response_body   OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_user_id       NUMBER;
        v_role_id       NUMBER;
        v_app_id        NUMBER;
        v_cus_id        NUMBER;
        v_refund_amt    NUMBER;
        v_refund_alias  VARCHAR2(100);
        v_requested_at  TIMESTAMP WITH TIME ZONE;
        v_dispute_id    NUMBER;
        v_disp_status   VARCHAR2(30);
        v_json          json_object_t;
        v_base64        CLOB;
        v_filename      VARCHAR2(255);
        v_mime          VARCHAR2(150);
        v_blob          BLOB;
        v_url           VARCHAR2(1000);
        v_object_key    VARCHAR2(500);
        v_sha           VARCHAR2(64);
        v_size          NUMBER;
        v_attempt       NUMBER;
        v_ev_id         NUMBER;
        v_ocr_clob      CLOB;
        v_ocr_status    VARCHAR2(30);
        v_ocr_amount    NUMBER;
        v_ocr_alias     VARCHAR2(200);
        v_ocr_conf      NUMBER;
        v_ocr_obj       json_object_t;
        v_is_image      BOOLEAN;
        v_max_bytes     NUMBER;
        v_max_b64_len   NUMBER;
        v_idem_key      VARCHAR2(255) := TRIM(pi_idempotency_key);
        v_idem_hash     VARCHAR2(64);
        v_idem_outcome  VARCHAR2(20);
        v_idem_status   NUMBER;
        v_idem_payload  CLOB;
        v_response      json_object_t := json_object_t();
        v_data          json_object_t := json_object_t();
        v_msg           VARCHAR2(400);
    BEGIN
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        IF v_role_id NOT IN (pkg_aox_util.fn_rol('ADMIN'), pkg_aox_util.fn_rol('RECEPCIONISTA')) THEN
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

        pkg_aox_util.pr_assert_rate_limit(
            pi_scope        => 'STAFF_REFUND_PROOF',
            pi_key          => TO_CHAR(v_org_id) || ':' || TO_CHAR(v_user_id),
            pi_max_attempts => 20,
            pi_window_sec   => 3600
        );

        IF pi_body IS NULL OR DBMS_LOB.GETLENGTH(pi_body) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Debes enviar el comprobante.');
        END IF;
        v_json := json_object_t.parse(pi_body);
        v_base64 := v_json.get_clob('file_base64');
        v_filename := TRIM(v_json.get_string('filename'));
        v_mime := LOWER(TRIM(NVL(v_json.get_string('mime_type'), 'application/octet-stream')));
        IF v_base64 IS NULL OR DBMS_LOB.GETLENGTH(v_base64) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El comprobante esta vacio.');
        END IF;

        v_max_bytes := pkg_aox_util.fn_param_number('RECEIPT_MAX_BYTES', 8388608);
        v_max_b64_len := CEIL(v_max_bytes / 3) * 4 + 4;
        IF DBMS_LOB.GETLENGTH(v_base64) > v_max_b64_len THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'El comprobante supera el tamano maximo permitido.'
            );
        END IF;

        IF v_idem_key IS NOT NULL THEN
            v_idem_hash := RAWTOHEX(DBMS_CRYPTO.HASH(
                UTL_I18N.STRING_TO_RAW(
                    TO_CHAR(pi_transaction_id) || '|' || NVL(v_filename, '') || '|' || v_mime || '|' ||
                    TO_CHAR(DBMS_LOB.GETLENGTH(v_base64)),
                    'AL32UTF8'
                ),
                DBMS_CRYPTO.HASH_SH256
            ));
            pkg_aox_util.pr_idempotency_begin(
                pi_scope            => 'STAFF_REFUND_PROOF',
                pi_key              => v_idem_key,
                pi_request_hash     => v_idem_hash,
                po_outcome          => v_idem_outcome,
                po_response_status  => v_idem_status,
                po_response_payload => v_idem_payload
            );
            IF v_idem_outcome = 'REPLAY' THEN
                po_status_code := v_idem_status;
                po_response_body := v_idem_payload;
                RETURN;
            ELSIF v_idem_outcome = 'IN_PROGRESS' THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                pkg_aox_util.pr_build_api_error_response(
                    pi_status_code   => po_status_code,
                    pi_api_code      => pkg_aox_util.c_api_code_idempotency_progress,
                    pi_message       => 'Ya hay una subida en curso para este comprobante.',
                    po_response_body => po_response_body
                );
                RETURN;
            ELSIF v_idem_outcome = 'CONFLICT' THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                pkg_aox_util.pr_build_api_error_response(
                    pi_status_code   => po_status_code,
                    pi_api_code      => pkg_aox_util.c_api_code_idempotency_conflict,
                    pi_message       => 'La clave de idempotencia ya fue usada con otro archivo.',
                    po_response_body => po_response_body
                );
                RETURN;
            END IF;
        END IF;

        SELECT pt.app_id_appointment,
               a.cus_id_customer,
               a.refund_amount,
               a.refund_alias,
               a.refund_requested_at
          INTO v_app_id, v_cus_id, v_refund_amt, v_refund_alias, v_requested_at
          FROM payment_transaction pt
          JOIN appointment a ON a.id_appointment = pt.app_id_appointment
         WHERE pt.id_transaction = pi_transaction_id
           AND pt.org_id_organization = v_org_id
           AND pt.provider = 'sipap'
         FOR UPDATE OF a.refund_status;

        SELECT id_dispute, dispute_status
          INTO v_dispute_id, v_disp_status
          FROM org_refund_dispute
         WHERE app_id_appointment = v_app_id
         FOR UPDATE;

        IF v_disp_status NOT IN ('OPEN', 'EVIDENCE_PROCESSING') THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Esta disputa ya no acepta una nueva prueba.'
            );
        END IF;

        UPDATE org_refund_dispute
           SET dispute_status = 'EVIDENCE_PROCESSING',
               updated_at     = CURRENT_TIMESTAMP
         WHERE id_dispute = v_dispute_id;

        v_blob := apex_web_service.clobbase642blob(v_base64);
        v_size := DBMS_LOB.GETLENGTH(v_blob);
        v_sha := RAWTOHEX(DBMS_CRYPTO.HASH(v_blob, DBMS_CRYPTO.HASH_SH256));

        SELECT NVL(MAX(attempt_n), 0) + 1
          INTO v_attempt
          FROM org_refund_dispute_evidence
         WHERE dispute_id = v_dispute_id;

        pkg_aox_bucket.pr_upload_refund_proof(
            pi_blob        => v_blob,
            pi_filename    => NVL(v_filename, 'reembolso'),
            pi_mime_type   => v_mime,
            pi_org_id      => v_org_id,
            pi_customer_id => v_cus_id,
            po_url         => v_url,
            po_object_key  => v_object_key,
            po_mime_type   => v_mime
        );

        INSERT INTO org_refund_dispute_evidence (
            dispute_id, attempt_n, object_key, mime_type, size_bytes, sha256,
            uploaded_by, ocr_status, extractor_version
        ) VALUES (
            v_dispute_id, v_attempt, v_object_key, v_mime, v_size, v_sha,
            v_user_id, 'PROCESSING', c_extractor_version
        ) RETURNING id_evidence INTO v_ev_id;

        UPDATE org_refund_dispute
           SET current_evidence_id = v_ev_id,
               updated_at          = CURRENT_TIMESTAMP
         WHERE id_dispute = v_dispute_id;

        v_is_image := v_mime LIKE 'image/%';
        IF v_is_image THEN
            v_ocr_clob := pkg_aox_ia_manager.fn_extract_refund_proof(
                pi_image_url    => v_url,
                pi_expected_amt => v_refund_amt,
                pi_expected_alias => v_refund_alias,
                pi_org_id       => v_org_id
            );
            BEGIN
                v_ocr_obj := json_object_t.parse(v_ocr_clob);
                v_ocr_amount := v_ocr_obj.get_number('amount');
            EXCEPTION WHEN OTHERS THEN v_ocr_amount := NULL;
            END;
            BEGIN
                v_ocr_alias := SUBSTR(v_ocr_obj.get_string('alias_hint'), 1, 200);
            EXCEPTION WHEN OTHERS THEN v_ocr_alias := NULL;
            END;
            BEGIN
                v_ocr_conf := NVL(v_ocr_obj.get_number('confidence'), 0);
            EXCEPTION WHEN OTHERS THEN v_ocr_conf := 0;
            END;
        ELSE
            v_ocr_clob := NULL;
            v_ocr_conf := 0;
        END IF;

        v_ocr_status := fn_classify_refund_ocr(v_ocr_clob, v_refund_amt, v_requested_at, v_is_image);

        UPDATE org_refund_dispute_evidence
           SET ocr_status     = v_ocr_status,
               ocr_amount     = v_ocr_amount,
               ocr_alias_hint = v_ocr_alias,
               ocr_confidence = v_ocr_conf,
               ocr_raw        = v_ocr_clob,
               ocr_checked_at = CURRENT_TIMESTAMP
         WHERE id_evidence = v_ev_id;

        IF v_ocr_status = 'ACCEPTED' THEN
            UPDATE org_refund_dispute
               SET dispute_status = 'EVIDENCE_ACCEPTED',
                   close_reason   = 'PROOF_OK',
                   closed_at      = CURRENT_TIMESTAMP,
                   closed_by      = v_user_id,
                   updated_at     = CURRENT_TIMESTAMP
             WHERE id_dispute = v_dispute_id;
            v_msg := 'Comprobante aceptado. El cliente ya puede ver la prueba.';
        ELSIF v_ocr_status = 'TECHNICAL_FAILURE' THEN
            UPDATE org_refund_dispute
               SET dispute_status = 'OPEN',
                   updated_at     = CURRENT_TIMESTAMP
             WHERE id_dispute = v_dispute_id;
            v_msg := 'No pudimos leer el archivo. Intenta de nuevo antes del vencimiento. No cuenta como strike.';
        ELSIF v_ocr_status = 'REJECTED_DEFINITE' THEN
            UPDATE org_refund_dispute
               SET dispute_status = 'OPEN',
                   updated_at     = CURRENT_TIMESTAMP
             WHERE id_dispute = v_dispute_id;
            v_msg := 'El comprobante no se pudo validar. Subi otra foto antes del vencimiento.';
        ELSE
            UPDATE org_refund_dispute
               SET dispute_status = 'OPEN',
                   updated_at     = CURRENT_TIMESTAMP
             WHERE id_dispute = v_dispute_id;
            v_msg := 'Comprobante recibido. Quedo en revision; no genera strike.';
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', v_msg);
        v_data.put('id_transaction', pi_transaction_id);
        v_data.put('id_dispute', v_dispute_id);
        v_data.put('id_evidence', v_ev_id);
        v_data.put('ocr_status', v_ocr_status);
        v_data.put('dispute_status', CASE WHEN v_ocr_status = 'ACCEPTED' THEN 'EVIDENCE_ACCEPTED' ELSE 'OPEN' END);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();

        IF v_idem_key IS NOT NULL THEN
            pkg_aox_util.pr_idempotency_complete(
                pi_scope           => 'STAFF_REFUND_PROOF',
                pi_key             => v_idem_key,
                pi_response_status => po_status_code,
                pi_response_payload => po_response_body
            );
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            IF v_idem_key IS NOT NULL THEN
                pkg_aox_util.pr_idempotency_release('STAFF_REFUND_PROOF', v_idem_key);
            END IF;
            RAISE_APPLICATION_ERROR(-20004, 'Disputa o cobro no encontrado.');
        WHEN OTHERS THEN
            ROLLBACK;
            IF v_idem_key IS NOT NULL THEN
                pkg_aox_util.pr_idempotency_release('STAFF_REFUND_PROOF', v_idem_key);
            END IF;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_upload_staff_proof;

    PROCEDURE pr_get_staff_proof(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_org_id     NUMBER;
        v_role_id    NUMBER;
        v_app_id     NUMBER;
        v_status     VARCHAR2(30);
        v_object_key VARCHAR2(500);
        v_mime       VARCHAR2(150);
    BEGIN
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        IF v_role_id NOT IN (pkg_aox_util.fn_rol('ADMIN'), pkg_aox_util.fn_rol('RECEPCIONISTA')) THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        SELECT pt.app_id_appointment
          INTO v_app_id
          FROM payment_transaction pt
         WHERE pt.id_transaction = pi_transaction_id
           AND pt.org_id_organization = v_org_id
           AND pt.provider = 'sipap';

        SELECT d.dispute_status, e.object_key, e.mime_type
          INTO v_status, v_object_key, v_mime
          FROM org_refund_dispute d
          JOIN org_refund_dispute_evidence e ON e.id_evidence = d.current_evidence_id
         WHERE d.app_id_appointment = v_app_id
           AND d.org_id_organization = v_org_id;

        pr_put_proof_payload(v_object_key, v_mime, po_status_code, po_response_body);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'Prueba de reembolso no encontrada.',
                po_response_body => po_response_body
            );
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_staff_proof;

    PROCEDURE pr_process_dispute_timeouts(
        pi_batch_size IN NUMBER DEFAULT 100
    ) IS
        v_limit NUMBER := LEAST(GREATEST(NVL(pi_batch_size, 100), 1), 500);
    BEGIN
        FOR rec IN (
            SELECT /*+ no_parallel */ d.id_dispute
              FROM org_refund_dispute d
             WHERE d.dispute_status IN ('OPEN', 'EVIDENCE_PROCESSING')
               AND d.proof_due_at < CURRENT_TIMESTAMP
             ORDER BY d.proof_due_at
             FETCH FIRST v_limit ROWS ONLY
        ) LOOP
            BEGIN
                pr_apply_timeout_strike(rec.id_dispute);
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    ROLLBACK;
            END;
        END LOOP;
    END pr_process_dispute_timeouts;

    PROCEDURE pr_process_notify_outbox(
        pi_batch_size IN NUMBER DEFAULT 50
    ) IS
        v_limit   NUMBER := LEAST(GREATEST(NVL(pi_batch_size, 50), 1), 200);
        v_title   VARCHAR2(200);
        v_body    VARCHAR2(500);
        v_url     VARCHAR2(500);
        v_base    VARCHAR2(500);
        v_app_id  NUMBER;
    BEGIN
        v_base := RTRIM(NVL(fn_get_parameter('APP_PUBLIC_BASE_URL'), 'https://hasel.app'), '/');
        v_url := v_base || '/panel/cobros';

        FOR rec IN (
            SELECT /*+ no_parallel */
                   o.id_outbox,
                   o.org_id_organization,
                   o.dispute_id,
                   o.event_code,
                   o.payload,
                   o.attempts
              FROM org_refund_notify_outbox o
             WHERE o.status IN ('PENDING', 'PROCESSING')
               AND o.attempts < 8
             ORDER BY o.created_at
             FETCH FIRST v_limit ROWS ONLY
             FOR UPDATE SKIP LOCKED
        ) LOOP
            UPDATE org_refund_notify_outbox
               SET status = 'PROCESSING',
                   attempts = rec.attempts + 1
             WHERE id_outbox = rec.id_outbox;

            BEGIN
                BEGIN
                    v_app_id := json_object_t.parse(rec.payload).get_number('appointment_id');
                EXCEPTION
                    WHEN OTHERS THEN v_app_id := NULL;
                END;

                IF rec.event_code = 'DISPUTE_OPENED' THEN
                    v_title := 'Disputa de reembolso';
                    v_body := 'Un cliente abrio una disputa. Adjunta el comprobante de transferencia en 48 horas habiles.';
                ELSE
                    v_title := 'Cliente insiste con el reembolso';
                    v_body := 'El cliente indica que el dinero sigue sin aparecer. Revisalo en Cobros.';
                END IF;

                FOR staff IN (
                    SELECT m.id_org_member
                      FROM org_member m
                     WHERE m.org_id_organization = rec.org_id_organization
                       AND m.is_active = 1
                       AND m.rol_id_role IN (
                            pkg_aox_util.fn_rol('ADMIN'),
                            pkg_aox_util.fn_rol('RECEPCIONISTA')
                       )
                ) LOOP
                    pkg_aox_fcm_api.pr_notify_org_member(
                        pi_org_member_id  => staff.id_org_member,
                        pi_title          => v_title,
                        pi_body           => v_body,
                        pi_url            => v_url,
                        pi_process_name   => 'PKG_AOX_REFUND_DISPUTES_API.NOTIFY',
                        pi_ntype          => 'PAYMENT',
                        pi_appointment_id => v_app_id,
                        pi_dedupe_key     => 'refund-dispute:' || rec.dispute_id || ':' || rec.event_code || ':' || staff.id_org_member
                    );
                END LOOP;

                UPDATE org_refund_notify_outbox
                   SET status = 'DONE',
                       processed_at = CURRENT_TIMESTAMP,
                       last_error = NULL
                 WHERE id_outbox = rec.id_outbox;
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    DECLARE
                        v_err VARCHAR2(400) := SUBSTR(SQLERRM, 1, 400);
                    BEGIN
                        UPDATE org_refund_notify_outbox
                           SET status = CASE WHEN rec.attempts + 1 >= 8 THEN 'FAILED' ELSE 'PENDING' END,
                               last_error = v_err
                         WHERE id_outbox = rec.id_outbox;
                        COMMIT;
                    END;
            END;
        END LOOP;
    END pr_process_notify_outbox;

    PROCEDURE pr_dismiss_for_appointment(
        pi_app_id  IN NUMBER,
        pi_user_id IN NUMBER,
        pi_reason  IN VARCHAR2
    ) IS
    BEGIN
        UPDATE org_refund_dispute
           SET dispute_status = 'DISMISSED',
               close_reason   = 'WAIVED',
               closed_at      = CURRENT_TIMESTAMP,
               closed_by      = pi_user_id,
               notes          = SUBSTR(NVL(notes || ' | ', '') || 'WAIVED: ' || pi_reason, 1, 500),
               updated_at     = CURRENT_TIMESTAMP
         WHERE app_id_appointment = pi_app_id
           AND dispute_status IN ('OPEN', 'EVIDENCE_PROCESSING');
    END pr_dismiss_for_appointment;

END pkg_aox_refund_disputes_api;
/
