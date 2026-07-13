PROMPT CREATE OR REPLACE PACKAGE pkg_aox_payments_api
CREATE OR REPLACE PACKAGE pkg_aox_payments_api IS

    -- Lista de cobros SIPAP (filtros status + fechas). Gate DEPOSIT_COLLECTION.
    PROCEDURE pr_list_payments(
        pi_auth_header   IN  VARCHAR2,
        pi_status_filter IN  VARCHAR2 DEFAULT 'all',
        pi_date_preset   IN  VARCHAR2 DEFAULT 'this_month',
        pi_date_from     IN  VARCHAR2 DEFAULT NULL,
        pi_date_to       IN  VARCHAR2 DEFAULT NULL,
        pi_page          IN  NUMBER   DEFAULT 1,
        pi_limit         IN  NUMBER   DEFAULT 50,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Count para badge del menu Cobros.
    PROCEDURE pr_pending_count(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Aprobar seña manualmente (staff).
    PROCEDURE pr_approve_payment(
        pi_auth_header   IN  VARCHAR2,
        pi_transaction_id IN NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Rechazar comprobante (motivo opcional). Hold sigue PENDING para re-subir.
    PROCEDURE pr_reject_payment(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        pi_body           IN  CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );

    -- Fase C: marcar reembolso como enviado (PENDING -> SENT).
    PROCEDURE pr_mark_refund_sent(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );

    -- Job: expira holds SIPAP (y legacy Pagopar) con payment_expires_at vencido.
    PROCEDURE pr_expire_pending_payments;

    -- Fase D: renunciar reembolso (WAIVED) con motivo.
    PROCEDURE pr_waive_refund(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        pi_body           IN  CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );

END pkg_aox_payments_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_payments_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_payments_api IS

    PROCEDURE pr_assert_staff(pi_auth_header IN VARCHAR2) IS
        v_role_id NUMBER;
    BEGIN
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        IF v_role_id NOT IN (
            pkg_aox_util.fn_rol('ADMIN'),
            pkg_aox_util.fn_rol('RECEPCIONISTA')
        ) THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;
    END pr_assert_staff;

    PROCEDURE pr_assert_deposit_feature(pi_org_id IN NUMBER) IS
    BEGIN
        IF pkg_aox_subscription_api.fn_org_has_feature(pi_org_id, 'DEPOSIT_COLLECTION') <> 1 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'Tu plan no incluye cobro de senas.'
            );
        END IF;
    END pr_assert_deposit_feature;

    FUNCTION fn_iso_ts(pi_ts IN TIMESTAMP WITH TIME ZONE) RETURN VARCHAR2 IS
    BEGIN
        IF pi_ts IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN TO_CHAR(pi_ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    END fn_iso_ts;

    FUNCTION fn_is_pending_review(
        pi_receipt_url   IN VARCHAR2,
        pi_ocr_status    IN VARCHAR2,
        pi_payment_status IN VARCHAR2
    ) RETURN NUMBER IS
    BEGIN
        IF pi_receipt_url IS NULL THEN
            RETURN 0;
        END IF;
        IF pi_payment_status IN ('PAID', 'PAID_TRANSFER', 'PAID_CASH', 'EXEMPT') THEN
            RETURN 0;
        END IF;
        IF NVL(pi_ocr_status, 'PENDING') IN ('PENDING', 'MISMATCH', 'MANUAL_REVIEW', 'FAILED') THEN
            RETURN 1;
        END IF;
        RETURN 0;
    END fn_is_pending_review;

    PROCEDURE pr_resolve_date_range(
        pi_date_preset IN  VARCHAR2,
        pi_date_from   IN  VARCHAR2,
        pi_date_to     IN  VARCHAR2,
        po_from        OUT TIMESTAMP WITH TIME ZONE,
        po_to          OUT TIMESTAMP WITH TIME ZONE
    ) IS
        v_preset VARCHAR2(30) := LOWER(TRIM(NVL(pi_date_preset, 'this_month')));
        v_now    TIMESTAMP WITH TIME ZONE := CURRENT_TIMESTAMP;
        v_month_start TIMESTAMP WITH TIME ZONE;
    BEGIN
        v_month_start := CAST(
            TRUNC(CAST(v_now AS TIMESTAMP), 'MM') AS TIMESTAMP WITH TIME ZONE
        );

        IF v_preset = 'last_month' THEN
            po_from := ADD_MONTHS(v_month_start, -1);
            po_to   := v_month_start - INTERVAL '1' SECOND;
        ELSIF v_preset = 'custom' THEN
            IF pi_date_from IS NOT NULL THEN
                po_from := TO_TIMESTAMP_TZ(TRIM(pi_date_from) || ' 00:00:00 +00:00', 'YYYY-MM-DD HH24:MI:SS TZH:TZM');
            ELSE
                po_from := v_month_start;
            END IF;
            IF pi_date_to IS NOT NULL THEN
                po_to := TO_TIMESTAMP_TZ(TRIM(pi_date_to) || ' 23:59:59 +00:00', 'YYYY-MM-DD HH24:MI:SS TZH:TZM');
            ELSE
                po_to := v_now;
            END IF;
        ELSE
            -- this_month (default)
            po_from := v_month_start;
            po_to   := v_now;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Rango de fechas invalido.');
    END pr_resolve_date_range;

    FUNCTION fn_build_item(
        pi_tx_id           IN NUMBER,
        pi_app_id          IN NUMBER,
        pi_start_time      IN TIMESTAMP WITH TIME ZONE,
        pi_customer_name   IN VARCHAR2,
        pi_service_name    IN VARCHAR2,
        pi_amount          IN NUMBER,
        pi_currency        IN VARCHAR2,
        pi_payment_status  IN VARCHAR2,
        pi_ocr_status      IN VARCHAR2,
        pi_payment_ref     IN VARCHAR2,
        pi_receipt_url     IN VARCHAR2,
        pi_ocr_reference   IN VARCHAR2,
        pi_ocr_amount      IN NUMBER,
        pi_ocr_confidence  IN NUMBER,
        pi_receipt_at      IN TIMESTAMP WITH TIME ZONE,
        pi_created_at      IN TIMESTAMP WITH TIME ZONE,
        pi_reject_reason   IN VARCHAR2,
        pi_refund_status   IN VARCHAR2 DEFAULT NULL,
        pi_refund_amount   IN NUMBER DEFAULT NULL,
        pi_refund_alias    IN VARCHAR2 DEFAULT NULL
    ) RETURN json_object_t IS
        v_obj json_object_t := json_object_t();
        v_ui_status VARCHAR2(30);
        v_refund_st VARCHAR2(20) := UPPER(TRIM(NVL(pi_refund_status, 'NONE')));
    BEGIN
        IF v_refund_st = 'PENDING' THEN
            v_ui_status := 'refund_pending';
        ELSIF v_refund_st = 'AWAITING_ALIAS' THEN
            v_ui_status := 'refund_awaiting_alias';
        ELSIF v_refund_st = 'SENT' THEN
            v_ui_status := 'refund_sent';
        ELSIF v_refund_st = 'WAIVED' THEN
            v_ui_status := 'refund_waived';
        ELSIF pi_payment_status IN ('PAID', 'PAID_TRANSFER') OR NVL(pi_ocr_status, 'X') = 'MATCH' THEN
            v_ui_status := 'approved';
        ELSIF fn_is_pending_review(pi_receipt_url, pi_ocr_status, pi_payment_status) = 1 THEN
            v_ui_status := 'pending';
        ELSE
            v_ui_status := 'other';
        END IF;

        v_obj.put('id_transaction', pi_tx_id);
        v_obj.put('id_appointment', pi_app_id);
        v_obj.put('start_time', fn_iso_ts(pi_start_time));
        v_obj.put('customer_name', pi_customer_name);
        v_obj.put('service_name', pi_service_name);
        v_obj.put('amount', pi_amount);
        v_obj.put('currency', NVL(pi_currency, 'PYG'));
        v_obj.put('payment_status', pi_payment_status);
        v_obj.put('ocr_status', pi_ocr_status);
        v_obj.put('ui_status', v_ui_status);
        v_obj.put('payment_reference', pi_payment_ref);
        v_obj.put('receipt_url', pi_receipt_url);
        v_obj.put('ocr_reference', pi_ocr_reference);
        IF pi_ocr_amount IS NOT NULL THEN
            v_obj.put('ocr_amount', pi_ocr_amount);
        END IF;
        IF pi_ocr_confidence IS NOT NULL THEN
            v_obj.put('ocr_confidence', pi_ocr_confidence);
        END IF;
        v_obj.put('receipt_uploaded_at', fn_iso_ts(pi_receipt_at));
        v_obj.put('created_at', fn_iso_ts(pi_created_at));
        v_obj.put('reject_reason', pi_reject_reason);
        v_obj.put('refund_status', v_refund_st);
        IF pi_refund_amount IS NOT NULL THEN
            v_obj.put('refund_amount', pi_refund_amount);
        END IF;
        v_obj.put('refund_alias', pi_refund_alias);
        RETURN v_obj;
    END fn_build_item;

    PROCEDURE pr_list_payments(
        pi_auth_header   IN  VARCHAR2,
        pi_status_filter IN  VARCHAR2 DEFAULT 'all',
        pi_date_preset   IN  VARCHAR2 DEFAULT 'this_month',
        pi_date_from     IN  VARCHAR2 DEFAULT NULL,
        pi_date_to       IN  VARCHAR2 DEFAULT NULL,
        pi_page          IN  NUMBER   DEFAULT 1,
        pi_limit         IN  NUMBER   DEFAULT 50,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_filter        VARCHAR2(30) := LOWER(TRIM(NVL(pi_status_filter, 'all')));
        v_from          TIMESTAMP WITH TIME ZONE;
        v_to            TIMESTAMP WITH TIME ZONE;
        v_page          NUMBER := GREATEST(NVL(pi_page, 1), 1);
        v_limit         NUMBER := LEAST(GREATEST(NVL(pi_limit, 50), 1), 100);
        v_offset        NUMBER;
        v_total         NUMBER := 0;
        v_items         json_array_t := json_array_t();
        v_response      json_object_t := json_object_t();
        v_meta          json_object_t := json_object_t();
        v_pending_count NUMBER := 0;
    BEGIN
        pr_assert_staff(pi_auth_header);
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;
        pr_assert_deposit_feature(v_org_id);

        pr_resolve_date_range(pi_date_preset, pi_date_from, pi_date_to, v_from, v_to);
        v_offset := (v_page - 1) * v_limit;

        -- Badge: comprobantes por revisar + reembolsos PENDING.
        SELECT /*+ no_parallel */ COUNT(*)
          INTO v_pending_count
          FROM (
            SELECT pt.id_transaction
              FROM payment_transaction pt
             WHERE pt.org_id_organization = v_org_id
               AND pt.provider = 'sipap'
               AND pt.receipt_url IS NOT NULL
               AND pt.payment_status = 'PENDING'
               AND NVL(pt.ocr_status, 'PENDING') IN ('PENDING', 'MISMATCH', 'MANUAL_REVIEW', 'FAILED')
            UNION
            SELECT pt.id_transaction
              FROM payment_transaction pt
              JOIN appointment a ON a.id_appointment = pt.app_id_appointment
             WHERE pt.org_id_organization = v_org_id
               AND pt.provider = 'sipap'
               AND a.refund_status = 'PENDING'
          );

        SELECT /*+ no_parallel */ COUNT(*)
          INTO v_total
          FROM payment_transaction pt
          JOIN appointment a ON a.id_appointment = pt.app_id_appointment
         WHERE pt.org_id_organization = v_org_id
           AND pt.provider = 'sipap'
           AND (
                (
                    v_filter = 'refunded'
                AND a.refund_status IN ('PENDING', 'SENT', 'AWAITING_ALIAS', 'WAIVED')
                AND NVL(a.refund_requested_at, NVL(pt.receipt_uploaded_at, pt.created_at)) BETWEEN v_from AND v_to
                )
             OR (
                    v_filter <> 'refunded'
                AND NVL(pt.receipt_uploaded_at, pt.created_at) BETWEEN v_from AND v_to
                AND (
                        v_filter = 'all'
                     OR (
                            v_filter = 'pending'
                        AND pt.receipt_url IS NOT NULL
                        AND pt.payment_status = 'PENDING'
                        AND NVL(pt.ocr_status, 'PENDING') IN ('PENDING', 'MISMATCH', 'MANUAL_REVIEW', 'FAILED')
                     )
                     OR (
                            v_filter = 'approved'
                        AND (
                               pt.payment_status IN ('PAID', 'PAID_TRANSFER')
                            OR NVL(pt.ocr_status, 'X') = 'MATCH'
                        )
                        AND NVL(a.refund_status, 'NONE') NOT IN ('PENDING', 'SENT', 'AWAITING_ALIAS', 'WAIVED')
                     )
                )
             )
           );

        FOR rec IN (
            SELECT /*+ no_parallel */
                   pt.id_transaction,
                   pt.app_id_appointment,
                   a.start_time,
                   c.full_name AS customer_name,
                   s.name AS service_name,
                   CASE
                       WHEN v_filter = 'refunded' AND a.refund_amount IS NOT NULL
                       THEN a.refund_amount
                       ELSE pt.amount
                   END AS amount,
                   pt.currency,
                   NVL(a.payment_status, pt.payment_status) AS payment_status,
                   pt.ocr_status,
                   pt.payment_reference,
                   pt.receipt_url,
                   pt.ocr_reference,
                   pt.ocr_amount,
                   pt.ocr_confidence,
                   pt.receipt_uploaded_at,
                   pt.created_at,
                   pt.reject_reason,
                   a.refund_status,
                   a.refund_amount,
                   a.refund_alias,
                   a.refund_alias_submitted_at,
                   NVL(a.refund_requested_at, NVL(pt.receipt_uploaded_at, pt.created_at)) AS sort_ts,
                   (SELECT COUNT(*)
                      FROM org_refund_claim c
                     WHERE c.app_id_appointment = a.id_appointment
                       AND c.claim_status = 'OPEN') AS open_claims
              FROM payment_transaction pt
              JOIN appointment a ON a.id_appointment = pt.app_id_appointment
              JOIN customer c ON c.id_customer = a.cus_id_customer
              JOIN service s ON s.id_service = a.ser_id_service
             WHERE pt.org_id_organization = v_org_id
               AND pt.provider = 'sipap'
               AND (
                    (
                        v_filter = 'refunded'
                    AND a.refund_status IN ('PENDING', 'SENT', 'AWAITING_ALIAS', 'WAIVED')
                    AND NVL(a.refund_requested_at, NVL(pt.receipt_uploaded_at, pt.created_at)) BETWEEN v_from AND v_to
                    )
                 OR (
                        v_filter <> 'refunded'
                    AND NVL(pt.receipt_uploaded_at, pt.created_at) BETWEEN v_from AND v_to
                    AND (
                            v_filter = 'all'
                         OR (
                                v_filter = 'pending'
                            AND pt.receipt_url IS NOT NULL
                            AND pt.payment_status = 'PENDING'
                            AND NVL(pt.ocr_status, 'PENDING') IN ('PENDING', 'MISMATCH', 'MANUAL_REVIEW', 'FAILED')
                         )
                         OR (
                                v_filter = 'approved'
                            AND (
                                   pt.payment_status IN ('PAID', 'PAID_TRANSFER')
                                OR NVL(pt.ocr_status, 'X') = 'MATCH'
                            )
                            AND NVL(a.refund_status, 'NONE') NOT IN ('PENDING', 'SENT', 'AWAITING_ALIAS', 'WAIVED')
                         )
                    )
                 )
               )
             ORDER BY sort_ts DESC
             OFFSET v_offset ROWS FETCH NEXT v_limit ROWS ONLY
        ) LOOP
            DECLARE
                v_item json_object_t;
            BEGIN
                v_item := fn_build_item(
                    rec.id_transaction,
                    rec.app_id_appointment,
                    rec.start_time,
                    rec.customer_name,
                    rec.service_name,
                    rec.amount,
                    rec.currency,
                    rec.payment_status,
                    rec.ocr_status,
                    rec.payment_reference,
                    rec.receipt_url,
                    rec.ocr_reference,
                    rec.ocr_amount,
                    rec.ocr_confidence,
                    rec.receipt_uploaded_at,
                    rec.created_at,
                    rec.reject_reason,
                    rec.refund_status,
                    rec.refund_amount,
                    rec.refund_alias
                );
                v_item.put('refund_claim_open', CASE WHEN rec.open_claims > 0 THEN 1 ELSE 0 END);
                IF NVL(rec.refund_status, 'NONE') = 'PENDING' THEN
                    v_item.put(
                        'refund_sla_breached',
                        pkg_aox_refund_claims_api.fn_is_refund_sla_breached(rec.refund_alias_submitted_at)
                    );
                END IF;
                IF NVL(rec.refund_status, 'NONE') = 'WAIVED' THEN
                    -- forzar chip
                    v_item.put('ui_status', 'refund_waived');
                END IF;
                v_items.append(v_item);
            END;
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data', v_items);
        v_meta.put('total', v_total);
        v_meta.put('page', v_page);
        v_meta.put('limit', v_limit);
        v_meta.put('pending_count', v_pending_count);
        v_response.put('meta', v_meta);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_payments;

    PROCEDURE pr_pending_count(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_count    NUMBER := 0;
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
    BEGIN
        pr_assert_staff(pi_auth_header);
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        -- Sin feature: badge 0 (no 403) para no romper el shell del panel.
        IF pkg_aox_subscription_api.fn_org_has_feature(v_org_id, 'DEPOSIT_COLLECTION') <> 1 THEN
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_data.put('pending_count', 0);
            v_response.put('status', 'success');
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        SELECT /*+ no_parallel */ COUNT(*)
          INTO v_count
          FROM (
            SELECT pt.id_transaction
              FROM payment_transaction pt
             WHERE pt.org_id_organization = v_org_id
               AND pt.provider = 'sipap'
               AND pt.receipt_url IS NOT NULL
               AND pt.payment_status = 'PENDING'
               AND NVL(pt.ocr_status, 'PENDING') IN ('PENDING', 'MISMATCH', 'MANUAL_REVIEW', 'FAILED')
            UNION
            SELECT pt.id_transaction
              FROM payment_transaction pt
              JOIN appointment a ON a.id_appointment = pt.app_id_appointment
             WHERE pt.org_id_organization = v_org_id
               AND pt.provider = 'sipap'
               AND a.refund_status = 'PENDING'
          );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_data.put('pending_count', v_count);
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_pending_count;

    PROCEDURE pr_approve_payment(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_user_id  NUMBER;
        v_app_id   NUMBER;
        v_pro_id   NUMBER;
        v_pay_st   VARCHAR2(20);
        v_receipt  VARCHAR2(1000);
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
    BEGIN
        pr_assert_staff(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;
        pr_assert_deposit_feature(v_org_id);
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        BEGIN
            SELECT /*+ no_parallel */
                   pt.app_id_appointment, pt.payment_status, pt.receipt_url, a.pro_id_professional
              INTO v_app_id, v_pay_st, v_receipt, v_pro_id
              FROM payment_transaction pt
              JOIN appointment a ON a.id_appointment = pt.app_id_appointment
             WHERE pt.id_transaction = pi_transaction_id
               AND pt.org_id_organization = v_org_id
               AND pt.provider = 'sipap'
             FOR UPDATE OF pt.payment_status, a.payment_status;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20004, 'Cobro no encontrado.');
        END;

        IF v_receipt IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'No hay comprobante para aprobar.');
        END IF;

        IF v_pay_st IN ('PAID', 'PAID_TRANSFER') THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Este cobro ya fue aprobado.');
        END IF;

        UPDATE payment_transaction
           SET payment_status = 'PAID',
               ocr_status     = 'MATCH',
               processed_at   = CURRENT_TIMESTAMP,
               reviewed_at    = CURRENT_TIMESTAMP,
               reviewed_by    = v_user_id,
               reject_reason  = NULL,
               ocr_checked_at = NVL(ocr_checked_at, CURRENT_TIMESTAMP)
         WHERE id_transaction = pi_transaction_id;

        UPDATE appointment
           SET payment_status = 'PAID_TRANSFER',
               status         = CASE WHEN status = 'CANCELADO' THEN status ELSE 'CONFIRMADO' END,
               paid_at        = CURRENT_TIMESTAMP,
               updated_at     = CURRENT_TIMESTAMP
         WHERE id_appointment = v_app_id
           AND org_id_organization = v_org_id;

        COMMIT;

        BEGIN
            pkg_aox_fcm_api.pr_notify_professional_appointment(
                pi_pro_id         => v_pro_id,
                pi_appointment_id => v_app_id,
                pi_title          => 'Seña aprobada',
                pi_body           => 'El comprobante SIPAP fue validado. Turno confirmado.',
                pi_process_name   => 'PKG_AOX_PAYMENTS_API.PR_APPROVE_PAYMENT.FCM_NOTIFY'
            );
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Seña aprobada. Turno confirmado.');
        v_data.put('id_transaction', pi_transaction_id);
        v_data.put('id_appointment', v_app_id);
        v_data.put('payment_status', 'PAID_TRANSFER');
        v_data.put('ocr_status', 'MATCH');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_approve_payment;

    PROCEDURE pr_reject_payment(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        pi_body           IN  CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_user_id  NUMBER;
        v_app_id   NUMBER;
        v_pay_st   VARCHAR2(20);
        v_receipt  VARCHAR2(1000);
        v_reason   VARCHAR2(400);
        v_json     json_object_t;
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
    BEGIN
        pr_assert_staff(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;
        pr_assert_deposit_feature(v_org_id);
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        IF pi_body IS NOT NULL AND DBMS_LOB.GETLENGTH(pi_body) > 0 THEN
            BEGIN
                v_json := json_object_t.parse(pi_body);
                v_reason := SUBSTR(TRIM(v_json.get_string('reason')), 1, 400);
            EXCEPTION
                WHEN OTHERS THEN
                    v_reason := NULL;
            END;
        END IF;

        BEGIN
            SELECT /*+ no_parallel */
                   pt.app_id_appointment, pt.payment_status, pt.receipt_url
              INTO v_app_id, v_pay_st, v_receipt
              FROM payment_transaction pt
             WHERE pt.id_transaction = pi_transaction_id
               AND pt.org_id_organization = v_org_id
               AND pt.provider = 'sipap'
             FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20004, 'Cobro no encontrado.');
        END;

        IF v_receipt IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'No hay comprobante para rechazar.');
        END IF;

        IF v_pay_st IN ('PAID', 'PAID_TRANSFER') THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'No se puede rechazar un cobro ya aprobado.');
        END IF;

        UPDATE payment_transaction
           SET ocr_status     = 'MISMATCH',
               reviewed_at    = CURRENT_TIMESTAMP,
               reviewed_by    = v_user_id,
               reject_reason  = v_reason,
               ocr_checked_at = CURRENT_TIMESTAMP
         WHERE id_transaction = pi_transaction_id;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Comprobante rechazado. El cliente puede subir otro si el hold sigue vigente.');
        v_data.put('id_transaction', pi_transaction_id);
        v_data.put('id_appointment', v_app_id);
        v_data.put('ocr_status', 'MISMATCH');
        v_data.put('reject_reason', v_reason);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_reject_payment;

    PROCEDURE pr_mark_refund_sent(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_user_id     NUMBER;
        v_app_id      NUMBER;
        v_refund_st   VARCHAR2(20);
        v_refund_amt  NUMBER;
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        pr_assert_staff(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;
        pr_assert_deposit_feature(v_org_id);
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        BEGIN
            SELECT /*+ no_parallel */
                   pt.app_id_appointment,
                   a.refund_status,
                   a.refund_amount
              INTO v_app_id, v_refund_st, v_refund_amt
              FROM payment_transaction pt
              JOIN appointment a ON a.id_appointment = pt.app_id_appointment
             WHERE pt.id_transaction = pi_transaction_id
               AND pt.org_id_organization = v_org_id
               AND pt.provider = 'sipap'
             FOR UPDATE OF a.refund_status;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20004, 'Cobro no encontrado.');
        END;

        IF v_refund_st = 'SENT' THEN
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            v_response.put('message', 'El reembolso ya estaba marcado como enviado.');
            v_data.put('id_transaction', pi_transaction_id);
            v_data.put('id_appointment', v_app_id);
            v_data.put('refund_status', 'SENT');
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        IF v_refund_st <> 'PENDING' THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Solo se pueden marcar reembolsos en estado pendiente.'
            );
        END IF;

        UPDATE appointment
           SET refund_status   = 'SENT',
               refund_sent_at  = CURRENT_TIMESTAMP,
               refund_marked_by = v_user_id,
               updated_at      = CURRENT_TIMESTAMP
         WHERE id_appointment = v_app_id;

        UPDATE org_refund_claim
           SET claim_status = 'RESOLVED',
               resolved_at  = CURRENT_TIMESTAMP,
               resolved_by  = v_user_id
         WHERE app_id_appointment = v_app_id
           AND claim_status = 'OPEN';

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Reembolso marcado como enviado.');
        v_data.put('id_transaction', pi_transaction_id);
        v_data.put('id_appointment', v_app_id);
        v_data.put('refund_status', 'SENT');
        IF v_refund_amt IS NOT NULL THEN
            v_data.put('refund_amount', v_refund_amt);
        END IF;
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_mark_refund_sent;

    PROCEDURE pr_waive_refund(
        pi_auth_header    IN  VARCHAR2,
        pi_transaction_id IN  NUMBER,
        pi_body           IN  CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
    BEGIN
        pkg_aox_refund_claims_api.pr_waive_refund(
            pi_auth_header    => pi_auth_header,
            pi_transaction_id => pi_transaction_id,
            pi_body           => pi_body,
            po_status_code    => po_status_code,
            po_response_body  => po_response_body
        );
    END pr_waive_refund;

    PROCEDURE pr_expire_pending_payments IS
    BEGIN
        -- Expira holds web SIPAP (reserve_for_deposit) y checkout Pagopar legacy abandonado.
        -- Requiere payment_expires_at: las citas PENDING del panel manual no lo tienen.
        FOR rec IN (
            SELECT id_appointment, org_id_organization, deposit_amount, pagopar_hash
              FROM appointment
             WHERE payment_status = 'PENDING'
               AND payment_expires_at IS NOT NULL
               AND payment_expires_at < CURRENT_TIMESTAMP
               AND status = 'PENDIENTE'
        ) LOOP
            UPDATE appointment
               SET payment_status = 'EXPIRED',
                   status = 'CANCELADO',
                   updated_at = CURRENT_TIMESTAMP
             WHERE id_appointment = rec.id_appointment
               AND payment_status = 'PENDING';

            IF SQL%ROWCOUNT > 0 THEN
                UPDATE payment_transaction
                   SET payment_status = 'EXPIRED',
                       processed_at = CURRENT_TIMESTAMP
                 WHERE app_id_appointment = rec.id_appointment
                   AND provider IN ('pagopar', 'sipap')
                   AND payment_status = 'PENDING';

                BEGIN
                    INSERT INTO payment_transaction (
                        org_id_organization, app_id_appointment, provider, external_reference,
                        id_pedido_comercio, idempotency_key, amount, payment_status,
                        payment_channel, source, processed_at
                    ) VALUES (
                        rec.org_id_organization, rec.id_appointment, 'sipap', rec.pagopar_hash,
                        'EXP-' || rec.id_appointment, 'EXPIRE:' || rec.id_appointment,
                        NVL(rec.deposit_amount, 0), 'EXPIRED', 'TRANSFER', 'EXPIRE_JOB', CURRENT_TIMESTAMP
                    );
                EXCEPTION
                    WHEN DUP_VAL_ON_INDEX THEN NULL;
                END;
            END IF;
        END LOOP;
        COMMIT;
    END pr_expire_pending_payments;

END pkg_aox_payments_api;
/
