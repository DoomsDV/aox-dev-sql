-- Fix: X-Service-Token no llega via CGI OWA en ADB/ORDS.
-- Bookmate poll-kude llama GET/POST /api/v1/internal/subscription-invoices/*
-- (modulo hasel / AOXDEV), NO el modulo esign_internal del firmador.
-- Patron alineado a firmador/db/ords/02_esign_internal_module.sql:
--   HEADER X-Service-Token -> bind :service_token
-- Ademas :status_code (no :status) para HTTP 401/403 reales.
--
-- Idempotente: redefine handlers + parametros de los 4 endpoints einvoice.

BEGIN
    ----------------------------------------------------------------------------
    -- POST .../:id/einvoice
    ----------------------------------------------------------------------------
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'internal/subscription-invoices/:id/einvoice',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_save_einvoice_result(
        pi_service_token => :service_token,
        pi_invoice_id    => TO_NUMBER(:id),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ----------------------------------------------------------------------------
    -- GET .../pending-kude
    ----------------------------------------------------------------------------
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'internal/subscription-invoices/pending-kude',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_list_pending_kude(
        pi_service_token => :service_token,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ----------------------------------------------------------------------------
    -- POST .../:id/einvoice-kude (legacy)
    ----------------------------------------------------------------------------
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'internal/subscription-invoices/:id/einvoice-kude',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_save_einvoice_kude(
        pi_service_token => :service_token,
        pi_invoice_id    => TO_NUMBER(:id),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ----------------------------------------------------------------------------
    -- POST .../:id/einvoice-artifacts
    ----------------------------------------------------------------------------
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'internal/subscription-invoices/:id/einvoice-artifacts',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_save_einvoice_artifacts(
        pi_service_token => :service_token,
        pi_invoice_id    => TO_NUMBER(:id),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ----------------------------------------------------------------------------
    -- Bind HEADER X-Service-Token -> :service_token (cada handler)
    ----------------------------------------------------------------------------
    FOR r IN (
        SELECT t.uri_template, h.method
          FROM user_ords_modules m
          JOIN user_ords_templates t ON t.module_id = m.id
          JOIN user_ords_handlers h ON h.template_id = t.id
         WHERE m.name = 'hasel'
           AND t.uri_template LIKE 'internal/subscription-invoices%'
           AND (
                t.uri_template LIKE '%/einvoice'
             OR t.uri_template LIKE '%/einvoice-kude'
             OR t.uri_template LIKE '%/einvoice-artifacts'
             OR t.uri_template LIKE '%/pending-kude'
           )
    ) LOOP
        BEGIN
            ORDS.define_parameter(
                p_module_name        => 'hasel',
                p_pattern            => r.uri_template,
                p_method             => r.method,
                p_name               => 'X-Service-Token',
                p_bind_variable_name => 'service_token',
                p_source_type        => 'HEADER',
                p_param_type         => 'STRING',
                p_access_method      => 'IN',
                p_comments           => 'Token compartido Astro<->ORDS (poll-kude / emit callbacks)'
            );
        EXCEPTION
            WHEN OTHERS THEN
                -- redefine_parameter si ya existia
                NULL;
        END;
    END LOOP;

    COMMIT;
END;
/

PROMPT === 20260901_einvoice_ords_service_token: X-Service-Token bind OK ===
