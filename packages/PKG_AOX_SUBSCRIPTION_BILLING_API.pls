PROMPT CREATE OR REPLACE PACKAGE pkg_aox_subscription_billing_api
CREATE OR REPLACE PACKAGE pkg_aox_subscription_billing_api IS
/**
 * API comercial de suscripci?n (Fase 5): cat?logo de planes/addons,
 * checkout de suscripci?n v?a Pagopar (facturaci?n de la PLATAFORMA).
 *
 * Facturaci?n de plan/addons -> org_subscription_invoice (este package).
 * Se?as de citas -> payment_transaction v?a SIPAP (PKG_AOX_PAYMENTS_API /
 * PKG_AOX_PAYMENT_SETTINGS_API). Pagopar de se?as fue deprecado (Fase E).
 *
 * Claves Pagopar de la plataforma (Hasel cobra a la organizaci?n) en app_parameter:
 *   SUBSCRIPTION_PAGOPAR_PUBLIC_KEY / SUBSCRIPTION_PAGOPAR_PRIVATE_KEY
 * Token SHA1: pkg_aox_pagopar_api.fn_pagopar_sha1_token.
 */

    c_forma_pago_bancard CONSTANT NUMBER := 9;
    c_forma_pago_qr      CONSTANT NUMBER := 24;

    -- GET /workspace/plans  (cat?logo + snapshot de la suscripci?n actual)
    PROCEDURE pr_get_plans(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/checkout  (inicia pago Pagopar de plan o addon)
    -- pi_idempotency_key (header Idempotency-Key): evita doble cobro si el cliente reintenta
    -- la misma peticion (ver PKG_AOX_UTIL.pr_idempotency_begin).
    PROCEDURE pr_create_checkout(
        pi_auth_header      IN  VARCHAR2,
        pi_body             IN  CLOB,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
    );

    -- POST /workspace/subscription/change-plan
    -- Downgrade: agenda pending_plan hasta current_period_end (sin credito de plan).
    -- Cancelar agenda: plan_code = plan actual. Upgrade de pago: usar activate.
    -- FREE no se agenda aqui: usar pr_cancel_subscription.
    PROCEDURE pr_change_plan(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/cancel
    -- Terminar suscripcion: agenda FREE al fin de ciclo, auto_renew=0, canceled_at.
    -- Al aplicar: FREE + READ_ONLY + cancela addons sin credito.
    PROCEDURE pr_cancel_subscription(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/cancel/undo
    -- Deshace cancelacion programada (antes del period_end).
    PROCEDURE pr_undo_cancel_subscription(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/addon/cancel  (inmediato + credito por dias no usados)
    PROCEDURE pr_cancel_storage_addon(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- GET /workspace/subscription/invoice/:hash  (estado de una factura por hash Pagopar)
    PROCEDURE pr_get_invoice_by_hash(
        pi_auth_header   IN  VARCHAR2,
        pi_hash          IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- GET /workspace/subscription/invoices  (historial de facturas de la org)
    PROCEDURE pr_list_invoices(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /pagopar/subscription/webhook  (confirmaci?n Pagopar de facturaci?n de plataforma)
    PROCEDURE pr_subscription_webhook(
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    ----------------------------------------------------------------------------
    -- Pago recurrente: catastro de tarjeta (uPay) + activacion + ciclo de cobro
    -- (API Pagopar pago-recurrente/3.0 via PKG_AOX_PAGOPAR_API).
    ----------------------------------------------------------------------------

    -- POST /workspace/subscription/card/add  -> agregar-cliente + agregar-tarjeta
    -- Devuelve { id_form, iframe_url, provider } para incrustar el iframe uPay.
    PROCEDURE pr_add_card(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/card/confirm  -> confirmar-tarjeta + listar-tarjeta
    -- Persiste las tarjetas catastradas ACTIVE en org_payment_card.
    PROCEDURE pr_confirm_card(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- GET /workspace/subscription/cards  -> tarjetas persistidas de la organizacion
    PROCEDURE pr_list_cards(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- DELETE /workspace/subscription/card/:id  -> eliminar-tarjeta (Pagopar + local)
    PROCEDURE pr_delete_card(
        pi_auth_header   IN  VARCHAR2,
        pi_card_id       IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/activate  -> primer cobro recurrente con la tarjeta default
    -- pi_idempotency_key (header Idempotency-Key): evita doble cobro si el cliente reintenta
    -- la misma peticion (ver PKG_AOX_UTIL.pr_idempotency_begin).
    PROCEDURE pr_activate_subscription(
        pi_auth_header      IN  VARCHAR2,
        pi_body             IN  CLOB,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
    );

    -- Job HASEL_SUBSCRIPTION_BILLING_CYCLE: cobro mensual automatico + dunning.
    -- No expone HTTP; lo invoca DBMS_SCHEDULER (ver migracion del job, solo en produccion).
    PROCEDURE pr_run_billing_cycle;

    -- Ciclo acotado a una org (DEV / fixture E2E). Sin scheduler permanente.
    -- Bloqueo concurrente por org; registra cada corrida en aox_api_log.
    PROCEDURE pr_run_billing_cycle_for_org(pi_org_id IN NUMBER);

    -- Campanita SYSTEM: trial pronto/vencido, PAST_DUE, READ_ONLY, cobro recuperado.
    -- Idempotente por dedupe_key org+evento+periodo+member.
    PROCEDURE pr_notify_subscription_lifecycle(pi_org_id IN NUMBER);

    ----------------------------------------------------------------------------
    -- Factura electronica SIFEN (firmador esign) sobre invoices de suscripcion.
    -- Disparo interno server-to-server: sin JWT de usuario, protegido por
    -- header X-Service-Token (app_parameter ESIGN_CALLBACK_SERVICE_TOKEN).
    -- Ver aox-dev/docs (facturacion electronica) para el flujo completo.
    ----------------------------------------------------------------------------

    -- Encola emision FE (outbox) de forma atomica. Sin COMMIT ni HTTP.
    PROCEDURE pr_enqueue_einvoice_dispatch(pi_invoice_id IN NUMBER);

    -- Despacha filas PENDING/lease-expirado de subscription_einvoice_outbox (HTTP a Astro).
    -- pi_org_id NULL = global; si se informa, solo esa org (fixture E2E).
    PROCEDURE pr_dispatch_einvoice_outbox(
        pi_limit  IN NUMBER DEFAULT 20,
        pi_org_id IN NUMBER DEFAULT NULL
    );

    -- Reintenta emails de KuDE fallidos/pendientes/PENDING caducados sin reemitir FE.
    PROCEDURE pr_retry_pending_einvoice_emails(
        pi_limit  IN NUMBER DEFAULT 20,
        pi_org_id IN NUMBER DEFAULT NULL
    );

    -- POST /internal/v1/subscription-invoices/:id/einvoice
    -- Callback de Astro con el resultado de POST /v1/documents en el firmador.
    PROCEDURE pr_save_einvoice_result(
        pi_service_token IN  VARCHAR2,
        pi_invoice_id    IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- GET /internal/v1/subscription-invoices/pending-kude
    -- Invoices con FE aprobada pero KuDE aun no confirmado (para el cron de Astro).
    PROCEDURE pr_list_pending_kude(
        pi_service_token IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /internal/v1/subscription-invoices/:id/einvoice-kude
    -- Callback de Astro cuando el KuDE (PDF) ya esta listo: dispara el email con adjunto.
    PROCEDURE pr_save_einvoice_kude(
        pi_service_token IN  VARCHAR2,
        pi_invoice_id    IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_subscription_billing_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_subscription_billing_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_subscription_billing_api IS

    c_iso_fmt      CONSTANT VARCHAR2(40) := 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM';
    c_plan_premium CONSTANT VARCHAR2(30) := 'PREMIUM';
    c_plan_base    CONSTANT VARCHAR2(30) := 'BASE';
    c_plan_free    CONSTANT VARCHAR2(30) := 'FREE';

    -- Forward decls de helpers privados (usados antes de su definicion en el body).
    PROCEDURE pr_enqueue_billing_admin_notice(
        pi_org_id IN NUMBER,
        pi_event  IN VARCHAR2,
        pi_period IN VARCHAR2,
        pi_title  IN VARCHAR2,
        pi_body   IN VARCHAR2
    );
    PROCEDURE pr_notificar_emision_fe(pi_invoice_id IN NUMBER);
    PROCEDURE pr_send_einvoice_email(pi_invoice_id IN NUMBER);

    --------------------------------------------------------------------------
    -- Helpers
    --------------------------------------------------------------------------
    FUNCTION fn_ts_to_iso(pi_ts IN TIMESTAMP WITH TIME ZONE) RETURN VARCHAR2 IS
    BEGIN
        IF pi_ts IS NULL THEN RETURN NULL; END IF;
        RETURN TO_CHAR(pi_ts, c_iso_fmt);
    END fn_ts_to_iso;

    FUNCTION fn_is_forma_pago_allowed(pi_forma_pago IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN pi_forma_pago IN (c_forma_pago_bancard, c_forma_pago_qr);
    END fn_is_forma_pago_allowed;

    PROCEDURE pr_assert_admin(pi_auth_header IN VARCHAR2, po_org_id OUT NUMBER) IS
        v_role_id NUMBER;
    BEGIN
        po_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF NVL(po_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token inv?lido o sin organizaci?n asociada.');
        END IF;

        -- Solo ADMIN (role_id = 1) gestiona facturaci?n del plan.
        IF NVL(v_role_id, 0) <> 1 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Solo el administrador puede gestionar el plan y la facturaci?n.');
        END IF;
    END pr_assert_admin;

    PROCEDURE pr_get_platform_keys(
        po_public_key  OUT VARCHAR2,
        po_private_key OUT VARCHAR2
    ) IS
    BEGIN
        po_public_key  := fn_get_parameter('SUBSCRIPTION_PAGOPAR_PUBLIC_KEY');
        po_private_key := fn_get_parameter('SUBSCRIPTION_PAGOPAR_PRIVATE_KEY');

        IF po_public_key IS NULL OR TRIM(po_public_key) IS NULL
           OR po_private_key IS NULL OR TRIM(po_private_key) IS NULL THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'La facturaci?n de suscripci?n no est? configurada. Contact? a soporte de Hasel.'
            );
        END IF;
    END pr_get_platform_keys;

    --------------------------------------------------------------------------
    -- Factura electronica SIFEN (firmador esign) - helpers
    --------------------------------------------------------------------------

    FUNCTION fn_json_escape(pi_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(NVL(pi_value, ''), CHR(92), CHR(92) || CHR(92)), '"', CHR(92) || '"');
    END fn_json_escape;

    -- Digito verificador de RUC/CI paraguayo (modulo 11, pesos ciclicos 2..11),
    -- algoritmo oficial DNIT/SET (Pa_Calcular_Dv_11_A). Se usa para completar
    -- el receptor "ruc" del documento SIFEN sin pedirle el DV al usuario.
    FUNCTION fn_calcular_dv_ruc(pi_numero IN VARCHAR2) RETURN NUMBER IS
        v_digits VARCHAR2(40);
        v_total  PLS_INTEGER := 0;
        v_peso   PLS_INTEGER := 2;
        v_resto  PLS_INTEGER;
    BEGIN
        -- Solo digitos (por si viene con guion/puntos, ej. "80012345-6" o "80.012.345").
        v_digits := REGEXP_REPLACE(NVL(pi_numero, ''), '[^0-9]', '');
        IF v_digits IS NULL THEN
            RETURN NULL;
        END IF;

        FOR i IN REVERSE 1 .. LENGTH(v_digits) LOOP
            v_total := v_total + TO_NUMBER(SUBSTR(v_digits, i, 1)) * v_peso;
            v_peso  := CASE WHEN v_peso >= 11 THEN 2 ELSE v_peso + 1 END;
        END LOOP;

        v_resto := MOD(v_total, 11);
        RETURN CASE WHEN v_resto > 1 THEN 11 - v_resto ELSE 0 END;
    END fn_calcular_dv_ruc;

    -- Valida el header X-Service-Token de las llamadas internas Astro -> ORDS
    -- (sin JWT de usuario). Secreto compartido en app_parameter ESIGN_CALLBACK_SERVICE_TOKEN.
    PROCEDURE pr_assert_service_token(pi_service_token IN VARCHAR2) IS
        v_expected VARCHAR2(200);
    BEGIN
        v_expected := fn_get_parameter('ESIGN_CALLBACK_SERVICE_TOKEN');
        IF v_expected IS NULL OR TRIM(v_expected) IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Integracion de facturacion electronica no configurada.');
        END IF;
        IF pi_service_token IS NULL OR pi_service_token <> v_expected THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Token de servicio invalido.');
        END IF;
    END pr_assert_service_token;

    --------------------------------------------------------------------------
    -- Campanita SYSTEM (admins) — ciclo de suscripcion
    --------------------------------------------------------------------------
    PROCEDURE pr_enqueue_billing_admin_notice(
        pi_org_id    IN NUMBER,
        pi_event     IN VARCHAR2,
        pi_period    IN VARCHAR2,
        pi_title     IN VARCHAR2,
        pi_body      IN VARCHAR2
    ) IS
        v_admin_role NUMBER := 1;
        v_dedupe     VARCHAR2(200);
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 OR TRIM(pi_event) IS NULL THEN
            RETURN;
        END IF;

        FOR mem IN (
            SELECT id_org_member
              FROM org_member
             WHERE org_id_organization = pi_org_id
               AND is_active = 1
               AND rol_id_role = v_admin_role
        ) LOOP
            v_dedupe := SUBSTR(
                'BILLING:' || pi_org_id || ':' || UPPER(TRIM(pi_event)) || ':' ||
                NVL(TRIM(pi_period), 'NA') || ':' || mem.id_org_member,
                1, 200
            );
            pkg_aox_inbox_api.pr_enqueue(
                pi_org_id         => pi_org_id,
                pi_org_member_id  => mem.id_org_member,
                pi_ntype          => 'SYSTEM',
                pi_title          => pi_title,
                pi_body           => pi_body,
                pi_action_type    => 'OPEN_URL',
                pi_action_url     => '/panel/plan',
                pi_dedupe_key     => v_dedupe
            );
        END LOOP;
    END pr_enqueue_billing_admin_notice;

    PROCEDURE pr_notify_subscription_lifecycle(pi_org_id IN NUMBER) IS
        v_state        VARCHAR2(20);
        v_prev_status  org_subscription.status%TYPE;
        v_trial_end    TIMESTAMP WITH TIME ZONE;
        v_period_end   TIMESTAMP WITH TIME ZONE;
        v_grace_end    TIMESTAMP WITH TIME ZONE;
        v_period_key   VARCHAR2(40);
        v_now          TIMESTAMP WITH TIME ZONE := systimestamp;
        v_hours_left   NUMBER;
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 THEN
            RETURN;
        END IF;

        BEGIN
            SELECT status, trial_ends_at, current_period_end, grace_ends_at
              INTO v_prev_status, v_trial_end, v_period_end, v_grace_end
              FROM org_subscription
             WHERE org_id_organization = pi_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN;
        END;

        v_state := pkg_aox_subscription_api.fn_get_subscription_state(pi_org_id);

        -- Trial pronto a vencer (ventana 72h).
        IF v_state = 'TRIAL' AND v_trial_end IS NOT NULL THEN
            v_hours_left := (CAST(v_trial_end AS DATE) - CAST(v_now AS DATE)) * 24;
            IF v_hours_left <= 72 AND v_hours_left > 0 THEN
                v_period_key := TO_CHAR(v_trial_end AT TIME ZONE 'UTC', 'YYYYMMDD');
                pr_enqueue_billing_admin_notice(
                    pi_org_id => pi_org_id,
                    pi_event  => 'TRIAL_SOON',
                    pi_period => v_period_key,
                    pi_title  => 'Tu prueba de Hasel vence pronto',
                    pi_body   => 'Quedan menos de 3 dias de prueba. Elegi un plan para no perder el acceso.'
                );
            END IF;
        END IF;

        IF v_state = 'TRIAL_EXPIRED' THEN
            v_period_key := TO_CHAR(NVL(v_trial_end, v_now) AT TIME ZONE 'UTC', 'YYYYMMDD');
            pr_enqueue_billing_admin_notice(
                pi_org_id => pi_org_id,
                pi_event  => 'TRIAL_EXPIRED',
                pi_period => v_period_key,
                pi_title  => 'Tu prueba de Hasel venció',
                pi_body   => 'La prueba gratuita terminó. Activa un plan para seguir usando Hasel.'
            );
        ELSIF v_state = 'PAST_DUE' THEN
            v_period_key := TO_CHAR(NVL(v_period_end, v_now) AT TIME ZONE 'UTC', 'YYYYMMDD');
            pr_enqueue_billing_admin_notice(
                pi_org_id => pi_org_id,
                pi_event  => 'PAST_DUE',
                pi_period => v_period_key,
                pi_title  => 'Pago pendiente de tu suscripción',
                pi_body   => 'No pudimos cobrar el plan. Tenés unos días de gracia antes de pasar a solo lectura.'
            );
        ELSIF v_state = 'READ_ONLY' THEN
            v_period_key := TO_CHAR(NVL(v_grace_end, NVL(v_period_end, v_now)) AT TIME ZONE 'UTC', 'YYYYMMDD');
            pr_enqueue_billing_admin_notice(
                pi_org_id => pi_org_id,
                pi_event  => 'READ_ONLY',
                pi_period => v_period_key,
                pi_title  => 'Tu organización está en solo lectura',
                pi_body   => 'Se venció el periodo de gracia. Regularizá el pago para volver a editar.'
            );
        END IF;
        -- PAYMENT_RECOVERED se dispara desde pr_fulfill_paid_subscription (prev PAST_DUE).
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'SUBSCRIPTION_NOTIFY',
                pi_process_name    => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_NOTIFY_SUBSCRIPTION_LIFECYCLE',
                pi_org_id          => pi_org_id,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
    END pr_notify_subscription_lifecycle;

    -- Compat: alias interno usado por webhook/credito. Solo encola (sin COMMIT/HTTP).
    PROCEDURE pr_notificar_emision_fe(pi_invoice_id IN NUMBER) IS
    BEGIN
        pr_enqueue_einvoice_dispatch(pi_invoice_id);
    END pr_notificar_emision_fe;

    -- Encola la emision FE de forma atomica. Sin COMMIT ni llamada HTTP.
    -- Solo reclama invoices PAID en NONE/FAILED sin CDC (protege estados terminales).
    PROCEDURE pr_enqueue_einvoice_dispatch(pi_invoice_id IN NUMBER) IS
        v_org_id   NUMBER;
        v_amount   NUMBER;
        v_status   VARCHAR2(20);
        v_inv_stat VARCHAR2(20);
        v_claimed  NUMBER := 0;
    BEGIN
        BEGIN
            SELECT org_id_organization, NVL(gross_amount, amount), status, NVL(einvoice_status, 'NONE')
              INTO v_org_id, v_amount, v_inv_stat, v_status
              FROM org_subscription_invoice
             WHERE id_invoice = pi_invoice_id
             FOR UPDATE OF einvoice_status;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN;
        END;

        IF v_inv_stat <> 'PAID' OR NVL(v_amount, 0) <= 0 THEN
            RETURN;
        END IF;

        -- Ya tiene CDC o FE en curso/terminal: no re-encolar.
        IF v_status NOT IN ('NONE', 'FAILED') THEN
            RETURN;
        END IF;

        UPDATE /*+ no_parallel */ org_subscription_invoice
           SET einvoice_status = 'PENDING',
               einvoice_error  = NULL
         WHERE id_invoice = pi_invoice_id
           AND NVL(einvoice_status, 'NONE') IN ('NONE', 'FAILED')
           AND einvoice_cdc IS NULL;

        v_claimed := SQL%ROWCOUNT;
        IF v_claimed = 0 THEN
            RETURN;
        END IF;

        BEGIN
            INSERT INTO subscription_einvoice_outbox (
                invoice_id, org_id_organization, status, emission_key
            ) VALUES (
                pi_invoice_id, v_org_id, 'PENDING', 'INV-' || TO_CHAR(pi_invoice_id)
            );
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                UPDATE subscription_einvoice_outbox
                   SET status = 'PENDING',
                       attempts = 0,
                       last_error = NULL,
                       processed_at = NULL,
                       lease_owner = NULL,
                       lease_until = NULL,
                       processing_started_at = NULL,
                       emission_key = NVL(emission_key, 'INV-' || TO_CHAR(pi_invoice_id))
                 WHERE invoice_id = pi_invoice_id
                   AND status IN ('FAILED', 'DONE')
                   AND NOT EXISTS (
                       SELECT 1 FROM org_subscription_invoice i
                        WHERE i.id_invoice = pi_invoice_id
                          AND i.einvoice_cdc IS NOT NULL
                   );
        END;
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'ESIGN_EINVOICE',
                pi_process_name    => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_ENQUEUE_EINVOICE_DISPATCH',
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body    => TO_CLOB('invoice_id=' || pi_invoice_id)
            );
    END pr_enqueue_einvoice_dispatch;

    FUNCTION fn_build_einvoice_payload(pi_invoice_id IN NUMBER) RETURN CLOB IS
        v_org_id          NUMBER;
        v_desc            org_subscription_invoice.description%TYPE;
        v_amount          org_subscription_invoice.amount%TYPE;
        v_currency        org_subscription_invoice.currency%TYPE;
        v_provider        org_subscription_invoice.payment_provider%TYPE;
        v_billing_name    org_billing_profile.billing_name%TYPE;
        v_doc_type        org_billing_profile.billing_doc_type%TYPE;
        v_doc_number      org_billing_profile.billing_doc_number%TYPE;
        v_billing_email   org_billing_profile.billing_email%TYPE;
        v_establecimiento VARCHAR2(10);
        v_punto           VARCHAR2(10);
        v_emission_key    VARCHAR2(64);
        v_medio_pago      NUMBER;
        v_des_medio       VARCHAR2(60);
        v_tipo_contrib    NUMBER;
        v_payload         json_object_t := json_object_t();
        v_receptor        json_object_t := json_object_t();
        v_datos_op        json_object_t := json_object_t();
    BEGIN
        SELECT org_id_organization, description, NVL(gross_amount, amount), currency, payment_provider
          INTO v_org_id, v_desc, v_amount, v_currency, v_provider
          FROM org_subscription_invoice
         WHERE id_invoice = pi_invoice_id;

        SELECT billing_name, billing_doc_type, billing_doc_number, billing_email
          INTO v_billing_name, v_doc_type, v_doc_number, v_billing_email
          FROM org_billing_profile
         WHERE org_id_organization = v_org_id;

        IF v_doc_type IS NULL OR v_doc_number IS NULL OR v_billing_email IS NULL THEN
            RETURN NULL;
        END IF;

        BEGIN
            SELECT NVL(emission_key, 'INV-' || TO_CHAR(pi_invoice_id))
              INTO v_emission_key
              FROM subscription_einvoice_outbox
             WHERE invoice_id = pi_invoice_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_emission_key := 'INV-' || TO_CHAR(pi_invoice_id);
        END;

        v_establecimiento := NVL(fn_get_parameter('ESIGN_ESTABLECIMIENTO'), '001');
        v_punto           := NVL(fn_get_parameter('ESIGN_PUNTO_EXPEDICION'), '001');

        -- Medio de pago segun proveedor real (no forzar tarjeta en pagos por saldo).
        CASE LOWER(NVL(v_provider, ''))
            WHEN 'credit' THEN
                v_medio_pago := 13; -- Compensacion
                v_des_medio  := 'Compensación';
            WHEN 'pagopar' THEN
                v_medio_pago := 3;
                v_des_medio  := 'Tarjeta de crédito';
            WHEN 'bancard' THEN
                v_medio_pago := 3;
                v_des_medio  := 'Tarjeta de crédito';
            WHEN 'qr' THEN
                v_medio_pago := 7;
                v_des_medio  := 'Billetera electrónica';
            ELSE
                IF NVL(v_provider, '') IS NOT NULL THEN
                    v_medio_pago := 99;
                    v_des_medio  := 'Otro';
                ELSE
                    v_medio_pago := 3;
                    v_des_medio  := 'Tarjeta de crédito';
                END IF;
        END CASE;

        v_datos_op.put('establecimiento', v_establecimiento);
        v_datos_op.put('punto_expedicion', v_punto);

        v_receptor.put('tipo', LOWER(v_doc_type));
        v_receptor.put('documento', v_doc_number);
        v_receptor.put('nombre', v_billing_name);
        IF UPPER(v_doc_type) = 'RUC' THEN
            v_receptor.put('dv', fn_calcular_dv_ruc(v_doc_number));
            -- Persona juridica si el nombre sugiere razon social; si no, fisica.
            IF REGEXP_LIKE(UPPER(NVL(v_billing_name, '')),
                           '(S\.?\s*R\.?\s*L\.?)|(S\.?\s*A\.?)|EAS|LTDA|CIA\.?|COOP|SOCIEDAD') THEN
                v_tipo_contrib := 2;
            ELSE
                v_tipo_contrib := 1;
            END IF;
            v_receptor.put('tipoContribuyente', v_tipo_contrib);
            v_receptor.put('tipoOperacion', 1); -- B2B
        END IF;

        v_payload.put('invoice_id', pi_invoice_id);
        v_payload.put('emission_key', v_emission_key);
        v_payload.put('datos_operacion', v_datos_op);
        v_payload.put('receptor', v_receptor);
        v_payload.put('moneda', NVL(v_currency, 'PYG'));
        v_payload.put('descripcion', NVL(v_desc, 'Suscripcion Hasel'));
        v_payload.put('monto', v_amount);
        v_payload.put('tipoTransaccion', 2);
        v_payload.put('desTipoTransaccion', 'Prestación de servicios');
        v_payload.put('indPres', 3);
        v_payload.put('desIndPres', 'Operación electrónica (venta a distancia, internet, etc.)');
        v_payload.put('condicion', 'contado');
        v_payload.put('medioPago', v_medio_pago);
        v_payload.put('desMedioPago', v_des_medio);

        RETURN v_payload.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_build_einvoice_payload;

    PROCEDURE pr_dispatch_einvoice_outbox(
        pi_limit  IN NUMBER DEFAULT 20,
        pi_org_id IN NUMBER DEFAULT NULL
    ) IS
        v_webhook_url   VARCHAR2(500) := fn_get_parameter('ESIGN_WEBHOOK_URL');
        v_service_token VARCHAR2(200) := fn_get_parameter('ESIGN_CALLBACK_SERVICE_TOKEN');
        v_payload       CLOB;
        v_response      CLOB;
        v_status_code   NUMBER;
        v_limit         PLS_INTEGER := LEAST(GREATEST(NVL(pi_limit, 20), 1), 100);
        v_lease_minutes NUMBER := 5;
        v_max_attempts  NUMBER := 5;
        v_worker_id     VARCHAR2(64) := SUBSTR('JOB-' || TO_CHAR(systimestamp, 'YYYYMMDDHH24MISSFF') || '-' || DBMS_SESSION.UNIQUE_SESSION_ID, 1, 64);
        TYPE t_ids IS TABLE OF NUMBER;
        v_ids           t_ids;
        v_id_outbox     NUMBER;
        v_invoice_id    NUMBER;
        v_org_id        NUMBER;
        v_attempts      NUMBER;
        v_emission_key  VARCHAR2(64);
        v_cdc           VARCHAR2(44);
        v_estatus       VARCHAR2(20);
        v_resp_json     json_object_t;
        v_resp_cdc      VARCHAR2(44);
        v_resp_data     json_object_t;
        v_terminal_fail BOOLEAN;
    BEGIN
        IF v_webhook_url IS NULL OR TRIM(v_webhook_url) IS NULL
           OR v_service_token IS NULL OR TRIM(v_service_token) IS NULL THEN
            RETURN;
        END IF;

        -- Reclamo atomico: PENDING o PROCESSING con lease expirado.
        SELECT id_outbox
          BULK COLLECT INTO v_ids
          FROM subscription_einvoice_outbox
         WHERE (
                   status = 'PENDING'
                OR (status = 'PROCESSING' AND (lease_until IS NULL OR lease_until < systimestamp))
               )
           AND (pi_org_id IS NULL OR org_id_organization = pi_org_id)
           AND ROWNUM <= v_limit
         FOR UPDATE SKIP LOCKED;

        FOR i IN 1 .. v_ids.COUNT LOOP
            v_id_outbox := v_ids(i);
            v_resp_cdc := NULL;
            BEGIN
                SELECT invoice_id, org_id_organization, attempts,
                       NVL(emission_key, 'INV-' || TO_CHAR(invoice_id))
                  INTO v_invoice_id, v_org_id, v_attempts, v_emission_key
                  FROM subscription_einvoice_outbox
                 WHERE id_outbox = v_id_outbox;

                UPDATE subscription_einvoice_outbox
                   SET status = 'PROCESSING',
                       attempts = NVL(attempts, 0) + 1,
                       lease_owner = v_worker_id,
                       lease_until = systimestamp + NUMTODSINTERVAL(v_lease_minutes, 'MINUTE'),
                       processing_started_at = systimestamp,
                       emission_key = NVL(emission_key, v_emission_key)
                 WHERE id_outbox = v_id_outbox;
                COMMIT;

                SELECT einvoice_cdc, einvoice_status
                  INTO v_cdc, v_estatus
                  FROM org_subscription_invoice
                 WHERE id_invoice = v_invoice_id;

                -- Solo DONE con resultado terminal verificable en Oracle.
                IF v_cdc IS NOT NULL OR v_estatus IN ('SENT_PENDING_KUDE', 'SENT') THEN
                    UPDATE subscription_einvoice_outbox
                       SET status = 'DONE',
                           processed_at = systimestamp,
                           lease_owner = NULL,
                           lease_until = NULL,
                           last_error = NULL
                     WHERE id_outbox = v_id_outbox;
                    COMMIT;
                    CONTINUE;
                END IF;

                v_payload := fn_build_einvoice_payload(v_invoice_id);
                IF v_payload IS NULL THEN
                    UPDATE subscription_einvoice_outbox
                       SET status = 'FAILED',
                           last_error = 'Sin billing profile o datos incompletos',
                           processed_at = systimestamp,
                           lease_owner = NULL,
                           lease_until = NULL
                     WHERE id_outbox = v_id_outbox;
                    UPDATE /*+ no_parallel */ org_subscription_invoice
                       SET einvoice_status = 'FAILED',
                           einvoice_error  = 'Sin billing profile o datos incompletos'
                     WHERE id_invoice = v_invoice_id
                       AND einvoice_cdc IS NULL
                       AND NVL(einvoice_status, 'NONE') IN ('NONE', 'PENDING', 'FAILED');
                    COMMIT;
                    CONTINUE;
                END IF;

                apex_web_service.g_request_headers.delete();
                apex_web_service.g_request_headers(1).name  := 'Content-Type';
                apex_web_service.g_request_headers(1).value := 'application/json';
                apex_web_service.g_request_headers(2).name  := 'X-Service-Token';
                apex_web_service.g_request_headers(2).value := v_service_token;
                apex_web_service.g_request_headers(3).name  := 'Idempotency-Key';
                apex_web_service.g_request_headers(3).value := v_emission_key;

                v_response := apex_web_service.make_rest_request(
                    p_url         => v_webhook_url,
                    p_http_method => 'POST',
                    p_body        => v_payload
                );
                v_status_code := apex_web_service.g_status_code;

                pkg_aox_util.pr_log_api(
                    pi_api_name      => 'ESIGN_EINVOICE',
                    pi_process_name  => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_DISPATCH_EINVOICE_OUTBOX',
                    pi_http_method   => 'POST',
                    pi_endpoint      => v_webhook_url,
                    pi_org_id        => v_org_id,
                    pi_status        => CASE WHEN v_status_code BETWEEN 200 AND 299 THEN 'SUCCESS' ELSE 'ERROR' END,
                    pi_status_code   => v_status_code,
                    pi_request_body  => v_payload,
                    pi_response_body => v_response
                );

                -- Extraer CDC del body Astro si vino (no confiar solo en HTTP 200).
                BEGIN
                    v_resp_json := json_object_t.parse(v_response);
                    IF v_resp_json.has('data') AND NOT v_resp_json.get('data').is_null THEN
                        v_resp_data := TREAT(v_resp_json.get('data') AS json_object_t);
                        v_resp_cdc := v_resp_data.get_string('cdc');
                    END IF;
                    IF v_resp_cdc IS NULL AND v_resp_json.has('cdc') THEN
                        v_resp_cdc := v_resp_json.get_string('cdc');
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        v_resp_cdc := NULL;
                END;

                IF v_resp_cdc IS NOT NULL THEN
                    -- Persistencia best-effort si el callback ORDS aun no corrio.
                    UPDATE /*+ no_parallel */ org_subscription_invoice
                       SET einvoice_cdc    = NVL(einvoice_cdc, v_resp_cdc),
                           einvoice_status = CASE
                                               WHEN einvoice_status IN ('SENT_PENDING_KUDE', 'SENT') THEN einvoice_status
                                               ELSE 'SENT_PENDING_KUDE'
                                             END,
                           einvoice_error  = NULL
                     WHERE id_invoice = v_invoice_id
                       AND (einvoice_cdc IS NULL OR einvoice_cdc = v_resp_cdc);

                    UPDATE subscription_einvoice_outbox
                       SET status = 'DONE',
                           processed_at = systimestamp,
                           last_error = NULL,
                           lease_owner = NULL,
                           lease_until = NULL
                     WHERE id_outbox = v_id_outbox;
                ELSIF v_status_code BETWEEN 200 AND 299 THEN
                    -- 2xx sin CDC: NO cerrar DONE (evita PENDING muerto). Reintento con lease.
                    UPDATE subscription_einvoice_outbox
                       SET status = 'PENDING',
                           last_error = SUBSTR('HTTP ' || v_status_code || ' sin CDC verificable', 1, 500),
                           lease_owner = NULL,
                           lease_until = NULL,
                           processed_at = NULL
                     WHERE id_outbox = v_id_outbox;
                ELSE
                    v_terminal_fail := (NVL(v_attempts, 0) + 1 >= v_max_attempts)
                                       OR (v_status_code BETWEEN 400 AND 499
                                           AND v_status_code NOT IN (408, 429));
                    IF v_terminal_fail THEN
                        UPDATE subscription_einvoice_outbox
                           SET status = 'FAILED',
                               last_error = SUBSTR('HTTP ' || v_status_code, 1, 500),
                               processed_at = systimestamp,
                               lease_owner = NULL,
                               lease_until = NULL
                         WHERE id_outbox = v_id_outbox;
                        UPDATE /*+ no_parallel */ org_subscription_invoice
                           SET einvoice_status = 'FAILED',
                               einvoice_error  = SUBSTR('HTTP ' || v_status_code || ' emision FE', 1, 500)
                         WHERE id_invoice = v_invoice_id
                           AND einvoice_cdc IS NULL
                           AND NVL(einvoice_status, 'NONE') IN ('NONE', 'PENDING', 'FAILED');
                    ELSE
                        UPDATE subscription_einvoice_outbox
                           SET status = 'PENDING',
                               last_error = SUBSTR('HTTP ' || v_status_code, 1, 500),
                               lease_owner = NULL,
                               lease_until = NULL,
                               processed_at = NULL
                         WHERE id_outbox = v_id_outbox;
                    END IF;
                END IF;
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    DECLARE
                        v_err VARCHAR2(500) := SUBSTR(SQLERRM, 1, 500);
                    BEGIN
                        ROLLBACK;
                        IF NVL(v_attempts, 0) + 1 >= v_max_attempts THEN
                            UPDATE subscription_einvoice_outbox
                               SET status = 'FAILED',
                                   last_error = v_err,
                                   processed_at = systimestamp,
                                   lease_owner = NULL,
                                   lease_until = NULL
                             WHERE id_outbox = v_id_outbox;
                            UPDATE /*+ no_parallel */ org_subscription_invoice
                               SET einvoice_status = 'FAILED',
                                   einvoice_error  = v_err
                             WHERE id_invoice = v_invoice_id
                               AND einvoice_cdc IS NULL
                               AND NVL(einvoice_status, 'NONE') IN ('NONE', 'PENDING', 'FAILED');
                        ELSE
                            UPDATE subscription_einvoice_outbox
                               SET status = 'PENDING',
                                   last_error = v_err,
                                   lease_owner = NULL,
                                   lease_until = NULL
                             WHERE id_outbox = v_id_outbox;
                        END IF;
                        COMMIT;
                        pkg_aox_util.pr_log_api(
                            pi_api_name        => 'ESIGN_EINVOICE',
                            pi_process_name    => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_DISPATCH_EINVOICE_OUTBOX',
                            pi_org_id          => v_org_id,
                            pi_status          => 'ERROR',
                            pi_error_code      => SQLCODE,
                            pi_error_message   => v_err,
                            pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                            pi_request_body    => TO_CLOB('invoice_id=' || v_invoice_id)
                        );
                    END;
            END;
        END LOOP;
    END pr_dispatch_einvoice_outbox;

    -- Baja el KuDE (PDF) y manda mail FACTURASUSCRIPCIONV2. Fallo de email NO marca FE como FAILED.
    PROCEDURE pr_send_einvoice_email(pi_invoice_id IN NUMBER) IS
        v_org_id         NUMBER;
        v_cdc            org_subscription_invoice.einvoice_cdc%TYPE;
        v_kude_url       org_subscription_invoice.einvoice_kude_url%TYPE;
        v_email_status   VARCHAR2(20);
        v_billing_name   org_billing_profile.billing_name%TYPE;
        v_billing_email  org_billing_profile.billing_email%TYPE;
        v_pdf_blob       BLOB;
        v_mail_id        NUMBER;
        v_apex_session_created BOOLEAN := FALSE;
        v_error_message  VARCHAR2(4000);
        v_claimed        NUMBER := 0;
    BEGIN
        -- Claim atomico: evita emails duplicados en reintentos concurrentes.
        -- PENDING caducado se recupera via pr_retry_pending_einvoice_emails (reset a FAILED).
        UPDATE /*+ no_parallel */ org_subscription_invoice
           SET einvoice_email_status = 'PENDING',
               einvoice_email_attempts = NVL(einvoice_email_attempts, 0) + 1,
               einvoice_email_error = NULL
         WHERE id_invoice = pi_invoice_id
           AND einvoice_kude_url IS NOT NULL
           AND einvoice_cdc IS NOT NULL
           AND NVL(einvoice_email_status, 'NONE') IN ('NONE', 'FAILED')
           AND einvoice_sent_at IS NULL;

        v_claimed := SQL%ROWCOUNT;
        IF v_claimed = 0 THEN
            RETURN;
        END IF;
        COMMIT;

        SELECT i.org_id_organization, i.einvoice_cdc, i.einvoice_kude_url,
               NVL(i.einvoice_email_status, 'NONE'),
               p.billing_name, p.billing_email
          INTO v_org_id, v_cdc, v_kude_url, v_email_status,
               v_billing_name, v_billing_email
          FROM org_subscription_invoice i
          JOIN org_billing_profile p ON p.org_id_organization = i.org_id_organization
         WHERE i.id_invoice = pi_invoice_id;

        IF v_kude_url IS NULL OR v_billing_email IS NULL THEN
            RETURN;
        END IF;

        apex_web_service.g_request_headers.delete();
        v_pdf_blob := apex_web_service.make_rest_request_b(
            p_url         => v_kude_url,
            p_http_method => 'GET'
        );

        IF apex_web_service.g_status_code NOT BETWEEN 200 AND 299
           OR v_pdf_blob IS NULL OR DBMS_LOB.GETLENGTH(v_pdf_blob) = 0 THEN
            RAISE_APPLICATION_ERROR(-20090, 'No se pudo descargar el KuDE (' || apex_web_service.g_status_code || ').');
        END IF;

        apex_session.create_session(
            p_app_id   => 100,
            p_page_id  => 1,
            p_username => 'AOX'
        );
        v_apex_session_created := TRUE;

        v_mail_id := apex_mail.send(
            p_to                 => TRIM(v_billing_email),
            p_from               => NVL(fn_get_parameter('MAIL_FROM_ADDRESS'), 'noreply@hasel.app'),
            p_template_static_id => 'FACTURASUSCRIPCIONV2',
            p_placeholders       => '{' ||
                                    '"NOMBRE": "' || fn_json_escape(v_billing_name) || '",' ||
                                    '"CDC": "' || fn_json_escape(v_cdc) || '"' ||
                                    '}'
        );

        apex_mail.add_attachment(
            p_mail_id     => v_mail_id,
            p_attachment  => v_pdf_blob,
            p_filename    => 'factura-' || v_cdc || '.pdf',
            p_mime_type   => 'application/pdf'
        );

        apex_mail.push_queue;

        UPDATE /*+ no_parallel */ org_subscription_invoice
           SET einvoice_status       = 'SENT',
               einvoice_sent_at      = systimestamp,
               einvoice_email_status = 'SENT',
               einvoice_email_error  = NULL
         WHERE id_invoice = pi_invoice_id;
        COMMIT;

        apex_session.delete_session;
    EXCEPTION
        WHEN OTHERS THEN
            v_error_message := SQLERRM;
            IF v_apex_session_created THEN
                BEGIN
                    apex_session.delete_session;
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
            END IF;
            -- Fallo de email: NO tocar einvoice_status FE/KuDE ni permitir nueva emision.
            UPDATE /*+ no_parallel */ org_subscription_invoice
               SET einvoice_email_status = 'FAILED',
                   einvoice_email_error  = SUBSTR(v_error_message, 1, 500)
             WHERE id_invoice = pi_invoice_id
               AND NVL(einvoice_email_status, 'NONE') <> 'SENT';
            COMMIT;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'ESIGN_EINVOICE',
                pi_process_name    => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_SEND_EINVOICE_EMAIL',
                pi_org_id          => v_org_id,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => v_error_message,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_request_body    => TO_CLOB('invoice_id=' || pi_invoice_id)
            );
    END pr_send_einvoice_email;

    PROCEDURE pr_retry_pending_einvoice_emails(
        pi_limit  IN NUMBER DEFAULT 20,
        pi_org_id IN NUMBER DEFAULT NULL
    ) IS
        v_limit PLS_INTEGER := LEAST(GREATEST(NVL(pi_limit, 20), 1), 100);
        v_max_attempts NUMBER := 5;
    BEGIN
        -- Recuperar PENDING abandonados (crash entre claim y SENT) sin reabrir FE.
        UPDATE /*+ no_parallel */ org_subscription_invoice
           SET einvoice_email_status = 'FAILED',
               einvoice_email_error  = NVL(einvoice_email_error, 'PENDING caducado; reintento automatico')
         WHERE einvoice_email_status = 'PENDING'
           AND einvoice_sent_at IS NULL
           AND einvoice_cdc IS NOT NULL
           AND einvoice_kude_url IS NOT NULL
           AND NVL(einvoice_email_attempts, 0) >= 1
           AND (pi_org_id IS NULL OR org_id_organization = pi_org_id);

        FOR rec IN (
            SELECT id_invoice
              FROM org_subscription_invoice
             WHERE einvoice_kude_url IS NOT NULL
               AND einvoice_cdc IS NOT NULL
               AND einvoice_sent_at IS NULL
               AND NVL(einvoice_email_status, 'NONE') IN ('NONE', 'FAILED')
               AND NVL(einvoice_email_attempts, 0) < v_max_attempts
               AND einvoice_status IN ('SENT_PENDING_KUDE', 'SENT')
               AND (pi_org_id IS NULL OR org_id_organization = pi_org_id)
             ORDER BY id_invoice
             FETCH FIRST v_limit ROWS ONLY
        ) LOOP
            BEGIN
                pr_send_einvoice_email(rec.id_invoice);
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END LOOP;
    END pr_retry_pending_einvoice_emails;

    FUNCTION fn_http_post_json(pi_url IN VARCHAR2, pi_body IN CLOB) RETURN CLOB IS
        v_response CLOB;
    BEGIN
        apex_web_service.g_request_headers.delete();
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';

        v_response := apex_web_service.make_rest_request(
            p_url         => pi_url,
            p_http_method => 'POST',
            p_body        => pi_body
        );

        IF apex_web_service.g_status_code NOT BETWEEN 200 AND 299 THEN
            RAISE_APPLICATION_ERROR(
                -20014,
                'Pagopar respondi? HTTP ' || apex_web_service.g_status_code || ': '
                || DBMS_LOB.SUBSTR(v_response, 1000, 1)
            );
        END IF;

        RETURN v_response;
    END fn_http_post_json;

    /** Recalcula y persiste storage_limit_bytes = storage del plan + addons activos. */
    PROCEDURE pr_refresh_storage_limit(pi_org_id IN NUMBER) IS
        v_limit NUMBER;
    BEGIN
        -- Calcular en un statement separado: no se puede consultar org_subscription
        -- dentro del UPDATE de la misma tabla (tabla mutante).
        v_limit := pkg_aox_subscription_api.fn_get_storage_limit_bytes(pi_org_id);

        UPDATE /*+ no_parallel */ org_subscription
           SET storage_limit_bytes = v_limit,
               updated_at          = systimestamp
         WHERE org_id_organization = pi_org_id;
    END pr_refresh_storage_limit;

    PROCEDURE pr_put_features(pi_plan_id IN NUMBER, pio_plan IN OUT NOCOPY json_object_t) IS
        v_features json_array_t := json_array_t();
    BEGIN
        FOR rec IN (
            SELECT feature_code
              FROM ref_plan_feature
             WHERE pln_id_plan = pi_plan_id
               AND is_enabled = 1
             ORDER BY feature_code
        ) LOOP
            v_features.append(rec.feature_code);
        END LOOP;
        pio_plan.put('features', v_features);
    END pr_put_features;

    --------------------------------------------------------------------------
    -- Pago recurrente: helpers privados
    --------------------------------------------------------------------------
    PROCEDURE pr_get_org_contact(
        pi_org_id IN  NUMBER,
        po_name   OUT VARCHAR2,
        po_email  OUT VARCHAR2,
        po_phone  OUT VARCHAR2
    ) IS
        -- Pagopar (agregar-cliente) exige celular con minimo 10 digitos.
        c_phone_fallback CONSTANT VARCHAR2(20) := '0981000000';
        v_digits         VARCHAR2(60);
    BEGIN
        SELECT name, company_email
          INTO po_name, po_email
          FROM organization
         WHERE id_organization = pi_org_id;

        BEGIN
            SELECT REGEXP_REPLACE(public_whatsapp, '[^0-9]', '')
              INTO v_digits
              FROM workspace_setting
             WHERE org_id_organization = pi_org_id
               AND public_whatsapp IS NOT NULL
               AND LENGTH(REGEXP_REPLACE(public_whatsapp, '[^0-9]', '')) >= 10
               AND ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_digits := NULL;
        END;

        IF v_digits IS NULL THEN
            BEGIN
                SELECT REGEXP_REPLACE(phone_number, '[^0-9]', '')
                  INTO v_digits
                  FROM professional
                 WHERE org_id_organization = pi_org_id
                   AND LENGTH(REGEXP_REPLACE(phone_number, '[^0-9]', '')) >= 10
                   AND ROWNUM = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_digits := NULL;
            END;
        END IF;

        IF v_digits IS NULL OR LENGTH(v_digits) < 10 THEN
            po_phone := c_phone_fallback;
        ELSE
            po_phone := v_digits;
        END IF;

        IF po_email IS NULL OR po_email NOT LIKE '%@%' THEN
            po_email := 'facturacion+org' || pi_org_id || '@hasel.app';
        END IF;
    END pr_get_org_contact;

    /** iniciar-transaccion (comercios/2.0): crea el pedido y devuelve el hash. */
    FUNCTION fn_iniciar_transaccion(
        pi_org_id      IN NUMBER,
        pi_invoice_id  IN NUMBER,
        pi_amount      IN NUMBER,
        pi_item_name   IN VARCHAR2,
        pi_desc        IN VARCHAR2,
        pi_public_key  IN VARCHAR2,
        pi_private_key IN VARCHAR2,
        pi_expires_at  IN TIMESTAMP WITH TIME ZONE,
        pi_forma_pago  IN NUMBER DEFAULT c_forma_pago_bancard
    ) RETURN VARCHAR2 IS
        v_id_pedido     VARCHAR2(64) := 'SUB-' || pi_invoice_id;
        v_token         VARCHAR2(64);
        v_org_name      organization.name%TYPE;
        v_org_email     organization.company_email%TYPE;
        v_org_phone     VARCHAR2(60);
        v_bill_name     org_billing_profile.billing_name%TYPE;
        v_bill_doc_type org_billing_profile.billing_doc_type%TYPE;
        v_bill_doc_number org_billing_profile.billing_doc_number%TYPE;
        v_bill_email    org_billing_profile.billing_email%TYPE;
        v_comprador     json_object_t := json_object_t();
        v_item          json_object_t := json_object_t();
        v_items         json_array_t  := json_array_t();
        v_pp_body       json_object_t := json_object_t();
        v_pp_raw        CLOB;
        v_pp_resp       json_object_t;
        v_pp_result     json_array_t;
        v_pp_result_obj json_object_t;
        v_api_url       VARCHAR2(500) := NVL(fn_get_parameter('PAGOPAR_API_INICIAR_URL'), 'https://api.pagopar.com/api/comercios/2.0/iniciar-transaccion');
    BEGIN
        pr_get_org_contact(pi_org_id, v_org_name, v_org_email, v_org_phone);
        v_token := pkg_aox_pagopar_api.fn_pagopar_sha1_token(pi_private_key || v_id_pedido || TO_CHAR(pi_amount));

        -- Perfil fiscal de suscripcion (si existe); fallback a contacto de organization.
        BEGIN
            SELECT /*+ no_parallel */
                   billing_name,
                   billing_doc_type,
                   billing_doc_number,
                   billing_email
              INTO v_bill_name,
                   v_bill_doc_type,
                   v_bill_doc_number,
                   v_bill_email
              FROM org_billing_profile
             WHERE org_id_organization = pi_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_bill_name := NULL;
                v_bill_doc_type := NULL;
                v_bill_doc_number := NULL;
                v_bill_email := NULL;
        END;

        IF v_bill_name IS NOT NULL AND LENGTH(TRIM(v_bill_name)) >= 2 THEN
            v_org_name := TRIM(v_bill_name);
        END IF;
        IF v_bill_email IS NOT NULL AND INSTR(v_bill_email, '@') > 1 THEN
            v_org_email := LOWER(TRIM(v_bill_email));
        END IF;
        IF v_bill_doc_type IS NULL OR v_bill_doc_type NOT IN ('CI', 'RUC') THEN
            v_bill_doc_type := 'CI';
        END IF;
        IF v_bill_doc_number IS NULL OR LENGTH(TRIM(v_bill_doc_number)) < 3 THEN
            v_bill_doc_number := TO_CHAR(pi_org_id);
        END IF;

        v_comprador.put('ruc', CASE WHEN v_bill_doc_type = 'RUC' THEN TRIM(v_bill_doc_number) ELSE '' END);
        v_comprador.put('email', v_org_email);
        v_comprador.put('ciudad', '1');
        v_comprador.put('nombre', v_org_name);
        v_comprador.put('telefono', v_org_phone);
        v_comprador.put('direccion', '');
        v_comprador.put('documento', TRIM(v_bill_doc_number));
        v_comprador.put('coordenadas', '');
        v_comprador.put('razon_social', v_org_name);
        v_comprador.put('tipo_documento', v_bill_doc_type);
        v_comprador.put('direccion_referencia', '');

        v_item.put('ciudad', '1');
        v_item.put('nombre', pi_item_name);
        v_item.put('cantidad', 1);
        v_item.put('categoria', '1909');
        v_item.put('public_key', pi_public_key);
        v_item.put('url_imagen', '');
        v_item.put('descripcion', pi_desc);
        v_item.put('id_producto', pi_invoice_id);
        v_item.put('precio_total', pi_amount);
        v_item.put('vendedor_telefono', '');
        v_item.put('vendedor_direccion', '');
        v_item.put('vendedor_direccion_referencia', '');
        v_item.put('vendedor_direccion_coordenadas', '');
        v_items.append(v_item);

        v_pp_body.put('token', v_token);
        v_pp_body.put('comprador', v_comprador);
        v_pp_body.put('public_key', pi_public_key);
        v_pp_body.put('monto_total', pi_amount);
        v_pp_body.put('tipo_pedido', 'VENTA-COMERCIO');
        v_pp_body.put('compras_items', v_items);
        v_pp_body.put('fecha_maxima_pago', TO_CHAR(pi_expires_at AT TIME ZONE 'America/Asuncion', 'YYYY-MM-DD HH24:MI:SS'));
        v_pp_body.put('id_pedido_comercio', v_id_pedido);
        v_pp_body.put('descripcion_resumen', pi_desc);
        v_pp_body.put('forma_pago', pi_forma_pago);

        v_pp_raw  := fn_http_post_json(v_api_url, v_pp_body.to_clob());
        v_pp_resp := json_object_t.parse(v_pp_raw);

        IF NOT v_pp_resp.get_boolean('respuesta') THEN
            RAISE_APPLICATION_ERROR(-20018, NVL(v_pp_resp.get_string('resultado'), 'Pagopar rechazo la transaccion.'));
        END IF;

        v_pp_result     := v_pp_resp.get_array('resultado');
        v_pp_result_obj := TREAT(v_pp_result.get(0) AS json_object_t);
        RETURN v_pp_result_obj.get_string('data');
    END fn_iniciar_transaccion;

    /** pagopar_card_id de la tarjeta default ACTIVE de la organizacion (NULL si no hay). */
    FUNCTION fn_default_card_pagopar_id(pi_org_id IN NUMBER) RETURN VARCHAR2 IS
        v_card_id org_payment_card.pagopar_card_id%TYPE;
    BEGIN
        SELECT pagopar_card_id INTO v_card_id
          FROM org_payment_card
         WHERE org_id_organization = pi_org_id
           AND status = 'ACTIVE'
           AND is_default = 1
           AND pagopar_card_id IS NOT NULL
         FETCH FIRST 1 ROW ONLY;
        RETURN v_card_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        RETURN NULL;
    END fn_default_card_pagopar_id;

    /** Llama listar-tarjeta y devuelve el alias_token temporal (15 min) de una tarjeta. */
    FUNCTION fn_alias_token_for(
        pi_org_id         IN NUMBER,
        pi_pagopar_card_id IN VARCHAR2,
        pi_public_key     IN VARCHAR2,
        pi_private_key    IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_raw    CLOB;
        v_resp   json_object_t;
        v_arr    json_array_t;
        v_obj    json_object_t;
    BEGIN
        v_raw  := pkg_aox_pagopar_api.fn_list_cards(pi_public_key, pi_private_key, TO_CHAR(pi_org_id));
        v_resp := json_object_t.parse(v_raw);
        IF NOT v_resp.get_boolean('respuesta') THEN
            RETURN NULL;
        END IF;
        v_arr := v_resp.get_array('resultado');
        FOR i IN 0 .. v_arr.get_size - 1 LOOP
            v_obj := json_object_t(v_arr.get(i));
            IF v_obj.get_string('tarjeta') = pi_pagopar_card_id THEN
                RETURN v_obj.get_string('alias_token');
            END IF;
        END LOOP;
        RETURN NULL;
    END fn_alias_token_for;

    /** Upsert de las tarjetas de listar-tarjeta en org_payment_card. Devuelve cantidad ACTIVE. */
    PROCEDURE pr_sync_cards(pi_org_id IN NUMBER, pi_list_raw IN CLOB) IS
        v_resp     json_object_t;
        v_arr      json_array_t;
        v_obj      json_object_t;
        v_card_id  VARCHAR2(64);
        v_brand    VARCHAR2(40);
        v_masked   VARCHAR2(40);
        v_card_type VARCHAR2(20);
        v_issuer   VARCHAR2(120);
        v_provider VARCHAR2(20);
        v_has_def  NUMBER := 0;
        v_active   NUMBER := 0;
    BEGIN
        v_resp := json_object_t.parse(pi_list_raw);
        IF NOT v_resp.get_boolean('respuesta') THEN
            RETURN;
        END IF;

        v_arr := v_resp.get_array('resultado');
        FOR i IN 0 .. v_arr.get_size - 1 LOOP
            -- Extraer a variables PL/SQL: no usar json_object_t.* dentro de MERGE (ORA-40573).
            v_obj       := json_object_t(v_arr.get(i));
            v_card_id   := v_obj.get_string('tarjeta');
            v_brand     := v_obj.get_string('marca');
            v_masked    := v_obj.get_string('tarjeta_numero');
            v_card_type := v_obj.get_string('tipo_tarjeta');
            v_issuer    := v_obj.get_string('emisor');
            v_provider  := NVL(v_obj.get_string('proveedor'), 'uPay');

            MERGE /*+ no_parallel */ INTO org_payment_card t
            USING (SELECT pi_org_id AS org_id, v_card_id AS card_id FROM dual) s
               ON (t.org_id_organization = s.org_id AND t.pagopar_card_id = s.card_id)
            WHEN MATCHED THEN
                UPDATE SET t.status        = 'ACTIVE',
                           t.brand         = v_brand,
                           t.masked_number = v_masked,
                           t.card_type     = v_card_type,
                           t.issuer        = v_issuer,
                           t.provider      = NVL(v_provider, t.provider),
                           t.confirmed_at  = NVL(t.confirmed_at, systimestamp),
                           t.updated_at    = systimestamp
            WHEN NOT MATCHED THEN
                INSERT (org_id_organization, provider, pagopar_identificador, pagopar_card_id,
                        brand, masked_number, card_type, issuer, status, is_default, confirmed_at)
                VALUES (pi_org_id, v_provider, TO_CHAR(pi_org_id), s.card_id,
                        v_brand, v_masked, v_card_type, v_issuer,
                        'ACTIVE', 0, systimestamp);
        END LOOP;

        -- Marcar DELETED las tarjetas locales ACTIVE que Pagopar ya no lista.
        UPDATE /*+ no_parallel */ org_payment_card
           SET status = 'DELETED', is_default = 0, updated_at = systimestamp
         WHERE org_id_organization = pi_org_id
           AND status = 'ACTIVE'
           AND NOT EXISTS (
               SELECT 1 FROM json_table(
                   pi_list_raw, '$.resultado[*]'
                   COLUMNS (tarjeta VARCHAR2(64) PATH '$.tarjeta')
               ) jt WHERE jt.tarjeta = org_payment_card.pagopar_card_id
           );

        -- Asegurar una tarjeta default si hay ACTIVE y ninguna default.
        SELECT COUNT(*) INTO v_active FROM org_payment_card
         WHERE org_id_organization = pi_org_id AND status = 'ACTIVE';
        SELECT COUNT(*) INTO v_has_def FROM org_payment_card
         WHERE org_id_organization = pi_org_id AND status = 'ACTIVE' AND is_default = 1;

        IF v_active > 0 AND v_has_def = 0 THEN
            UPDATE /*+ no_parallel */ org_payment_card
               SET is_default = 1, updated_at = systimestamp
             WHERE id_payment_card = (
                 SELECT id_payment_card FROM (
                     SELECT id_payment_card FROM org_payment_card
                      WHERE org_id_organization = pi_org_id AND status = 'ACTIVE'
                      ORDER BY confirmed_at DESC NULLS LAST, id_payment_card DESC
                 ) WHERE ROWNUM = 1
             );
        END IF;
    END pr_sync_cards;

    --------------------------------------------------------------------------
    -- Facturacion consolidada / prorrateo
    --------------------------------------------------------------------------
    PROCEDURE pr_get_period_bounds(
        pi_org_id       IN  NUMBER,
        po_period_start OUT TIMESTAMP WITH TIME ZONE,
        po_period_end   OUT TIMESTAMP WITH TIME ZONE
    ) IS
    BEGIN
        SELECT current_period_start, current_period_end
          INTO po_period_start, po_period_end
          FROM org_subscription
         WHERE org_id_organization = pi_org_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            po_period_start := NULL;
            po_period_end   := NULL;
    END pr_get_period_bounds;

    FUNCTION fn_calendar_days_between(
        pi_from IN TIMESTAMP WITH TIME ZONE,
        pi_to   IN TIMESTAMP WITH TIME ZONE
    ) RETURN NUMBER IS
    BEGIN
        IF pi_from IS NULL OR pi_to IS NULL THEN
            RETURN 0;
        END IF;
        RETURN GREATEST(0, TRUNC(CAST(pi_to AS DATE)) - TRUNC(CAST(pi_from AS DATE)));
    END fn_calendar_days_between;

    FUNCTION fn_prorate_amount(
        pi_full_amount    IN NUMBER,
        pi_days_remaining IN NUMBER,
        pi_period_days    IN NUMBER,
        pi_enforce_min    IN NUMBER DEFAULT 1
    ) RETURN NUMBER IS
        v_period NUMBER := GREATEST(1, NVL(pi_period_days, 1));
        v_days   NUMBER := GREATEST(0, NVL(pi_days_remaining, 0));
        v_amt    NUMBER;
    BEGIN
        IF v_days <= 0 OR NVL(pi_full_amount, 0) <= 0 THEN
            RETURN 0;
        END IF;
        v_amt := CEIL(pi_full_amount * v_days / v_period);
        -- Pagopar exige minimo 1000 Gs en cobros; creditos no aplican piso.
        IF NVL(pi_enforce_min, 1) = 1 AND v_amt > 0 AND v_amt < 1000 THEN
            v_amt := 1000;
        END IF;
        RETURN v_amt;
    END fn_prorate_amount;

    /** Credito por tiempo no usado de cualquier item mensual (plan o addon). */
    FUNCTION fn_unused_credit_amount(
        pi_org_id       IN NUMBER,
        pi_full_monthly IN NUMBER
    ) RETURN NUMBER IS
        v_start TIMESTAMP WITH TIME ZONE;
        v_end   TIMESTAMP WITH TIME ZONE;
        v_days  NUMBER;
        v_per   NUMBER;
    BEGIN
        IF NVL(pi_full_monthly, 0) <= 0 THEN
            RETURN 0;
        END IF;
        pr_get_period_bounds(pi_org_id, v_start, v_end);
        IF v_end IS NULL OR v_end <= systimestamp THEN
            RETURN 0;
        END IF;
        v_days := fn_calendar_days_between(systimestamp, v_end);
        v_per  := fn_calendar_days_between(NVL(v_start, ADD_MONTHS(v_end, -1)), v_end);
        IF v_per < 1 THEN
            v_per := 30;
        END IF;
        RETURN fn_prorate_amount(pi_full_monthly, v_days, v_per, 0);
    END fn_unused_credit_amount;

    PROCEDURE pr_grant_credit(
        pi_org_id    IN NUMBER,
        pi_amount    IN NUMBER,
        pi_reason    IN VARCHAR2,
        pi_ref_code  IN VARCHAR2 DEFAULT NULL,
        pi_invoice_id IN NUMBER DEFAULT NULL
    ) IS
        v_bal NUMBER;
        v_amt NUMBER := GREATEST(0, ROUND(NVL(pi_amount, 0)));
    BEGIN
        IF v_amt <= 0 THEN
            RETURN;
        END IF;
        UPDATE /*+ no_parallel */ org_subscription
           SET account_balance = NVL(account_balance, 0) + v_amt,
               updated_at      = systimestamp
         WHERE org_id_organization = pi_org_id
        RETURNING account_balance INTO v_bal;

        INSERT /*+ no_parallel */ INTO org_billing_credit_ledger (
            org_id_organization, delta_amount, balance_after, reason, invoice_id, ref_code
        ) VALUES (
            pi_org_id, v_amt, v_bal, UPPER(TRIM(pi_reason)), pi_invoice_id, pi_ref_code
        );
    END pr_grant_credit;

    PROCEDURE pr_apply_credit_to_amount(
        pi_org_id         IN  NUMBER,
        pi_gross          IN  NUMBER,
        po_net            OUT NUMBER,
        po_credit_applied OUT NUMBER
    ) IS
        v_bal NUMBER;
        v_gross NUMBER := GREATEST(0, ROUND(NVL(pi_gross, 0)));
    BEGIN
        SELECT NVL(account_balance, 0)
          INTO v_bal
          FROM org_subscription
         WHERE org_id_organization = pi_org_id;

        po_credit_applied := LEAST(v_bal, v_gross);
        po_net            := v_gross - po_credit_applied;
    END pr_apply_credit_to_amount;

    PROCEDURE pr_consume_credit(
        pi_org_id         IN NUMBER,
        pi_credit_applied IN NUMBER,
        pi_invoice_id     IN NUMBER
    ) IS
        v_bal NUMBER;
        v_amt NUMBER := GREATEST(0, ROUND(NVL(pi_credit_applied, 0)));
        v_already NUMBER;
    BEGIN
        IF v_amt <= 0 THEN
            RETURN;
        END IF;

        -- Idempotencia: no consumir dos veces la misma factura.
        SELECT COUNT(*)
          INTO v_already
          FROM org_billing_credit_ledger
         WHERE invoice_id = pi_invoice_id
           AND reason = 'APPLY_INVOICE';
        IF v_already > 0 THEN
            RETURN;
        END IF;

        UPDATE /*+ no_parallel */ org_subscription
           SET account_balance = GREATEST(0, NVL(account_balance, 0) - v_amt),
               updated_at      = systimestamp
         WHERE org_id_organization = pi_org_id
        RETURNING account_balance INTO v_bal;

        INSERT /*+ no_parallel */ INTO org_billing_credit_ledger (
            org_id_organization, delta_amount, balance_after, reason, invoice_id, ref_code
        ) VALUES (
            pi_org_id, -v_amt, v_bal, 'APPLY_INVOICE', pi_invoice_id, NULL
        );
    END pr_consume_credit;

    PROCEDURE pr_cancel_active_addons_no_credit(pi_org_id IN NUMBER) IS
    BEGIN
        UPDATE /*+ no_parallel */ org_storage_addon
           SET status  = 'CANCELED',
               ends_at = NVL(ends_at, systimestamp)
         WHERE org_id_organization = pi_org_id
           AND status = 'ACTIVE';

        UPDATE /*+ no_parallel */ org_addon
           SET status      = 'CANCELED',
               canceled_at = NVL(canceled_at, systimestamp),
               updated_at  = systimestamp
         WHERE org_id_organization = pi_org_id
           AND status = 'ACTIVE';
    END pr_cancel_active_addons_no_credit;

    PROCEDURE pr_apply_due_pending_plan(pi_org_id IN NUMBER) IS
        v_pending_id   NUMBER;
        v_pending_at   TIMESTAMP WITH TIME ZONE;
        v_period_end   TIMESTAMP WITH TIME ZONE;
        v_pending_code VARCHAR2(30);
    BEGIN
        SELECT pending_pln_id_plan, pending_plan_change_at, current_period_end
          INTO v_pending_id, v_pending_at, v_period_end
          FROM org_subscription
         WHERE org_id_organization = pi_org_id;

        IF v_pending_id IS NULL THEN
            RETURN;
        END IF;

        IF (v_pending_at IS NOT NULL AND v_pending_at <= systimestamp)
           OR (v_period_end IS NOT NULL AND v_period_end <= systimestamp) THEN
            BEGIN
                SELECT code INTO v_pending_code FROM ref_plan WHERE id_plan = v_pending_id;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                v_pending_code := NULL;
            END;

            IF v_pending_code = c_plan_free THEN
                -- Terminar: FREE + READ_ONLY + apagar cobros + cancelar addons (sin credito).
                UPDATE /*+ no_parallel */ org_subscription
                   SET pln_id_plan            = v_pending_id,
                       status                 = 'READ_ONLY',
                       auto_renew             = 0,
                       pending_pln_id_plan    = NULL,
                       pending_plan_change_at = NULL,
                       updated_at             = systimestamp
                 WHERE org_id_organization = pi_org_id;
                pr_cancel_active_addons_no_credit(pi_org_id);
            ELSE
                UPDATE /*+ no_parallel */ org_subscription
                   SET pln_id_plan            = v_pending_id,
                       pending_pln_id_plan    = NULL,
                       pending_plan_change_at = NULL,
                       updated_at             = systimestamp
                 WHERE org_id_organization = pi_org_id;
            END IF;
            pr_refresh_storage_limit(pi_org_id);
        END IF;
    END pr_apply_due_pending_plan;

    PROCEDURE pr_fulfill_paid_subscription(
        pi_org_id  IN NUMBER,
        pi_plan_id IN NUMBER
    ) IS
        v_prev_status org_subscription.status%TYPE;
    BEGIN
        BEGIN
            SELECT status INTO v_prev_status
              FROM org_subscription
             WHERE org_id_organization = pi_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_prev_status := NULL;
        END;

        UPDATE /*+ no_parallel */ org_subscription
           SET pln_id_plan            = pi_plan_id,
               status                 = 'ACTIVE',
               auto_renew             = 1,
               canceled_at            = NULL,
               current_period_start   = systimestamp,
               current_period_end     = ADD_MONTHS(GREATEST(NVL(current_period_end, systimestamp), systimestamp), 1),
               grace_ends_at          = NULL,
               charge_retry_count     = 0,
               last_charge_at         = systimestamp,
               pending_pln_id_plan    = NULL,
               pending_plan_change_at = NULL,
               updated_at             = systimestamp
         WHERE org_id_organization = pi_org_id;
        pr_refresh_storage_limit(pi_org_id);

        IF v_prev_status = 'PAST_DUE' THEN
            pr_enqueue_billing_admin_notice(
                pi_org_id => pi_org_id,
                pi_event  => 'PAYMENT_RECOVERED',
                pi_period => TO_CHAR(systimestamp AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'),
                pi_title  => 'Pago recuperado',
                pi_body   => 'El cobro de tu suscripción se confirmó. Ya estás al día.'
            );
        END IF;
    END pr_fulfill_paid_subscription;

    PROCEDURE pr_fulfill_paid_addon(
        pi_org_id   IN NUMBER,
        pi_addon_id IN NUMBER
    ) IS
    BEGIN
        IF pi_addon_id IS NULL THEN
            RETURN;
        END IF;
        MERGE /*+ no_parallel */ INTO org_storage_addon t
        USING (SELECT pi_org_id AS org_id, pi_addon_id AS addon_id FROM dual) s
           ON (t.org_id_organization = s.org_id AND t.sad_id_storage_addon = s.addon_id AND t.status = 'ACTIVE')
        WHEN MATCHED THEN
            UPDATE SET t.quantity = t.quantity + 1
        WHEN NOT MATCHED THEN
            INSERT (org_id_organization, sad_id_storage_addon, quantity, status)
            VALUES (s.org_id, s.addon_id, 1, 'ACTIVE');
        pr_refresh_storage_limit(pi_org_id);
    END pr_fulfill_paid_addon;

    FUNCTION fn_addons_monthly_total(pi_org_id IN NUMBER) RETURN NUMBER IS
        v_total NUMBER;
    BEGIN
        SELECT NVL(SUM(r.price_amount * o.quantity), 0)
          INTO v_total
          FROM org_storage_addon o
          JOIN ref_storage_addon r ON r.id_storage_addon = o.sad_id_storage_addon
         WHERE o.org_id_organization = pi_org_id
           AND o.status = 'ACTIVE'
           AND r.is_active = 1;
        RETURN v_total;
    END fn_addons_monthly_total;

    FUNCTION fn_addons_desc_suffix(pi_org_id IN NUMBER) RETURN VARCHAR2 IS
        v_parts VARCHAR2(500);
    BEGIN
        SELECT LISTAGG(r.name || CASE WHEN o.quantity > 1 THEN ' x' || o.quantity ELSE '' END, ' + ')
                 WITHIN GROUP (ORDER BY r.sort_order, r.id_storage_addon)
          INTO v_parts
          FROM org_storage_addon o
          JOIN ref_storage_addon r ON r.id_storage_addon = o.sad_id_storage_addon
         WHERE o.org_id_organization = pi_org_id
           AND o.status = 'ACTIVE';
        RETURN v_parts;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_addons_desc_suffix;

    PROCEDURE pr_activate_addon_free(
        pi_org_id   IN NUMBER,
        pi_addon_id IN NUMBER
    ) IS
    BEGIN
        MERGE /*+ no_parallel */ INTO org_storage_addon t
        USING (SELECT pi_org_id AS org_id, pi_addon_id AS addon_id FROM dual) s
           ON (t.org_id_organization = s.org_id AND t.sad_id_storage_addon = s.addon_id AND t.status = 'ACTIVE')
        WHEN MATCHED THEN
            UPDATE SET t.quantity = t.quantity + 1
        WHEN NOT MATCHED THEN
            INSERT (org_id_organization, sad_id_storage_addon, quantity, status)
            VALUES (s.org_id, s.addon_id, 1, 'ACTIVE');
        pr_refresh_storage_limit(pi_org_id);
        COMMIT;
    END pr_activate_addon_free;

    /**
     * Cobro recurrente de un target con la tarjeta default:
     *   PLAN            -> solo precio del plan (activacion / upgrade)
     *   STORAGE_ADDON   -> prorrateo hasta current_period_end
     *   CONSOLIDATED    -> plan + addons ACTIVE (ciclo de renovacion)
     * Aplica account_balance (gross/credit_applied/amount neto).
     * Si net=0: PAID inmediato sin Pagopar. Si net>0: webhook confirma PAID.
     */
    PROCEDURE pr_charge_target(
        pi_org_id           IN  NUMBER,
        pi_target_type      IN  VARCHAR2,
        pi_plan_code        IN  VARCHAR2,
        pi_addon_code       IN  VARCHAR2,
        po_invoice_id       OUT NUMBER,
        po_hash             OUT VARCHAR2,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
    ) IS
        -- Idempotencia (framework generico PKG_AOX_UTIL): protege el unico choke point
        -- de cobro de suscripcion/addon (checkout, activate y billing cycle) contra
        -- doble cobro por reintento de red.
        c_idem_scope        CONSTANT VARCHAR2(64) := 'SUBSCRIPTION_CHARGE_TARGET';
        v_idem_key          VARCHAR2(255) := TRIM(pi_idempotency_key);
        v_idem_request_hash VARCHAR2(64);
        v_idem_outcome      VARCHAR2(20);
        v_idem_resp_status  NUMBER;
        v_idem_resp_payload CLOB;
        v_idem_replay       json_object_t;

        v_public_key   VARCHAR2(500);
        v_private_key  VARCHAR2(500);
        v_sub_id       org_subscription.id_subscription%TYPE;
        v_plan_id      ref_plan.id_plan%TYPE;
        v_addon_id     ref_storage_addon.id_storage_addon%TYPE;
        v_full_amount  NUMBER;
        v_gross        NUMBER := 0;
        v_net          NUMBER := 0;
        v_credit       NUMBER := 0;
        v_pay_amount   NUMBER;
        v_currency     VARCHAR2(3) := 'PYG';
        v_item_name    VARCHAR2(150);
        v_desc         VARCHAR2(255);
        v_invoice_type VARCHAR2(20);
        v_period_start TIMESTAMP WITH TIME ZONE := systimestamp;
        v_period_end   TIMESTAMP WITH TIME ZONE := ADD_MONTHS(systimestamp, 1);
        v_sub_start    TIMESTAMP WITH TIME ZONE;
        v_sub_end      TIMESTAMP WITH TIME ZONE;
        v_days_rem     NUMBER;
        v_period_days  NUMBER;
        v_addon_total  NUMBER;
        v_addon_suffix VARCHAR2(500);
        v_expires_at   TIMESTAMP WITH TIME ZONE := systimestamp + NUMTODSINTERVAL(NVL(TO_NUMBER(fn_get_parameter('SUBSCRIPTION_PAYMENT_PENDING_MINUTES')), 1440), 'MINUTE');
        v_founder      NUMBER(1,0) := 0;
        v_card_id      org_payment_card.pagopar_card_id%TYPE;
        v_alias_token  VARCHAR2(256);
        v_pay_raw      CLOB;
        v_pay_resp     json_object_t;
        v_target       VARCHAR2(20) := UPPER(TRIM(pi_target_type));

        PROCEDURE lp_idem_complete(pi_invoice_id IN NUMBER, pi_hash IN VARCHAR2) IS
            v_payload json_object_t := json_object_t();
        BEGIN
            IF v_idem_key IS NULL THEN
                RETURN;
            END IF;
            v_payload.put('invoice_id', pi_invoice_id);
            v_payload.put('hash', pi_hash);
            pkg_aox_util.pr_idempotency_complete(c_idem_scope, v_idem_key, 200, v_payload.to_clob());
        END lp_idem_complete;
    BEGIN
        IF v_idem_key IS NOT NULL THEN
            v_idem_request_hash := RAWTOHEX(DBMS_CRYPTO.HASH(
                UTL_I18N.STRING_TO_RAW(
                    TO_CHAR(pi_org_id) || '|' || v_target || '|' ||
                    NVL(UPPER(TRIM(pi_plan_code)), '') || '|' || NVL(UPPER(TRIM(pi_addon_code)), ''),
                    'AL32UTF8'
                ),
                DBMS_CRYPTO.HASH_SH256
            ));

            pkg_aox_util.pr_idempotency_begin(
                pi_scope             => c_idem_scope,
                pi_key               => v_idem_key,
                pi_request_hash      => v_idem_request_hash,
                po_outcome           => v_idem_outcome,
                po_response_status   => v_idem_resp_status,
                po_response_payload  => v_idem_resp_payload
            );

            IF v_idem_outcome = 'REPLAY' THEN
                v_idem_replay := json_object_t.parse(v_idem_resp_payload);
                po_invoice_id := v_idem_replay.get_number('invoice_id');
                po_hash       := v_idem_replay.get_string('hash');
                RETURN;
            ELSIF v_idem_outcome = 'IN_PROGRESS' THEN
                RAISE_APPLICATION_ERROR(
                    pkg_aox_util.c_sqlcode_idempotency_progress,
                    'Ya hay un cobro en curso para esta operacion. Espera unos segundos e intenta de nuevo.'
                );
            ELSIF v_idem_outcome = 'CONFLICT' THEN
                RAISE_APPLICATION_ERROR(
                    pkg_aox_util.c_sqlcode_idempotency_conflict,
                    'La clave de idempotencia ya fue usada con una operacion distinta.'
                );
            END IF;
            -- outcome = 'NEW': continua el flujo normal abajo
        END IF;

    BEGIN
        SELECT id_subscription, NVL(is_founder, 0)
          INTO v_sub_id, v_founder
          FROM org_subscription
         WHERE org_id_organization = pi_org_id;

        pr_get_period_bounds(pi_org_id, v_sub_start, v_sub_end);

        IF v_target IN ('PLAN', 'CONSOLIDATED') AND UPPER(TRIM(pi_plan_code)) = c_plan_free THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'El plan Continuidad no se cobra. Elegi Base o Premium para reactivar.'
            );
        END IF;

        IF v_target = 'PLAN' THEN
            BEGIN
                SELECT id_plan, price_amount, currency, name
                  INTO v_plan_id, v_gross, v_currency, v_item_name
                  FROM ref_plan WHERE code = pi_plan_code AND is_active = 1;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Plan no valido.');
            END;

            IF v_founder = 1 AND pi_plan_code = c_plan_premium THEN
                v_gross := ROUND(v_gross * 0.5);
                v_desc := 'Suscripcion ' || v_item_name || ' fundador 50% (1 mes)';
            ELSE
                v_desc := 'Suscripcion ' || v_item_name || ' (1 mes)';
            END IF;
            v_invoice_type := 'SUBSCRIPTION';

        ELSIF v_target = 'CONSOLIDATED' THEN
            BEGIN
                SELECT id_plan, price_amount, currency, name
                  INTO v_plan_id, v_gross, v_currency, v_item_name
                  FROM ref_plan WHERE code = pi_plan_code AND is_active = 1;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Plan no valido.');
            END;

            IF v_founder = 1 AND pi_plan_code = c_plan_premium THEN
                v_gross := ROUND(v_gross * 0.5);
            END IF;

            v_addon_total  := fn_addons_monthly_total(pi_org_id);
            v_addon_suffix := fn_addons_desc_suffix(pi_org_id);
            v_gross        := NVL(v_gross, 0) + NVL(v_addon_total, 0);

            IF v_addon_suffix IS NOT NULL THEN
                v_desc := v_item_name || ' + ' || v_addon_suffix || ' (1 mes)';
            ELSE
                v_desc := 'Suscripcion ' || v_item_name || ' (1 mes)';
            END IF;

            IF v_sub_end IS NOT NULL THEN
                v_period_start := NVL(v_sub_end, systimestamp);
                v_period_end   := ADD_MONTHS(v_period_start, 1);
            END IF;
            v_invoice_type := 'SUBSCRIPTION';

        ELSIF v_target = 'STORAGE_ADDON' THEN
            IF pkg_aox_subscription_api.fn_org_has_feature(pi_org_id, 'APPOINTMENT_HISTORY') = 0 THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Los paquetes de almacenamiento solo estan disponibles en el plan Premium.');
            END IF;
            BEGIN
                SELECT id_storage_addon, price_amount, currency, name
                  INTO v_addon_id, v_full_amount, v_currency, v_item_name
                  FROM ref_storage_addon WHERE code = pi_addon_code AND is_active = 1;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Paquete de almacenamiento no valido.');
            END;

            IF v_sub_end IS NOT NULL AND v_sub_end > systimestamp THEN
                v_days_rem    := fn_calendar_days_between(systimestamp, v_sub_end);
                v_period_days := fn_calendar_days_between(
                    NVL(v_sub_start, ADD_MONTHS(v_sub_end, -1)),
                    v_sub_end
                );
                IF v_period_days < 1 THEN
                    v_period_days := 30;
                END IF;
                v_gross        := fn_prorate_amount(v_full_amount, v_days_rem, v_period_days, 1);
                v_period_start := systimestamp;
                v_period_end   := v_sub_end;
                IF v_days_rem <= 0 THEN
                    v_desc := v_item_name || ' (sin cobro; entra en la renovacion)';
                ELSE
                    v_desc := v_item_name || ' (prorrateo ' || v_days_rem || ' dia(s))';
                END IF;
            ELSE
                v_gross        := v_full_amount;
                v_period_start := systimestamp;
                v_period_end   := ADD_MONTHS(systimestamp, 1);
                v_desc         := v_item_name || ' (1 mes)';
            END IF;

            IF NVL(v_gross, 0) <= 0 THEN
                pr_activate_addon_free(pi_org_id, v_addon_id);
                po_invoice_id := NULL;
                po_hash       := NULL;
                lp_idem_complete(po_invoice_id, po_hash);
                RETURN;
            END IF;
            v_invoice_type := 'STORAGE_ADDON';
            v_plan_id      := NULL;
        ELSE
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation,
                'target_type invalido (PLAN, STORAGE_ADDON o CONSOLIDATED).');
        END IF;

        pr_apply_credit_to_amount(pi_org_id, v_gross, v_net, v_credit);
        IF v_credit > 0 THEN
            v_desc := SUBSTR(v_desc || ' - credito ' || TO_CHAR(v_credit) || ' Gs', 1, 255);
        END IF;

        -- Cubierto 100% por saldo: PAID sin Pagopar ni tarjeta.
        IF v_net <= 0 THEN
            INSERT /*+ no_parallel */ INTO org_subscription_invoice (
                org_id_organization, sub_id_subscription, invoice_type, pln_id_plan,
                sad_id_storage_addon, description, amount, gross_amount, credit_applied,
                currency, status, period_start, period_end, due_date, paid_at, payment_provider
            ) VALUES (
                pi_org_id, v_sub_id, v_invoice_type, v_plan_id,
                v_addon_id, v_desc, 0, v_gross, v_credit,
                v_currency, 'PAID', v_period_start, v_period_end, v_expires_at, systimestamp, 'credit'
            ) RETURNING id_invoice INTO po_invoice_id;

            pr_consume_credit(pi_org_id, v_credit, po_invoice_id);

            IF v_invoice_type = 'SUBSCRIPTION' THEN
                pr_fulfill_paid_subscription(pi_org_id, v_plan_id);
            ELSIF v_invoice_type = 'STORAGE_ADDON' THEN
                pr_fulfill_paid_addon(pi_org_id, v_addon_id);
            END IF;

            pr_enqueue_einvoice_dispatch(po_invoice_id);
            COMMIT;
            pr_dispatch_einvoice_outbox(5);

            po_hash := NULL;
            lp_idem_complete(po_invoice_id, po_hash);
            RETURN;
        END IF;

        pr_get_platform_keys(v_public_key, v_private_key);
        v_card_id := fn_default_card_pagopar_id(pi_org_id);
        IF v_card_id IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation,
                'Agrega una tarjeta antes de activar la suscripcion.');
        END IF;

        -- Minimo Pagopar 1000 Gs; no se consume credito extra.
        v_pay_amount := v_net;
        IF v_pay_amount > 0 AND v_pay_amount < 1000 THEN
            v_pay_amount := 1000;
        END IF;

        INSERT /*+ no_parallel */ INTO org_subscription_invoice (
            org_id_organization, sub_id_subscription, invoice_type, pln_id_plan,
            sad_id_storage_addon, description, amount, gross_amount, credit_applied,
            currency, status, period_start, period_end, due_date, payment_provider
        ) VALUES (
            pi_org_id, v_sub_id, v_invoice_type, v_plan_id,
            v_addon_id, v_desc, v_pay_amount, v_gross, v_credit,
            v_currency, 'PENDING', v_period_start, v_period_end, v_expires_at, 'pagopar'
        ) RETURNING id_invoice INTO po_invoice_id;

        po_hash := fn_iniciar_transaccion(
            pi_org_id      => pi_org_id,
            pi_invoice_id  => po_invoice_id,
            pi_amount      => v_pay_amount,
            pi_item_name   => v_item_name,
            pi_desc        => v_desc,
            pi_public_key  => v_public_key,
            pi_private_key => v_private_key,
            pi_expires_at  => v_expires_at,
            pi_forma_pago  => c_forma_pago_bancard
        );

        UPDATE /*+ no_parallel */ org_subscription_invoice
           SET external_reference = po_hash
         WHERE id_invoice = po_invoice_id;

        COMMIT;

        v_alias_token := fn_alias_token_for(pi_org_id, v_card_id, v_public_key, v_private_key);
        IF v_alias_token IS NULL THEN
            UPDATE /*+ no_parallel */ org_subscription_invoice SET status = 'FAILED' WHERE id_invoice = po_invoice_id;
            COMMIT;
            RAISE_APPLICATION_ERROR(-20031, 'No se pudo obtener la tarjeta catastrada para el cobro.');
        END IF;

        v_pay_raw  := pkg_aox_pagopar_api.fn_pay(v_public_key, v_private_key, TO_CHAR(pi_org_id), po_hash, v_alias_token);
        v_pay_resp := json_object_t.parse(v_pay_raw);

        IF NOT v_pay_resp.get_boolean('respuesta') THEN
            UPDATE /*+ no_parallel */ org_subscription_invoice SET status = 'FAILED' WHERE id_invoice = po_invoice_id;
            COMMIT;
            RAISE_APPLICATION_ERROR(-20032, NVL(v_pay_resp.get_string('resultado'), 'Pagopar rechazo el cobro de la tarjeta.'));
        END IF;

        lp_idem_complete(po_invoice_id, po_hash);
    EXCEPTION
        WHEN OTHERS THEN
            -- Libera la key ante fallas tecnicas/transitorias (sin cobro confirmado) para no
            -- bloquear un retry legitimo. Los rechazos de negocio (validacion, sin tarjeta,
            -- Pagopar rechazo explicito) dejan la key IN_PROGRESS: el frontend emite una key
            -- nueva para el siguiente intento del usuario (ver Fase 4 del plan).
            IF v_idem_key IS NOT NULL AND SQLCODE NOT IN (
                pkg_aox_util.c_sqlcode_validation, pkg_aox_util.c_sqlcode_forbidden, -20031, -20032
            ) THEN
                pkg_aox_util.pr_idempotency_release(c_idem_scope, v_idem_key);
            END IF;
            RAISE;
    END;
    END pr_charge_target;

    --------------------------------------------------------------------------
    -- GET /workspace/plans
    --------------------------------------------------------------------------
    PROCEDURE pr_get_plans(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id          NUMBER;
        v_response        json_object_t := json_object_t();
        v_data            json_object_t := json_object_t();
        v_current         json_object_t := json_object_t();
        v_plans           json_array_t  := json_array_t();
        v_addons          json_array_t  := json_array_t();

        v_cur_plan_code   ref_plan.code%TYPE;
        v_cur_plan_name   ref_plan.name%TYPE;
        v_cur_plan_id     ref_plan.id_plan%TYPE;
        v_cur_plan_price  ref_plan.price_amount%TYPE;
        v_status          org_subscription.status%TYPE;
        v_is_founder      org_subscription.is_founder%TYPE;
        v_billing_exempt  org_subscription.billing_exempt%TYPE;
        v_storage_used    org_subscription.storage_used_bytes%TYPE;
        v_trial_ends_at   org_subscription.trial_ends_at%TYPE;
        v_period_start    org_subscription.current_period_start%TYPE;
        v_period_end      org_subscription.current_period_end%TYPE;
        v_grace_ends_at   org_subscription.grace_ends_at%TYPE;
        v_account_balance NUMBER := 0;
        v_pending_plan_id NUMBER;
        v_pending_at      TIMESTAMP WITH TIME ZONE;
        v_pending_code    VARCHAR2(30);
        v_pending_name    VARCHAR2(100);
        v_eff_state       VARCHAR2(20);
        v_storage_limit   NUMBER;
        v_platform_ok     NUMBER := 0;
        v_dummy_pub       VARCHAR2(500);
        v_dummy_priv      VARCHAR2(500);
        v_plan_monthly    NUMBER := 0;
        v_addons_monthly  NUMBER := 0;
        v_days_rem        NUMBER := 0;
        v_period_days     NUMBER := 30;
        v_active_addons   json_array_t := json_array_t();
        v_auto_renew      NUMBER(1,0) := 1;
        v_canceled_at     TIMESTAMP WITH TIME ZONE;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token inv?lido o sin organizaci?n asociada.');
        END IF;

        -- Aplicar cancelacion/downgrade vencidos antes de armar el snapshot.
        pr_apply_due_pending_plan(v_org_id);
        COMMIT;

        SELECT s.pln_id_plan, p.code, p.name, p.price_amount, s.status, s.is_founder, s.billing_exempt,
               s.storage_used_bytes, s.trial_ends_at, s.current_period_start, s.current_period_end, s.grace_ends_at,
               NVL(s.account_balance, 0), s.pending_pln_id_plan, s.pending_plan_change_at,
               NVL(s.auto_renew, 1), s.canceled_at
          INTO v_cur_plan_id, v_cur_plan_code, v_cur_plan_name, v_cur_plan_price, v_status, v_is_founder, v_billing_exempt,
               v_storage_used, v_trial_ends_at, v_period_start, v_period_end, v_grace_ends_at,
               v_account_balance, v_pending_plan_id, v_pending_at,
               v_auto_renew, v_canceled_at
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        IF v_pending_plan_id IS NOT NULL THEN
            BEGIN
                SELECT code, name INTO v_pending_code, v_pending_name
                  FROM ref_plan WHERE id_plan = v_pending_plan_id;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                v_pending_code := NULL;
                v_pending_name := NULL;
            END;
        END IF;

        v_eff_state     := pkg_aox_subscription_api.fn_get_subscription_state(v_org_id);
        v_storage_limit := pkg_aox_subscription_api.fn_get_storage_limit_bytes(v_org_id);

        BEGIN
            pr_get_platform_keys(v_dummy_pub, v_dummy_priv);
            v_platform_ok := 1;
        EXCEPTION WHEN OTHERS THEN
            v_platform_ok := 0;
        END;

        IF NVL(v_is_founder, 0) = 1 AND v_cur_plan_code = c_plan_premium THEN
            v_plan_monthly := ROUND(v_cur_plan_price * 0.5);
        ELSE
            v_plan_monthly := NVL(v_cur_plan_price, 0);
        END IF;
        v_addons_monthly := fn_addons_monthly_total(v_org_id);

        IF v_period_end IS NOT NULL AND v_period_end > systimestamp THEN
            v_days_rem    := fn_calendar_days_between(systimestamp, v_period_end);
            v_period_days := fn_calendar_days_between(
                NVL(v_period_start, ADD_MONTHS(v_period_end, -1)),
                v_period_end
            );
            IF v_period_days < 1 THEN
                v_period_days := 30;
            END IF;
        ELSE
            v_days_rem    := 0;
            v_period_days := 30;
        END IF;

        FOR rec IN (
            SELECT r.code, r.name, r.price_amount, o.quantity, r.extra_bytes
              FROM org_storage_addon o
              JOIN ref_storage_addon r ON r.id_storage_addon = o.sad_id_storage_addon
             WHERE o.org_id_organization = v_org_id
               AND o.status = 'ACTIVE'
             ORDER BY r.sort_order, r.id_storage_addon
        ) LOOP
            DECLARE
                v_oa json_object_t := json_object_t();
                v_cancel_credit NUMBER;
            BEGIN
                v_cancel_credit := fn_prorate_amount(rec.price_amount, v_days_rem, v_period_days, 0);
                v_oa.put('code', rec.code);
                v_oa.put('name', rec.name);
                v_oa.put('quantity', rec.quantity);
                v_oa.put('price_amount', rec.price_amount);
                v_oa.put('line_total', rec.price_amount * rec.quantity);
                v_oa.put('extra_bytes', rec.extra_bytes);
                v_oa.put('cancel_credit_amount', v_cancel_credit);
                v_oa.put('cancelable', 1);
                v_active_addons.append(v_oa);
            END;
        END LOOP;

        -- Snapshot actual
        v_current.put('plan_code'          , v_cur_plan_code);
        v_current.put('plan_name'          , v_cur_plan_name);
        v_current.put('status'             , v_status);
        v_current.put('effective_status'   , v_eff_state);
        v_current.put('can_write'          , pkg_aox_subscription_api.fn_org_can_write(v_org_id));
        v_current.put('is_founder'         , v_is_founder);
        v_current.put('billing_exempt'     , v_billing_exempt);
        v_current.put('founder_discount_percent', CASE WHEN NVL(v_is_founder, 0) = 1 THEN 50 ELSE 0 END);
        v_current.put('trial_ends_at'      , fn_ts_to_iso(v_trial_ends_at));
        v_current.put('current_period_start', fn_ts_to_iso(v_period_start));
        v_current.put('current_period_end' , fn_ts_to_iso(v_period_end));
        -- Alias UX: proxima fecha de facturacion (= current_period_end; editable en APEX).
        v_current.put('next_billing_at'    , fn_ts_to_iso(v_period_end));
        v_current.put('grace_ends_at'      , fn_ts_to_iso(v_grace_ends_at));
        -- Estimado del proximo cargo neto (despues de saldo a favor).
        v_current.put('next_charge_estimate',
            GREATEST(0, (v_plan_monthly + v_addons_monthly) - NVL(v_account_balance, 0)));
        v_current.put('storage_used_bytes' , v_storage_used);
        v_current.put('storage_limit_bytes', v_storage_limit);
        v_current.put('supports_storage_addons', CASE WHEN v_cur_plan_code = c_plan_premium THEN 1 ELSE 0 END);
        v_current.put('billing_configured' , v_platform_ok);
        v_current.put('plan_monthly_amount', v_plan_monthly);
        v_current.put('addons_monthly_amount', v_addons_monthly);
        v_current.put('monthly_total', v_plan_monthly + v_addons_monthly);
        v_current.put('days_remaining_in_period', v_days_rem);
        v_current.put('period_days', v_period_days);
        v_current.put('account_balance', v_account_balance);
        v_current.put('auto_renew', v_auto_renew);
        v_current.put('canceled_at', fn_ts_to_iso(v_canceled_at));
        v_current.put('cancel_scheduled',
            CASE WHEN v_pending_code = c_plan_free THEN 1 ELSE 0 END);
        IF v_pending_code IS NOT NULL THEN
            v_current.put('pending_plan_code', v_pending_code);
            v_current.put('pending_plan_name', v_pending_name);
            v_current.put('pending_plan_change_at', fn_ts_to_iso(v_pending_at));
        ELSE
            v_current.put_null('pending_plan_code');
            v_current.put_null('pending_plan_name');
            v_current.put_null('pending_plan_change_at');
        END IF;
        v_current.put('active_storage_addons', v_active_addons);

        -- Planes comerciales (excluye FREE / Continuidad del catalogo de compra)
        FOR rec IN (
            SELECT id_plan, code, name, price_amount, currency, billing_period, storage_limit_bytes, sort_order
              FROM ref_plan
             WHERE is_active = 1
               AND code <> c_plan_free
             ORDER BY sort_order, id_plan
        ) LOOP
            DECLARE
                v_plan json_object_t := json_object_t();
                v_checkout NUMBER;
            BEGIN
                v_plan.put('id_plan'            , rec.id_plan);
                v_plan.put('code'               , rec.code);
                v_plan.put('name'               , rec.name);
                v_plan.put('price_amount'       , rec.price_amount);
                v_plan.put('currency'           , rec.currency);
                v_plan.put('billing_period'     , rec.billing_period);
                v_plan.put('storage_limit_bytes', rec.storage_limit_bytes);
                v_plan.put('is_current'         , CASE WHEN rec.id_plan = v_cur_plan_id THEN 1 ELSE 0 END);
                -- Precio a cobrar: fundadores pagan 50% del Premium de por vida.
                IF NVL(v_is_founder, 0) = 1 AND rec.code = c_plan_premium THEN
                    v_checkout := ROUND(rec.price_amount * 0.5);
                    v_plan.put('checkout_price_amount', v_checkout);
                    v_plan.put('founder_discount_percent', 50);
                ELSE
                    v_checkout := rec.price_amount;
                    v_plan.put('checkout_price_amount', v_checkout);
                    v_plan.put('founder_discount_percent', 0);
                END IF;
                -- Total mensual si eligen este plan (addons solo aplican en Premium).
                IF rec.code = c_plan_premium THEN
                    v_plan.put('monthly_total', v_checkout + v_addons_monthly);
                ELSE
                    v_plan.put('monthly_total', v_checkout);
                END IF;
                pr_put_features(rec.id_plan, v_plan);
                v_plans.append(v_plan);
            END;
        END LOOP;

        -- Addons de storage activos
        FOR rec IN (
            SELECT id_storage_addon, code, name, extra_bytes, price_amount, currency, billing_period, sort_order
              FROM ref_storage_addon
             WHERE is_active = 1
             ORDER BY sort_order, id_storage_addon
        ) LOOP
            DECLARE
                v_addon json_object_t := json_object_t();
                v_prorate NUMBER;
            BEGIN
                v_prorate := fn_prorate_amount(rec.price_amount, v_days_rem, v_period_days, 1);
                v_addon.put('id_storage_addon', rec.id_storage_addon);
                v_addon.put('code'            , rec.code);
                v_addon.put('name'            , rec.name);
                v_addon.put('extra_bytes'     , rec.extra_bytes);
                v_addon.put('price_amount'    , rec.price_amount);
                v_addon.put('currency'        , rec.currency);
                v_addon.put('billing_period'  , rec.billing_period);
                v_addon.put('prorate_amount'  , v_prorate);
                v_addon.put('cancel_credit_amount', fn_prorate_amount(rec.price_amount, v_days_rem, v_period_days, 0));
                v_addon.put('days_remaining'  , v_days_rem);
                v_addon.put('period_days'     , v_period_days);
                v_addons.append(v_addon);
            END;
        END LOOP;

        v_data.put('current'       , v_current);
        v_data.put('plans'         , v_plans);
        v_data.put('storage_addons', v_addons);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data'  , v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'No se encontr? suscripci?n para la organizaci?n.',
                po_response_body => po_response_body
            );
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_plans;

    --------------------------------------------------------------------------
    -- POST /workspace/subscription/checkout
    --------------------------------------------------------------------------
    PROCEDURE pr_create_checkout(
        pi_auth_header      IN  VARCHAR2,
        pi_body             IN  CLOB,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
    ) IS
        v_org_id      NUMBER;
        v_req         json_object_t;
        v_target_type VARCHAR2(20);
        v_plan_code   VARCHAR2(30);
        v_addon_code  VARCHAR2(30);
        v_invoice_id  NUMBER;
        v_hash        VARCHAR2(128);
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        -- Modelo "solo recurrente": ya no se redirige a pagopar.com/pagos.
        -- El cobro se hace con la tarjeta catastrada (uPay) via pago-recurrente/3.0.
        pr_assert_admin(pi_auth_header, v_org_id);

        v_req         := json_object_t.parse(pi_body);
        v_target_type := UPPER(TRIM(NVL(v_req.get_string('target_type'), 'PLAN')));
        v_plan_code   := UPPER(TRIM(v_req.get_string('plan_code')));
        v_addon_code  := UPPER(TRIM(v_req.get_string('addon_code')));

        pr_charge_target(
            pi_org_id           => v_org_id,
            pi_target_type      => v_target_type,
            pi_plan_code        => v_plan_code,
            pi_addon_code       => v_addon_code,
            po_invoice_id       => v_invoice_id,
            po_hash             => v_hash,
            pi_idempotency_key  => pi_idempotency_key
        );

        IF v_hash IS NULL AND v_target_type = 'STORAGE_ADDON' THEN
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            v_response.put('message', 'Almacenamiento activado. Se sumara al cargo de la proxima renovacion.');
            v_data.put_null('invoice_id');
            v_data.put_null('hash');
            v_data.put('status', 'ACTIVE');
            v_data.put('charged', 0);
            v_data.put('requires_polling', 0);
            v_data.put('target_type', v_target_type);
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Cobro iniciado con la tarjeta registrada. Se confirmara en unos instantes.');
        v_data.put('invoice_id', v_invoice_id);
        v_data.put('hash', v_hash);
        v_data.put('status', 'PENDING');
        v_data.put('charged', 1);
        v_data.put('requires_polling', 1);
        v_data.put('target_type', v_target_type);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'SUBSCRIPTION_CHECKOUT',
                pi_process_name    => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_CREATE_CHECKOUT',
                pi_http_method     => 'POST',
                pi_endpoint        => '/workspace/subscription/checkout',
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body    => pi_body
            );
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_create_checkout;

    --------------------------------------------------------------------------
    -- POST /workspace/subscription/change-plan
    -- Downgrade: agenda hasta current_period_end (sin credito de plan).
    -- Mantener plan actual: cancela agenda. Upgrade pago: usar activate.
    --------------------------------------------------------------------------
    PROCEDURE pr_change_plan(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id           NUMBER;
        v_req              json_object_t;
        v_plan_code        VARCHAR2(30);
        v_plan_id          ref_plan.id_plan%TYPE;
        v_plan_price       NUMBER;
        v_cur_plan_id      NUMBER;
        v_cur_plan_code    VARCHAR2(30);
        v_cur_plan_price   NUMBER;
        v_period_end       TIMESTAMP WITH TIME ZONE;
        v_billing_exempt   org_subscription.billing_exempt%TYPE;
        v_response         json_object_t := json_object_t();
        v_data             json_object_t := json_object_t();
        v_scheduled        NUMBER := 0;
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);

        v_req       := json_object_t.parse(pi_body);
        v_plan_code := UPPER(TRIM(v_req.get_string('plan_code')));

        BEGIN
            SELECT id_plan, price_amount
              INTO v_plan_id, v_plan_price
              FROM ref_plan WHERE code = v_plan_code AND is_active = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Plan no valido.');
        END;

        IF v_plan_code = c_plan_free THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Para terminar la suscripcion usa Terminar suscripcion (no Pasar a Base).'
            );
        END IF;

        SELECT s.pln_id_plan, p.code, p.price_amount, s.current_period_end, s.billing_exempt
          INTO v_cur_plan_id, v_cur_plan_code, v_cur_plan_price, v_period_end, v_billing_exempt
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        -- Cancelar downgrade / terminacion agendada (pedir el plan actual).
        IF v_plan_id = v_cur_plan_id THEN
            UPDATE /*+ no_parallel */ org_subscription
               SET pending_pln_id_plan    = NULL,
                   pending_plan_change_at = NULL,
                   auto_renew             = 1,
                   canceled_at            = NULL,
                   updated_at             = systimestamp
             WHERE org_id_organization = v_org_id;
            COMMIT;
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            v_response.put('message', 'Cambio de plan cancelado. Seguis con ' || v_cur_plan_code || '.');
            v_data.put('plan_code', v_cur_plan_code);
            v_data.put('scheduled', 0);
            v_data.put('pending_cleared', 1);
            v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        -- Upgrade (precio mayor): requiere cobro via activate, salvo exentos.
        IF NVL(v_plan_price, 0) > NVL(v_cur_plan_price, 0) THEN
            IF NVL(v_billing_exempt, 0) = 1 THEN
                UPDATE /*+ no_parallel */ org_subscription
                   SET pln_id_plan            = v_plan_id,
                       pending_pln_id_plan    = NULL,
                       pending_plan_change_at = NULL,
                       updated_at             = systimestamp
                 WHERE org_id_organization = v_org_id;
                pr_refresh_storage_limit(v_org_id);
                COMMIT;
                po_status_code := pkg_aox_util.c_success_ok_code;
                v_response.put('status', 'success');
                v_response.put('message', 'Plan actualizado correctamente.');
                v_data.put('plan_code', v_plan_code);
                v_data.put('scheduled', 0);
                v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
                v_response.put('data', v_data);
                po_response_body := v_response.to_clob();
                RETURN;
            END IF;
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'Para subir de plan necesitás completar el pago con tu tarjeta.'
            );
        END IF;

        -- Downgrade / mismo precio hacia Base: agendar al fin del ciclo (sin credito de plan).
        -- Cliente de pago: limpia cancelacion (auto_renew) y agenda BASE.
        IF v_period_end IS NULL THEN
            v_period_end := ADD_MONTHS(systimestamp, 1);
        END IF;

        UPDATE /*+ no_parallel */ org_subscription
           SET pending_pln_id_plan    = v_plan_id,
               pending_plan_change_at = v_period_end,
               auto_renew             = 1,
               canceled_at            = NULL,
               updated_at             = systimestamp
         WHERE org_id_organization = v_org_id;
        COMMIT;
        v_scheduled := 1;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message',
            'Cambio a ' || v_plan_code || ' programado. Seguis con ' || v_cur_plan_code
            || ' hasta el fin del periodo. Luego se cobra la tarifa de ' || v_plan_code || '.');
        v_data.put('plan_code', v_cur_plan_code);
        v_data.put('pending_plan_code', v_plan_code);
        v_data.put('pending_plan_change_at', fn_ts_to_iso(v_period_end));
        v_data.put('scheduled', v_scheduled);
        v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_change_plan;

    --------------------------------------------------------------------------
    -- POST /workspace/subscription/cancel
    --------------------------------------------------------------------------
    PROCEDURE pr_cancel_subscription(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_cur_plan_code  VARCHAR2(30);
        v_period_end     TIMESTAMP WITH TIME ZONE;
        v_billing_exempt NUMBER(1,0);
        v_status         VARCHAR2(20);
        v_free_id        NUMBER;
        v_response       json_object_t := json_object_t();
        v_data           json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);

        BEGIN
            SELECT id_plan INTO v_free_id FROM ref_plan WHERE code = c_plan_free AND is_active = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Plan de continuidad no configurado.');
        END;

        SELECT p.code, s.current_period_end, NVL(s.billing_exempt, 0), s.status
          INTO v_cur_plan_code, v_period_end, v_billing_exempt, v_status
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        IF v_billing_exempt = 1 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'Las cuentas exentas de facturacion no usan Cancelar suscripcion.'
            );
        END IF;

        IF v_cur_plan_code = c_plan_free OR v_status = 'READ_ONLY' THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Tu cuenta ya esta en modo continuidad / solo lectura. Renova un plan para reactivar.'
            );
        END IF;

        IF v_period_end IS NULL THEN
            v_period_end := ADD_MONTHS(systimestamp, 1);
        END IF;

        UPDATE /*+ no_parallel */ org_subscription
           SET pending_pln_id_plan    = v_free_id,
               pending_plan_change_at = v_period_end,
               auto_renew             = 0,
               canceled_at            = NVL(canceled_at, systimestamp),
               updated_at             = systimestamp
         WHERE org_id_organization = v_org_id;

        -- Si el periodo ya vencio, aplicar de inmediato.
        pr_apply_due_pending_plan(v_org_id);
        COMMIT;

        DECLARE
            v_pending_id   NUMBER;
            v_pending_at   TIMESTAMP WITH TIME ZONE;
            v_pending_code VARCHAR2(30);
        BEGIN
            SELECT s.pending_pln_id_plan, s.pending_plan_change_at, p.code, s.status
              INTO v_pending_id, v_pending_at, v_cur_plan_code, v_status
              FROM org_subscription s
              JOIN ref_plan p ON p.id_plan = s.pln_id_plan
             WHERE s.org_id_organization = v_org_id;

            IF v_pending_id IS NOT NULL THEN
                SELECT code INTO v_pending_code FROM ref_plan WHERE id_plan = v_pending_id;
            END IF;

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            IF v_status = 'READ_ONLY' OR v_cur_plan_code = c_plan_free THEN
                v_response.put('message',
                    'Suscripcion terminada. Tu cuenta quedo en modo solo lectura (Continuidad).');
                v_data.put('scheduled', 0);
                v_data.put('applied', 1);
            ELSE
                v_response.put('message',
                    'Cancelacion programada. Seguis con ' || v_cur_plan_code
                    || ' hasta el fin del periodo; luego pasas a Continuidad (solo lectura) sin cobros.');
                v_data.put('scheduled', 1);
                v_data.put('applied', 0);
                v_data.put('pending_plan_code', NVL(v_pending_code, c_plan_free));
                v_data.put('pending_plan_change_at', fn_ts_to_iso(v_pending_at));
            END IF;
            v_data.put('plan_code', v_cur_plan_code);
            v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
        END;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_cancel_subscription;

    --------------------------------------------------------------------------
    -- POST /workspace/subscription/cancel/undo
    --------------------------------------------------------------------------
    PROCEDURE pr_undo_cancel_subscription(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_cur_plan_code VARCHAR2(30);
        v_pending_id    NUMBER;
        v_pending_code  VARCHAR2(30);
        v_response      json_object_t := json_object_t();
        v_data          json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);

        SELECT p.code, s.pending_pln_id_plan
          INTO v_cur_plan_code, v_pending_id
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        IF v_pending_id IS NULL THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'No hay una cancelacion programada para deshacer.'
            );
        END IF;

        SELECT code INTO v_pending_code FROM ref_plan WHERE id_plan = v_pending_id;
        IF v_pending_code <> c_plan_free THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Hay un cambio de plan programado (no una cancelacion). Usa Mantener plan.'
            );
        END IF;

        IF v_cur_plan_code = c_plan_free THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'La cancelacion ya se aplico. Renova un plan Base o Premium para reactivar.'
            );
        END IF;

        UPDATE /*+ no_parallel */ org_subscription
           SET pending_pln_id_plan    = NULL,
               pending_plan_change_at = NULL,
               auto_renew             = 1,
               canceled_at            = NULL,
               updated_at             = systimestamp
         WHERE org_id_organization = v_org_id;
        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Cancelacion anulada. Seguis con ' || v_cur_plan_code || '.');
        v_data.put('plan_code', v_cur_plan_code);
        v_data.put('scheduled', 0);
        v_data.put('pending_cleared', 1);
        v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_undo_cancel_subscription;

    --------------------------------------------------------------------------
    -- POST /workspace/subscription/addon/cancel
    --------------------------------------------------------------------------
    PROCEDURE pr_cancel_storage_addon(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_req         json_object_t;
        v_addon_code  VARCHAR2(30);
        v_addon_id    NUMBER;
        v_addon_price NUMBER;
        v_addon_name  VARCHAR2(150);
        v_row_id      NUMBER;
        v_qty         NUMBER;
        v_credit      NUMBER;
        v_balance     NUMBER;
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);
        v_req        := json_object_t.parse(pi_body);
        v_addon_code := UPPER(TRIM(v_req.get_string('addon_code')));

        BEGIN
            SELECT id_storage_addon, price_amount, name
              INTO v_addon_id, v_addon_price, v_addon_name
              FROM ref_storage_addon
             WHERE code = v_addon_code AND is_active = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Paquete de almacenamiento no valido.');
        END;

        BEGIN
            SELECT id_org_storage_addon, quantity
              INTO v_row_id, v_qty
              FROM org_storage_addon
             WHERE org_id_organization = v_org_id
               AND sad_id_storage_addon = v_addon_id
               AND status = 'ACTIVE'
             ORDER BY id_org_storage_addon DESC
             FETCH FIRST 1 ROW ONLY;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'No tenes ese paquete de almacenamiento activo.');
        END;

        v_credit := fn_unused_credit_amount(v_org_id, v_addon_price);
        pr_grant_credit(v_org_id, v_credit, 'CANCEL_ADDON', v_addon_code, NULL);

        IF v_qty > 1 THEN
            UPDATE /*+ no_parallel */ org_storage_addon
               SET quantity = quantity - 1
             WHERE id_org_storage_addon = v_row_id;
        ELSE
            UPDATE /*+ no_parallel */ org_storage_addon
               SET status  = 'CANCELED',
                   ends_at = systimestamp,
                   quantity = 1
             WHERE id_org_storage_addon = v_row_id;
        END IF;

        pr_refresh_storage_limit(v_org_id);

        SELECT NVL(account_balance, 0)
          INTO v_balance
          FROM org_subscription
         WHERE org_id_organization = v_org_id;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message',
            CASE WHEN v_credit > 0
                 THEN 'Almacenamiento cancelado. Se acreditaron ' || TO_CHAR(v_credit) || ' Gs a favor.'
                 ELSE 'Almacenamiento cancelado.'
            END);
        v_data.put('addon_code', v_addon_code);
        v_data.put('addon_name', v_addon_name);
        v_data.put('credit_granted', v_credit);
        v_data.put('account_balance', v_balance);
        v_data.put('storage_limit_bytes', pkg_aox_subscription_api.fn_get_storage_limit_bytes(v_org_id));
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_cancel_storage_addon;

    --------------------------------------------------------------------------
    -- GET /workspace/subscription/invoice/:hash
    --------------------------------------------------------------------------
    PROCEDURE pr_get_invoice_by_hash(
        pi_auth_header   IN  VARCHAR2,
        pi_hash          IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token inv?lido o sin organizaci?n asociada.');
        END IF;

        FOR rec IN (
            SELECT i.id_invoice, i.invoice_type, i.status, i.amount, i.currency,
                   i.description, p.code AS plan_code, i.paid_at, i.external_reference
              FROM org_subscription_invoice i
              LEFT JOIN ref_plan p ON p.id_plan = i.pln_id_plan
             WHERE i.external_reference = TRIM(pi_hash)
               AND i.org_id_organization = v_org_id
             ORDER BY i.id_invoice DESC
             FETCH FIRST 1 ROW ONLY
        ) LOOP
            v_data.put('invoice_id'  , rec.id_invoice);
            v_data.put('invoice_type', rec.invoice_type);
            v_data.put('status'      , rec.status);
            v_data.put('amount'      , rec.amount);
            v_data.put('currency'    , rec.currency);
            v_data.put('description' , rec.description);
            v_data.put('plan_code'   , rec.plan_code);
            v_data.put('paid_at'     , fn_ts_to_iso(rec.paid_at));
            v_data.put('hash'        , rec.external_reference);
            v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        END LOOP;

        po_status_code := pkg_aox_util.c_not_found_code;
        pkg_aox_util.pr_build_api_error_response(
            pi_status_code   => po_status_code,
            pi_api_code      => pkg_aox_util.c_api_code_not_found,
            pi_message       => 'Factura no encontrada.',
            po_response_body => po_response_body
        );
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_invoice_by_hash;

    --------------------------------------------------------------------------
    -- GET /workspace/subscription/invoices
    --------------------------------------------------------------------------
    PROCEDURE pr_list_invoices(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
        v_items    json_array_t  := json_array_t();
        v_period_end TIMESTAMP WITH TIME ZONE;
        v_balance  NUMBER;
        v_plan_amt NUMBER;
        v_addon_amt NUMBER;
        v_plan_code VARCHAR2(30);
        v_plan_name VARCHAR2(100);
        v_founder  NUMBER;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token invalido o sin organizacion asociada.');
        END IF;

        SELECT s.current_period_end, NVL(s.account_balance, 0), NVL(s.is_founder, 0),
               p.code, p.name,
               CASE WHEN NVL(s.is_founder, 0) = 1 AND p.code = c_plan_premium
                    THEN ROUND(p.price_amount * 0.5) ELSE p.price_amount END
          INTO v_period_end, v_balance, v_founder, v_plan_code, v_plan_name, v_plan_amt
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        v_addon_amt := fn_addons_monthly_total(v_org_id);

        FOR rec IN (
            SELECT i.id_invoice, i.invoice_type, i.status, i.amount,
                   NVL(i.gross_amount, i.amount) AS gross_amount,
                   NVL(i.credit_applied, 0) AS credit_applied,
                   i.currency, i.description, i.payment_provider,
                   i.created_at, i.paid_at, i.period_start, i.period_end,
                   i.external_reference, p.code AS plan_code, p.name AS plan_name
              FROM org_subscription_invoice i
              LEFT JOIN ref_plan p ON p.id_plan = i.pln_id_plan
             WHERE i.org_id_organization = v_org_id
             ORDER BY i.created_at DESC, i.id_invoice DESC
             FETCH FIRST 50 ROWS ONLY
        ) LOOP
            DECLARE v_item json_object_t := json_object_t();
            BEGIN
                v_item.put('invoice_id', rec.id_invoice);
                v_item.put('invoice_type', rec.invoice_type);
                v_item.put('status', rec.status);
                v_item.put('amount', rec.amount);
                v_item.put('gross_amount', rec.gross_amount);
                v_item.put('credit_applied', rec.credit_applied);
                v_item.put('currency', rec.currency);
                v_item.put('description', rec.description);
                v_item.put('payment_provider', rec.payment_provider);
                v_item.put('plan_code', rec.plan_code);
                v_item.put('plan_name', rec.plan_name);
                v_item.put('created_at', fn_ts_to_iso(rec.created_at));
                v_item.put('paid_at', fn_ts_to_iso(rec.paid_at));
                v_item.put('period_start', fn_ts_to_iso(rec.period_start));
                v_item.put('period_end', fn_ts_to_iso(rec.period_end));
                v_item.put('hash', rec.external_reference);
                v_items.append(v_item);
            END;
        END LOOP;

        v_data.put('next_billing_at', fn_ts_to_iso(v_period_end));
        v_data.put('plan_code', v_plan_code);
        v_data.put('plan_name', v_plan_name);
        v_data.put('plan_monthly_amount', v_plan_amt);
        v_data.put('addons_monthly_amount', v_addon_amt);
        v_data.put('monthly_total', v_plan_amt + v_addon_amt);
        v_data.put('account_balance', v_balance);
        v_data.put('next_charge_estimate', GREATEST(0, (v_plan_amt + v_addon_amt) - v_balance));
        v_data.put('invoices', v_items);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_invoices;

    --------------------------------------------------------------------------
    -- POST /pagopar/subscription/webhook
    --------------------------------------------------------------------------
    PROCEDURE pr_subscription_webhook(
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_req            json_object_t;
        v_result_arr     json_array_t;
        v_result_obj     json_object_t;
        v_hash_pedido    VARCHAR2(128);
        v_token_received VARCHAR2(256);
        v_token_expected VARCHAR2(256);
        v_pagado         BOOLEAN;

        v_invoice_id     NUMBER;
        v_org_id         NUMBER;
        v_invoice_type   VARCHAR2(20);
        v_status         VARCHAR2(20);
        v_plan_id        NUMBER;
        v_addon_id       NUMBER;
        v_invoice_amount NUMBER;
        v_credit_applied NUMBER;
        v_period_start   TIMESTAMP WITH TIME ZONE;
        v_period_end     TIMESTAMP WITH TIME ZONE;
        v_desc           VARCHAR2(255);

        v_public_key     VARCHAR2(500);
        v_private_key    VARCHAR2(500);
        v_echo           json_array_t := json_array_t();
    BEGIN
        v_req        := json_object_t.parse(pi_body);
        v_result_arr := v_req.get_array('resultado');
        v_result_obj := TREAT(v_result_arr.get(0) AS json_object_t);

        v_hash_pedido    := v_result_obj.get_string('hash_pedido');
        v_token_received := LOWER(TRIM(v_result_obj.get_string('token')));
        v_pagado         := v_result_obj.get_boolean('pagado');

        BEGIN
            -- FOR UPDATE: si dos entregas concurrentes del mismo webhook llegan en simultaneo,
            -- la segunda espera a que la primera confirme/commitee y ve status ya actualizado
            -- (cae en el check "ya esta PAID" de abajo en vez de reprocesar).
            SELECT id_invoice, org_id_organization, invoice_type, status, pln_id_plan,
                   sad_id_storage_addon, amount, credit_applied, period_start, period_end, description
              INTO v_invoice_id, v_org_id, v_invoice_type, v_status, v_plan_id,
                   v_addon_id, v_invoice_amount, v_credit_applied, v_period_start, v_period_end, v_desc
              FROM org_subscription_invoice
             WHERE external_reference = v_hash_pedido
             ORDER BY id_invoice DESC
             FETCH FIRST 1 ROW ONLY
               FOR UPDATE OF status;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            po_status_code := 404;
            po_response_body := '{"status":"error","message":"Factura no encontrada."}';
            RETURN;
        END;

        pr_get_platform_keys(v_public_key, v_private_key);
        v_token_expected := pkg_aox_pagopar_api.fn_pagopar_sha1_token(v_private_key || v_hash_pedido);

        IF v_token_expected <> v_token_received THEN
            po_status_code := 403;
            po_response_body := '{"status":"error","message":"Token inv?lido."}';
            RETURN;
        END IF;

        -- Idempotencia: si ya est? pagada, devolvemos OK (echo) sin re-procesar.
        IF v_status = 'PAID' THEN
            v_echo.append(v_result_obj);
            po_status_code := 200;
            po_response_body := v_echo.to_clob();
            RETURN;
        END IF;

        IF v_pagado THEN
            UPDATE /*+ no_parallel */ org_subscription_invoice
               SET status = 'PAID', paid_at = systimestamp
             WHERE id_invoice = v_invoice_id;

            -- Consumir credito declarado en la factura (idempotente via ledger).
            pr_consume_credit(v_org_id, NVL(v_credit_applied, 0), v_invoice_id);

            IF v_invoice_type = 'SUBSCRIPTION' THEN
                pr_fulfill_paid_subscription(v_org_id, v_plan_id);

            ELSIF v_invoice_type = 'STORAGE_ADDON' THEN
                IF v_addon_id IS NULL THEN
                    BEGIN
                        SELECT id_storage_addon INTO v_addon_id
                          FROM ref_storage_addon
                         WHERE price_amount = (
                                   SELECT NVL(gross_amount, amount)
                                     FROM org_subscription_invoice
                                    WHERE id_invoice = v_invoice_id
                               )
                           AND is_active = 1
                         FETCH FIRST 1 ROW ONLY;
                    EXCEPTION WHEN NO_DATA_FOUND THEN
                        v_addon_id := NULL;
                    END;
                END IF;
                pr_fulfill_paid_addon(v_org_id, v_addon_id);
            END IF;

            -- Encolar FE en la misma transaccion del PAID; despachar HTTP despues del COMMIT.
            pr_enqueue_einvoice_dispatch(v_invoice_id);
        ELSE
            UPDATE /*+ no_parallel */ org_subscription_invoice
               SET status = 'FAILED'
             WHERE id_invoice = v_invoice_id
               AND status = 'PENDING';
            -- FAILED: no se consume credito (sigue disponible).
        END IF;

        COMMIT;

        IF v_pagado THEN
            BEGIN
                pr_dispatch_einvoice_outbox(5);
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END IF;

        v_echo.append(v_result_obj);
        po_status_code := 200;
        po_response_body := v_echo.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'SUBSCRIPTION_WEBHOOK',
                pi_process_name    => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_SUBSCRIPTION_WEBHOOK',
                pi_http_method     => 'POST',
                pi_endpoint        => '/pagopar/subscription/webhook',
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body    => pi_body
            );
            po_status_code := 500;
            po_response_body := '{"status":"error","message":"Error interno procesando webhook de suscripci?n."}';
    END pr_subscription_webhook;

    --------------------------------------------------------------------------
    -- Tarjetas catastradas (uPay) + activacion + ciclo de cobro
    --------------------------------------------------------------------------
    PROCEDURE pr_build_cards_json(pi_org_id IN NUMBER, po_cards OUT json_array_t) IS
        v_card json_object_t;
    BEGIN
        po_cards := json_array_t();
        FOR rec IN (
            SELECT id_payment_card, provider, brand, masked_number, card_type, issuer, is_default
              FROM org_payment_card
             WHERE org_id_organization = pi_org_id
               AND status = 'ACTIVE'
             ORDER BY is_default DESC, confirmed_at DESC NULLS LAST, id_payment_card DESC
        ) LOOP
            v_card := json_object_t();
            v_card.put('id', rec.id_payment_card);
            v_card.put('provider', rec.provider);
            v_card.put('brand', rec.brand);
            v_card.put('masked_number', rec.masked_number);
            v_card.put('card_type', rec.card_type);
            v_card.put('issuer', rec.issuer);
            v_card.put('is_default', rec.is_default);
            po_cards.append(v_card);
        END LOOP;
    END pr_build_cards_json;

    PROCEDURE pr_add_card(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_req         json_object_t;
        v_provider    VARCHAR2(20);
        v_public_key  VARCHAR2(500);
        v_private_key VARCHAR2(500);
        v_name        organization.name%TYPE;
        v_email       organization.company_email%TYPE;
        v_phone       VARCHAR2(60);
        v_return_url  VARCHAR2(500) := NVL(fn_get_parameter('PAGOPAR_UPAY_RETURN_URL'), 'https://hasel.app/panel/plan');
        v_iframe_base VARCHAR2(500) := NVL(fn_get_parameter('PAGOPAR_UPAY_IFRAME_URL'), 'https://www.pagopar.com/upay-iframe/?id-form=');
        v_raw         CLOB;
        v_resp        json_object_t;
        v_id_form     VARCHAR2(200);
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);
        v_req      := CASE WHEN pi_body IS NOT NULL AND DBMS_LOB.GETLENGTH(pi_body) > 0 THEN json_object_t.parse(pi_body) ELSE json_object_t() END;
        v_provider := NVL(TRIM(v_req.get_string('provider')), NVL(fn_get_parameter('SUBSCRIPTION_CARD_PROVIDER'), 'uPay'));

        pr_get_platform_keys(v_public_key, v_private_key);
        pr_get_org_contact(v_org_id, v_name, v_email, v_phone);

        -- agregar-cliente (idempotente): si falla por token/permiso, corta con el mensaje de Pagopar.
        v_raw  := pkg_aox_pagopar_api.fn_add_customer(v_public_key, v_private_key, TO_CHAR(v_org_id), v_name, v_email, v_phone);
        v_resp := json_object_t.parse(v_raw);
        IF NOT v_resp.get_boolean('respuesta') THEN
            RAISE_APPLICATION_ERROR(-20033, NVL(v_resp.get_string('resultado'), 'Pagopar rechazo el alta del cliente.'));
        END IF;

        -- agregar-tarjeta -> id-form para el iframe.
        v_raw  := pkg_aox_pagopar_api.fn_add_card(v_public_key, v_private_key, TO_CHAR(v_org_id), v_return_url, v_provider);
        v_resp := json_object_t.parse(v_raw);
        IF NOT v_resp.get_boolean('respuesta') THEN
            RAISE_APPLICATION_ERROR(-20034, NVL(v_resp.get_string('resultado'), 'Pagopar rechazo el alta de la tarjeta.'));
        END IF;
        v_id_form := v_resp.get_string('resultado');

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_data.put('id_form', v_id_form);
        v_data.put('iframe_url', v_iframe_base || v_id_form);
        v_data.put('provider', v_provider);
        v_data.put('return_url', v_return_url);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_api(
                pi_api_name => 'SUBSCRIPTION_CARD_ADD', pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_ADD_CARD',
                pi_http_method => 'POST', pi_endpoint => '/workspace/subscription/card/add', pi_status => 'ERROR',
                pi_error_code => SQLCODE, pi_error_message => SQLERRM,
                pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK, pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body => pi_body
            );
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_add_card;

    PROCEDURE pr_confirm_card(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_public_key  VARCHAR2(500);
        v_private_key VARCHAR2(500);
        v_return_url  VARCHAR2(500) := NVL(fn_get_parameter('PAGOPAR_UPAY_RETURN_URL'), 'https://hasel.app/panel/plan');
        v_list_raw    CLOB;
        v_cards       json_array_t;
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);
        pr_get_platform_keys(v_public_key, v_private_key);

        -- confirmar-tarjeta es obligatorio tras el retorno del iframe (exito o fallo).
        BEGIN
            v_list_raw := pkg_aox_pagopar_api.fn_confirm_card(v_public_key, v_private_key, TO_CHAR(v_org_id), v_return_url);
        EXCEPTION WHEN OTHERS THEN
            NULL; -- si confirmar falla, seguimos e intentamos listar igual
        END;

        -- listar-tarjeta -> persistir tarjetas ACTIVE.
        v_list_raw := pkg_aox_pagopar_api.fn_list_cards(v_public_key, v_private_key, TO_CHAR(v_org_id));
        pr_sync_cards(v_org_id, v_list_raw);
        COMMIT;

        pr_build_cards_json(v_org_id, v_cards);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_data.put('cards', v_cards);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_log_api(
                pi_api_name => 'SUBSCRIPTION_CARD_CONFIRM', pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_CONFIRM_CARD',
                pi_http_method => 'POST', pi_endpoint => '/workspace/subscription/card/confirm', pi_status => 'ERROR',
                pi_error_code => SQLCODE, pi_error_message => SQLERRM,
                pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK, pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body => pi_body
            );
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_confirm_card;

    PROCEDURE pr_list_cards(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_cards    json_array_t;
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);
        pr_build_cards_json(v_org_id, v_cards);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_data.put('cards', v_cards);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_cards;

    PROCEDURE pr_delete_card(
        pi_auth_header   IN  VARCHAR2,
        pi_card_id       IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_public_key  VARCHAR2(500);
        v_private_key VARCHAR2(500);
        v_card_pp_id  org_payment_card.pagopar_card_id%TYPE;
        v_was_default org_payment_card.is_default%TYPE;
        v_alias_token VARCHAR2(256);
        v_raw         CLOB;
        v_resp        json_object_t;
        v_response    json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);

        BEGIN
            SELECT pagopar_card_id, is_default INTO v_card_pp_id, v_was_default
              FROM org_payment_card
             WHERE id_payment_card = pi_card_id
               AND org_id_organization = v_org_id
               AND status = 'ACTIVE';
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Tarjeta no encontrada.');
        END;

        pr_get_platform_keys(v_public_key, v_private_key);

        -- alias_token temporal (15 min) para poder eliminar en Pagopar.
        IF v_card_pp_id IS NOT NULL THEN
            v_alias_token := fn_alias_token_for(v_org_id, v_card_pp_id, v_public_key, v_private_key);
            IF v_alias_token IS NOT NULL THEN
                v_raw  := pkg_aox_pagopar_api.fn_delete_card(v_public_key, v_private_key, TO_CHAR(v_org_id), v_alias_token);
                v_resp := json_object_t.parse(v_raw);
                IF NOT v_resp.get_boolean('respuesta') THEN
                    RAISE_APPLICATION_ERROR(-20035, NVL(v_resp.get_string('resultado'), 'Pagopar rechazo la eliminacion de la tarjeta.'));
                END IF;
            END IF;
        END IF;

        UPDATE /*+ no_parallel */ org_payment_card
           SET status = 'DELETED', is_default = 0, updated_at = systimestamp
         WHERE id_payment_card = pi_card_id;

        -- Promover otra tarjeta ACTIVE a default si eliminamos la default.
        IF NVL(v_was_default, 0) = 1 THEN
            UPDATE /*+ no_parallel */ org_payment_card
               SET is_default = 1, updated_at = systimestamp
             WHERE id_payment_card = (
                 SELECT id_payment_card FROM (
                     SELECT id_payment_card FROM org_payment_card
                      WHERE org_id_organization = v_org_id AND status = 'ACTIVE'
                      ORDER BY confirmed_at DESC NULLS LAST, id_payment_card DESC
                 ) WHERE ROWNUM = 1
             );
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Tarjeta eliminada.');
        v_response.put('data', json_object_t());
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_delete_card;

    PROCEDURE pr_activate_subscription(
        pi_auth_header      IN  VARCHAR2,
        pi_body             IN  CLOB,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
    ) IS
        v_org_id      NUMBER;
        v_req         json_object_t;
        v_target_type VARCHAR2(20);
        v_plan_code   VARCHAR2(30);
        v_addon_code  VARCHAR2(30);
        v_invoice_id  NUMBER;
        v_hash        VARCHAR2(128);
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);
        v_req         := CASE WHEN pi_body IS NOT NULL AND DBMS_LOB.GETLENGTH(pi_body) > 0 THEN json_object_t.parse(pi_body) ELSE json_object_t() END;
        v_target_type := UPPER(TRIM(NVL(v_req.get_string('target_type'), 'PLAN')));
        v_plan_code   := UPPER(TRIM(NVL(v_req.get_string('plan_code'), c_plan_premium)));
        v_addon_code  := UPPER(TRIM(v_req.get_string('addon_code')));

        -- Upgrade/activacion limpia cualquier downgrade pendiente.
        IF v_target_type = 'PLAN' THEN
            UPDATE /*+ no_parallel */ org_subscription
               SET pending_pln_id_plan    = NULL,
                   pending_plan_change_at = NULL,
                   updated_at             = systimestamp
             WHERE org_id_organization = v_org_id;
            COMMIT;
        END IF;

        pr_charge_target(
            pi_org_id           => v_org_id,
            pi_target_type      => v_target_type,
            pi_plan_code        => v_plan_code,
            pi_addon_code       => v_addon_code,
            po_invoice_id       => v_invoice_id,
            po_hash             => v_hash,
            pi_idempotency_key  => pi_idempotency_key
        );

        -- Sin hash: alta gratis (addon 0 dias) o factura cubierta 100% por saldo a favor.
        IF v_hash IS NULL THEN
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            IF v_invoice_id IS NOT NULL THEN
                v_response.put('message', 'Activado usando tu saldo a favor. No hubo cargo en la tarjeta.');
                v_data.put('invoice_id', v_invoice_id);
                v_data.put('status', 'PAID');
            ELSIF v_target_type = 'STORAGE_ADDON' THEN
                v_response.put('message', 'Almacenamiento activado. Se sumara al cargo de la proxima renovacion.');
                v_data.put_null('invoice_id');
                v_data.put('status', 'ACTIVE');
                v_data.put('prorated', 0);
            ELSE
                v_response.put('message', 'Activacion completada.');
                v_data.put_null('invoice_id');
                v_data.put('status', 'ACTIVE');
            END IF;
            v_data.put_null('hash');
            v_data.put('requires_polling', 0);
            v_data.put('target_type', v_target_type);
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Suscripcion activada. Estamos confirmando el cobro.');
        v_data.put('invoice_id', v_invoice_id);
        v_data.put('hash', v_hash);
        v_data.put('status', 'PENDING');
        v_data.put('requires_polling', 1);
        v_data.put('target_type', v_target_type);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_log_api(
                pi_api_name => 'SUBSCRIPTION_ACTIVATE', pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_ACTIVATE_SUBSCRIPTION',
                pi_http_method => 'POST', pi_endpoint => '/workspace/subscription/activate', pi_status => 'ERROR',
                pi_error_code => SQLCODE, pi_error_message => SQLERRM,
                pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK, pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body => pi_body
            );
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_activate_subscription;

    PROCEDURE pr_run_billing_cycle IS
        v_invoice_id NUMBER;
        v_hash       VARCHAR2(128);
        v_plan_code  VARCHAR2(30);
        v_auto_renew NUMBER(1,0);
        v_max_retry  NUMBER := NVL(TO_NUMBER(fn_get_parameter('SUBSCRIPTION_MAX_CHARGE_RETRIES')), 4);
        TYPE t_org_set IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER;
        v_touched    t_org_set;
        v_org_id     NUMBER;
    BEGIN
        -- Guardrail de ambiente: en DEV (BILLING_ENABLED=0) el job global no cobra.
        IF NVL(fn_get_parameter('BILLING_ENABLED'), '0') <> '1' THEN
            pkg_aox_util.pr_log_api(
                pi_api_name => 'SUBSCRIPTION_BILLING_CYCLE',
                pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_RUN_BILLING_CYCLE',
                pi_http_method => 'JOB',
                pi_endpoint => 'HASEL_SUBSCRIPTION_BILLING_CYCLE',
                pi_status => 'SKIPPED',
                pi_error_message => 'BILLING_ENABLED!=1'
            );
            RETURN;
        END IF;

        -- 1) Aplicar pending vencidos (incluye Terminar→FREE aunque auto_renew=0).
        FOR rec IN (
            SELECT s.org_id_organization AS org_id
              FROM org_subscription s
             WHERE s.pending_pln_id_plan IS NOT NULL
               AND (
                    (s.pending_plan_change_at IS NOT NULL AND s.pending_plan_change_at <= systimestamp)
                 OR (s.current_period_end IS NOT NULL AND s.current_period_end <= systimestamp)
               )
        ) LOOP
            BEGIN
                pr_apply_due_pending_plan(rec.org_id);
                v_touched(rec.org_id) := TRUE;
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    ROLLBACK;
                    pkg_aox_util.pr_log_api(
                        pi_api_name => 'SUBSCRIPTION_BILLING_CYCLE', pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_APPLY_PENDING',
                        pi_http_method => 'JOB', pi_endpoint => 'HASEL_SUBSCRIPTION_BILLING_CYCLE', pi_status => 'ERROR',
                        pi_error_code => SQLCODE, pi_error_message => SQLERRM,
                        pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK, pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                        pi_request_body => TO_CLOB('org_id=' || rec.org_id)
                    );
            END;
        END LOOP;

        -- 2) Cobrar renovaciones (Base y Premium). No cobra FREE ni auto_renew=0.
        FOR rec IN (
            SELECT s.org_id_organization AS org_id
              FROM org_subscription s
             WHERE s.status IN ('ACTIVE', 'PAST_DUE')
               AND NVL(s.auto_renew, 1) = 1
               AND NVL(s.billing_exempt, 0) = 0
               AND s.current_period_end IS NOT NULL
               AND s.current_period_end <= systimestamp
               AND NVL(s.charge_retry_count, 0) < v_max_retry
        ) LOOP
            BEGIN
                SELECT p.code, NVL(s.auto_renew, 1)
                  INTO v_plan_code, v_auto_renew
                  FROM org_subscription s
                  JOIN ref_plan p ON p.id_plan = s.pln_id_plan
                 WHERE s.org_id_organization = rec.org_id;

                IF v_plan_code = c_plan_free OR v_auto_renew = 0 THEN
                    CONTINUE;
                END IF;

                UPDATE /*+ no_parallel */ org_subscription
                   SET charge_retry_count = NVL(charge_retry_count, 0) + 1,
                       last_charge_at     = systimestamp,
                       updated_at         = systimestamp
                 WHERE org_id_organization = rec.org_id;
                COMMIT;

                pr_charge_target(
                    pi_org_id           => rec.org_id,
                    pi_target_type      => 'CONSOLIDATED',
                    pi_plan_code        => v_plan_code,
                    pi_addon_code       => NULL,
                    po_invoice_id       => v_invoice_id,
                    po_hash             => v_hash,
                    pi_idempotency_key  => 'CYCLE:' || rec.org_id || ':' || TO_CHAR(systimestamp, 'YYYYMMDD')
                );
                v_touched(rec.org_id) := TRUE;
            EXCEPTION
                WHEN OTHERS THEN
                    ROLLBACK;
                    pkg_aox_util.pr_log_api(
                        pi_api_name => 'SUBSCRIPTION_BILLING_CYCLE', pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_RUN_BILLING_CYCLE',
                        pi_http_method => 'JOB', pi_endpoint => 'HASEL_SUBSCRIPTION_BILLING_CYCLE', pi_status => 'ERROR',
                        pi_error_code => SQLCODE, pi_error_message => SQLERRM,
                        pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK, pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                        pi_request_body => TO_CLOB('org_id=' || rec.org_id)
                    );
            END;
        END LOOP;

        -- Orgs con lifecycle inminente (trial/gracia) tambien se consideran tocadas.
        FOR rec IN (
            SELECT s.org_id_organization AS org_id
              FROM org_subscription s
             WHERE NVL(s.billing_exempt, 0) = 0
               AND NVL(s.is_founder, 0) = 0
               AND (
                       (s.trial_ends_at IS NOT NULL AND s.trial_ends_at <= systimestamp + NUMTODSINTERVAL(3, 'DAY'))
                    OR (s.grace_ends_at IS NOT NULL AND s.grace_ends_at <= systimestamp + NUMTODSINTERVAL(3, 'DAY'))
                    OR s.status IN ('PAST_DUE', 'READ_ONLY', 'CANCELED')
                   )
        ) LOOP
            v_touched(rec.org_id) := TRUE;
        END LOOP;

        -- 3) Notificaciones solo para orgs tocadas.
        v_org_id := v_touched.FIRST;
        WHILE v_org_id IS NOT NULL LOOP
            BEGIN
                pr_notify_subscription_lifecycle(v_org_id);
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    ROLLBACK;
            END;
            v_org_id := v_touched.NEXT(v_org_id);
        END LOOP;

        -- 4) Outbox FE + emails (global: todas las filas pendientes; el ciclo de fixture filtra).
        BEGIN
            pr_dispatch_einvoice_outbox(50, NULL);
            pr_retry_pending_einvoice_emails(50, NULL);
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
    END pr_run_billing_cycle;

    PROCEDURE pr_run_billing_cycle_for_org(pi_org_id IN NUMBER) IS
        v_invoice_id NUMBER;
        v_hash       VARCHAR2(128);
        v_plan_code  VARCHAR2(30);
        v_auto_renew NUMBER(1,0);
        v_max_retry  NUMBER := NVL(TO_NUMBER(fn_get_parameter('SUBSCRIPTION_MAX_CHARGE_RETRIES')), 4);
        v_sub_id     NUMBER;
        v_locked     BOOLEAN := FALSE;
        v_fixture_id NUMBER;
        v_fixture_name VARCHAR2(100);
        v_org_name   organization.name%TYPE;
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'org_id invalido para ciclo de billing.');
        END IF;

        -- Aislamiento fixture: exige QA_BILLING_E2E_ORG_ID inmutable (nombre solo como chequeo).
        BEGIN
            v_fixture_id := TO_NUMBER(fn_get_parameter('QA_BILLING_E2E_ORG_ID'));
        EXCEPTION
            WHEN OTHERS THEN
                v_fixture_id := NULL;
        END;
        v_fixture_name := NVL(fn_get_parameter('QA_BILLING_E2E_ORG_NAME'), 'QA Billing E2E');

        IF v_fixture_id IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation,
                'QA_BILLING_E2E_ORG_ID no configurado; ejecuta scripts/qa_billing_e2e_seed.sql');
        END IF;
        IF pi_org_id <> v_fixture_id THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation,
                'pr_run_billing_cycle_for_org solo admite la fixture E2E (org_id=' || v_fixture_id || ').');
        END IF;
        IF pi_org_id = 1 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Abortado: no se puede ciclar org_id=1.');
        END IF;

        SELECT name INTO v_org_name FROM organization WHERE id_organization = pi_org_id;
        IF v_org_name <> v_fixture_name THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation,
                'Org ' || pi_org_id || ' no coincide con fixture "' || v_fixture_name || '".');
        END IF;

        pkg_aox_util.pr_log_api(
            pi_api_name     => 'SUBSCRIPTION_BILLING_CYCLE',
            pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_RUN_BILLING_CYCLE_FOR_ORG',
            pi_http_method  => 'DEV',
            pi_endpoint     => 'pr_run_billing_cycle_for_org',
            pi_org_id       => pi_org_id,
            pi_status       => 'STARTED',
            pi_request_body => TO_CLOB('org_id=' || pi_org_id)
        );

        -- Lock concurrente por org (NOWAIT): evita corridas solapadas de la fixture.
        BEGIN
            SELECT id_subscription INTO v_sub_id
              FROM org_subscription
             WHERE org_id_organization = pi_org_id
             FOR UPDATE NOWAIT;
            v_locked := TRUE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                pkg_aox_util.pr_log_api(
                    pi_api_name => 'SUBSCRIPTION_BILLING_CYCLE',
                    pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_RUN_BILLING_CYCLE_FOR_ORG',
                    pi_org_id => pi_org_id,
                    pi_status => 'SKIPPED',
                    pi_error_message => 'Org sin org_subscription'
                );
                RETURN;
            WHEN OTHERS THEN
                IF SQLCODE = -54 THEN -- resource busy
                    pkg_aox_util.pr_log_api(
                        pi_api_name => 'SUBSCRIPTION_BILLING_CYCLE',
                        pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_RUN_BILLING_CYCLE_FOR_ORG',
                        pi_org_id => pi_org_id,
                        pi_status => 'SKIPPED',
                        pi_error_message => 'Ciclo ya en ejecucion para esta org (lock)'
                    );
                    RETURN;
                END IF;
                RAISE;
        END;

        BEGIN
            pr_apply_due_pending_plan(pi_org_id);
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_util.pr_log_api(
                    pi_api_name => 'SUBSCRIPTION_BILLING_CYCLE',
                    pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_APPLY_PENDING',
                    pi_org_id => pi_org_id,
                    pi_status => 'ERROR',
                    pi_error_code => SQLCODE,
                    pi_error_message => SQLERRM
                );
        END;

        BEGIN
            SELECT p.code, NVL(s.auto_renew, 1)
              INTO v_plan_code, v_auto_renew
              FROM org_subscription s
              JOIN ref_plan p ON p.id_plan = s.pln_id_plan
             WHERE s.org_id_organization = pi_org_id;

            DECLARE
                v_due NUMBER := 0;
            BEGIN
                SELECT COUNT(*)
                  INTO v_due
                  FROM org_subscription s2
                 WHERE s2.org_id_organization = pi_org_id
                   AND s2.status IN ('ACTIVE', 'PAST_DUE')
                   AND NVL(s2.billing_exempt, 0) = 0
                   AND s2.current_period_end IS NOT NULL
                   AND s2.current_period_end <= systimestamp
                   AND NVL(s2.charge_retry_count, 0) < v_max_retry;

                IF v_plan_code <> c_plan_free
                   AND v_auto_renew = 1
                   AND v_due > 0
                THEN
                    UPDATE /*+ no_parallel */ org_subscription
                       SET charge_retry_count = NVL(charge_retry_count, 0) + 1,
                           last_charge_at     = systimestamp,
                           updated_at         = systimestamp
                     WHERE org_id_organization = pi_org_id;

                    pr_charge_target(
                        pi_org_id           => pi_org_id,
                        pi_target_type      => 'CONSOLIDATED',
                        pi_plan_code        => v_plan_code,
                        pi_addon_code       => NULL,
                        po_invoice_id       => v_invoice_id,
                        po_hash             => v_hash,
                        pi_idempotency_key  => 'CYCLE:' || pi_org_id || ':' || TO_CHAR(systimestamp, 'YYYYMMDD')
                    );
                END IF;
            END;
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_util.pr_log_api(
                    pi_api_name => 'SUBSCRIPTION_BILLING_CYCLE',
                    pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_RUN_BILLING_CYCLE_FOR_ORG',
                    pi_org_id => pi_org_id,
                    pi_status => 'ERROR',
                    pi_error_code => SQLCODE,
                    pi_error_message => SQLERRM,
                    pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK,
                    pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
                );
        END;

        pr_notify_subscription_lifecycle(pi_org_id);
        COMMIT;

        BEGIN
            pr_dispatch_einvoice_outbox(10, pi_org_id);
            pr_retry_pending_einvoice_emails(10, pi_org_id);
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;

        pkg_aox_util.pr_log_api(
            pi_api_name     => 'SUBSCRIPTION_BILLING_CYCLE',
            pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_RUN_BILLING_CYCLE_FOR_ORG',
            pi_http_method  => 'DEV',
            pi_endpoint     => 'pr_run_billing_cycle_for_org',
            pi_org_id       => pi_org_id,
            pi_status       => 'SUCCESS',
            pi_request_body => TO_CLOB('org_id=' || pi_org_id || ';invoice_id=' || v_invoice_id)
        );
    END pr_run_billing_cycle_for_org;

    --------------------------------------------------------------------------
    -- Factura electronica SIFEN (firmador esign) - endpoints internos
    -- (X-Service-Token, sin JWT de usuario)
    --------------------------------------------------------------------------

    -- POST /internal/v1/subscription-invoices/:id/einvoice
    PROCEDURE pr_save_einvoice_result(
        pi_service_token IN  VARCHAR2,
        pi_invoice_id    IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_json          json_object_t;
        v_response      json_object_t := json_object_t();
        v_cdc           VARCHAR2(44);
        v_estado        VARCHAR2(20);
        v_cod_res       VARCHAR2(10);
        v_prot_aut      VARCHAR2(30);
        v_ambiente      VARCHAR2(10);
        v_mensaje       VARCHAR2(500);
        v_new_status    VARCHAR2(20);
        v_cur_cdc       VARCHAR2(44);
        v_cur_status    VARCHAR2(20);
        v_rows          NUMBER;
    BEGIN
        pr_assert_service_token(pi_service_token);

        v_json     := json_object_t.parse(pi_body);
        v_cdc      := v_json.get_string('cdc');
        v_estado   := v_json.get_string('estado');
        v_cod_res  := CASE WHEN v_json.has('codRes') THEN v_json.get_string('codRes') END;
        v_prot_aut := CASE WHEN v_json.has('protAut') THEN v_json.get_string('protAut') END;
        v_ambiente := CASE WHEN v_json.has('ambiente') THEN v_json.get_string('ambiente') END;
        v_mensaje  := CASE WHEN v_json.has('mensaje') THEN v_json.get_string('mensaje') END;

        BEGIN
            SELECT einvoice_cdc, einvoice_status
              INTO v_cur_cdc, v_cur_status
              FROM org_subscription_invoice
             WHERE id_invoice = pi_invoice_id
             FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := 404;
                v_response.put('status', 'error');
                v_response.put('message', 'Invoice no encontrada.');
                po_response_body := v_response.to_clob();
                RETURN;
        END;

        -- Idempotencia / proteccion de estados terminales con CDC.
        IF v_cur_status IN ('SENT_PENDING_KUDE', 'SENT') AND v_cur_cdc IS NOT NULL THEN
            IF v_cdc IS NULL OR v_cdc = v_cur_cdc THEN
                po_status_code := pkg_aox_util.c_success_ok_code;
                v_response.put('status', 'success');
                v_response.put('message', 'CDC ya persistido; callback ignorado.');
                po_response_body := v_response.to_clob();
                RETURN;
            END IF;
            po_status_code := 409;
            v_response.put('status', 'error');
            v_response.put('message', 'Invoice ya tiene CDC terminal distinto; no se sobrescribe.');
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        IF UPPER(NVL(v_estado, '')) = 'APROBADO' AND v_cdc IS NOT NULL THEN
            v_new_status := 'SENT_PENDING_KUDE';
        ELSE
            v_new_status := 'FAILED';
        END IF;

        UPDATE /*+ no_parallel */ org_subscription_invoice
           SET einvoice_cdc          = CASE WHEN v_new_status = 'SENT_PENDING_KUDE' THEN v_cdc ELSE einvoice_cdc END,
               einvoice_estado_sifen = v_estado,
               einvoice_cod_res      = v_cod_res,
               einvoice_prot_aut     = v_prot_aut,
               einvoice_ambiente     = v_ambiente,
               einvoice_status       = v_new_status,
               einvoice_error        = CASE WHEN v_new_status = 'FAILED'
                                             THEN SUBSTR('SIFEN estado=' || v_estado
                                                          || CASE WHEN v_cod_res IS NOT NULL THEN ' codRes=' || v_cod_res END
                                                          || CASE WHEN v_mensaje IS NOT NULL THEN ' - ' || v_mensaje END, 1, 500)
                                             ELSE NULL END
         WHERE id_invoice = pi_invoice_id
           AND NVL(einvoice_status, 'NONE') IN ('NONE', 'PENDING', 'FAILED')
           AND (einvoice_cdc IS NULL OR einvoice_cdc = v_cdc);

        v_rows := SQL%ROWCOUNT;
        IF v_rows = 0 THEN
            po_status_code := 409;
            v_response.put('status', 'error');
            v_response.put('message', 'No se actualizo (estado no reclamable o CDC protegido).');
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        -- Cerrar outbox solo con resultado terminal verificable.
        IF v_new_status = 'SENT_PENDING_KUDE' AND v_cdc IS NOT NULL THEN
            UPDATE subscription_einvoice_outbox
               SET status = 'DONE',
                   processed_at = systimestamp,
                   last_error = NULL,
                   lease_owner = NULL,
                   lease_until = NULL
             WHERE invoice_id = pi_invoice_id
               AND status IN ('PENDING', 'PROCESSING');
        ELSIF v_new_status = 'FAILED' THEN
            UPDATE subscription_einvoice_outbox
               SET status = 'FAILED',
                   processed_at = systimestamp,
                   last_error = SUBSTR(NVL(v_mensaje, 'SIFEN ' || v_estado), 1, 500),
                   lease_owner = NULL,
                   lease_until = NULL
             WHERE invoice_id = pi_invoice_id
               AND status IN ('PENDING', 'PROCESSING');
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_save_einvoice_result;

    -- GET /internal/v1/subscription-invoices/pending-kude
    PROCEDURE pr_list_pending_kude(
        pi_service_token IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response json_object_t := json_object_t();
        v_data     json_array_t := json_array_t();
        v_item     json_object_t;
    BEGIN
        pr_assert_service_token(pi_service_token);

        FOR rec IN (
            SELECT id_invoice, einvoice_cdc
              FROM org_subscription_invoice
             WHERE einvoice_status = 'SENT_PENDING_KUDE'
               AND einvoice_cdc IS NOT NULL
               AND einvoice_kude_url IS NULL
             ORDER BY id_invoice
             FETCH FIRST 50 ROWS ONLY
        ) LOOP
            v_item := json_object_t();
            v_item.put('invoice_id', rec.id_invoice);
            v_item.put('cdc', rec.einvoice_cdc);
            v_data.append(v_item);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_pending_kude;

    -- POST /internal/v1/subscription-invoices/:id/einvoice-kude
    PROCEDURE pr_save_einvoice_kude(
        pi_service_token IN  VARCHAR2,
        pi_invoice_id    IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_json      json_object_t;
        v_response  json_object_t := json_object_t();
        v_kude_url  VARCHAR2(500);
    BEGIN
        pr_assert_service_token(pi_service_token);

        v_json     := json_object_t.parse(pi_body);
        v_kude_url := v_json.get_string('kudeUrl');

        IF v_kude_url IS NULL OR TRIM(v_kude_url) IS NULL THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response.put('status', 'error');
            v_response.put('message', 'Falta kudeUrl.');
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        UPDATE /*+ no_parallel */ org_subscription_invoice
           SET einvoice_kude_url = v_kude_url
         WHERE id_invoice = pi_invoice_id
           AND einvoice_status = 'SENT_PENDING_KUDE'
           AND einvoice_kude_url IS NULL;

        IF SQL%ROWCOUNT = 0 THEN
            -- Idempotente: si ya tiene la misma URL, OK.
            DECLARE
                v_existing VARCHAR2(500);
            BEGIN
                SELECT einvoice_kude_url INTO v_existing
                  FROM org_subscription_invoice
                 WHERE id_invoice = pi_invoice_id;
                IF v_existing IS NOT NULL AND v_existing = v_kude_url THEN
                    po_status_code := pkg_aox_util.c_success_ok_code;
                    v_response.put('status', 'success');
                    po_response_body := v_response.to_clob();
                    RETURN;
                END IF;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    NULL;
            END;
            po_status_code := 404;
            v_response.put('status', 'error');
            v_response.put('message', 'Invoice no encontrada o ya procesada.');
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        COMMIT;

        -- Envio del mail con adjunto: fallo de email no marca FE FAILED ni reabre emision.
        BEGIN
            pr_send_einvoice_email(pi_invoice_id);
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_save_einvoice_kude;

END pkg_aox_subscription_billing_api;
/
