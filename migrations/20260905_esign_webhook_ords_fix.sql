-- Fix receptor webhook esign: HTTP status real + headers HMAC por bind ORDS
-- + placeholder ESIGN_API_KEY (el valor real NO va en este archivo).
--
-- El handler del 20260905 usaba :status (ORDS no lo propaga) y leia
-- X-Esign-* via CGI OWA (en ADB suele llegar NULL). El firmador marcaba
-- DELIVERED ante HTTP 200 aunque el PL/SQL devolviera 401/503.
-- Patron: migrations/20260901_einvoice_ords_service_token.sql

PROMPT === app_parameter ESIGN_API_KEY (insert si falta; valor PENDING) ===
MERGE INTO app_parameter t
USING (
    SELECT 'ESIGN_API_KEY' AS param_key,
           'PENDING' AS param_value,
           'API key sk_test_/sk_prod_ del tenant esign Hasel. El webhook Oracle la usa para GET /v1/documents/{cdc}/xml. Copiar la misma que Bookmate ESIGN_API_KEY (no commitear el valor).' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);

PROMPT === Redefinir ORDS POST /public/v1/esign/webhook ===
BEGIN
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'esign/webhook',
        p_method      => 'POST',
        p_source_type => ORDS.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_receive_esign_webhook(
        pi_timestamp     => :esign_timestamp,
        pi_signature     => :esign_signature,
        pi_delivery_id   => :esign_delivery_id,
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

    FOR r IN (
        SELECT 'X-Esign-Timestamp' AS hdr, 'esign_timestamp' AS bind, 'Unix epoch del HMAC invoice.ready' AS cmt FROM dual
        UNION ALL
        SELECT 'X-Esign-Signature', 'esign_signature', 'Firma t=,v1= HMAC-SHA256' FROM dual
        UNION ALL
        SELECT 'X-Esign-Delivery-Id', 'esign_delivery_id', 'UUID de document_webhook_delivery' FROM dual
    ) LOOP
        BEGIN
            ORDS.define_parameter(
                p_module_name        => 'public',
                p_pattern            => 'esign/webhook',
                p_method             => 'POST',
                p_name               => r.hdr,
                p_bind_variable_name => r.bind,
                p_source_type        => 'HEADER',
                p_param_type         => 'STRING',
                p_access_method      => 'IN',
                p_comments           => r.cmt
            );
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
    END LOOP;

    COMMIT;
END;
/

PROMPT === 20260905_esign_webhook_ords_fix: status_code + header binds OK ===
