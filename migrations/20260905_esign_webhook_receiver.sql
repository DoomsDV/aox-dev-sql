-- Webhook público esign (invoice.ready) + parámetros de verificación HMAC.
-- Requiere: compilar PKG_AOX_SUBSCRIPTION_BILLING_API (pr_receive_esign_webhook).

PROMPT === app_parameter ESIGN_WEBHOOK_SECRET (insert si falta) ===
MERGE INTO app_parameter t
USING (
    SELECT 'ESIGN_WEBHOOK_SECRET' AS param_key,
           'PENDING' AS param_value,
           'Secret HMAC compartido con el panel esign (webhook invoice.ready). Rotar en panel esign y copiar aquí.' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);

PROMPT === Ampliar einvoice_kude_url a 1000 chars ===
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_subscription_invoice MODIFY (einvoice_kude_url VARCHAR2(1000))';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-942, -904) THEN RAISE; END IF;
END;
/

PROMPT === Compilar paquete billing (webhook receiver) ===
@@../packages/PKG_AOX_SUBSCRIPTION_BILLING_API.pls

PROMPT === ORDS POST /public/v1/esign/webhook ===
BEGIN
    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'esign/webhook'
    );
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'esign/webhook',
        p_method      => 'POST',
        p_source_type => ORDS.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
    v_ts            VARCHAR2(32) := owa_util.get_cgi_env('HTTP_X_ESIGN_TIMESTAMP');
    v_sig           VARCHAR2(512) := owa_util.get_cgi_env('HTTP_X_ESIGN_SIGNATURE');
    v_delivery      VARCHAR2(128) := owa_util.get_cgi_env('HTTP_X_ESIGN_DELIVERY_ID');
BEGIN
    pkg_aox_subscription_billing_api.pr_receive_esign_webhook(
        pi_timestamp     => v_ts,
        pi_signature     => v_sig,
        pi_delivery_id   => v_delivery,
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    COMMIT;
END;
/

PROMPT === ORDS POST /public/v1/esign/webhook registrado ===
