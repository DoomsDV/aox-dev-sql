-- Webhook de Pagopar (suscripciones): propagar el código HTTP real.
--
-- El handler asignaba :status, que ORDS no toma como código de respuesta
-- (el implícito es :status_code), así que respondía 200 aunque rechazara el
-- token (403), no encontrara la factura (404) o fallara (500). Para Pagopar un
-- 200 es "recibido": una notificación rechazada nunca se reintentaba.
-- El cuerpo no cambia: en el camino feliz sigue siendo el eco de "resultado".
--
-- Idempotente: redefine solo el handler POST de pagopar/subscription/webhook.

PROMPT === ORDS POST /pagopar/v1/subscription/webhook con :status_code ===
BEGIN
    ORDS.define_handler(
        p_module_name => 'pagopar',
        p_pattern     => 'subscription/webhook',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_subscription_webhook(
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
    COMMIT;
END;
/
