-- ORDS: POST /api/v1/appointments/:id/survey + webhook nfm_reply encuesta CSAT.

BEGIN
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'appointments/:id/survey');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'appointments/:id/survey',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_appointment_api.pr_send_appointment_survey(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_app_id        => :id,
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

BEGIN
    ORDS.delete_handler(
        p_module_name  => 'whatsapp',
        p_uri_template => 'attendance-reply',
        p_method       => 'POST'
    );
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

BEGIN
    ORDS.define_handler(
        p_module_name    => 'whatsapp',
        p_pattern        => 'attendance-reply',
        p_method         => 'POST',
        p_source_type    => ORDS.source_type_plsql,
        p_source         => q'[
DECLARE
    v_body_blob BLOB := :body;
    v_body      CLOB;
    v_sig       VARCHAR2(4000);
    v_payload   VARCHAR2(200);
    v_nfm_json  VARCHAR2(4000);
    v_phone_from VARCHAR2(30);
    v_response  json_object_t := json_object_t();
    v_dest      INTEGER := 1;
    v_src       INTEGER := 1;
    v_ctx       INTEGER := DBMS_LOB.default_lang_ctx;
    v_warn      INTEGER;
BEGIN
    IF v_body_blob IS NOT NULL AND DBMS_LOB.getlength(v_body_blob) > 0 THEN
        DBMS_LOB.createtemporary(v_body, TRUE);
        DBMS_LOB.converttoclob(
            dest_lob     => v_body,
            src_blob     => v_body_blob,
            amount       => DBMS_LOB.lobmaxsize,
            dest_offset  => v_dest,
            src_offset   => v_src,
            blob_csid    => NLS_CHARSET_ID('AL32UTF8'),
            lang_context => v_ctx,
            warning      => v_warn
        );
    END IF;

    BEGIN
        pkg_aox_meta_api.pr_log_webhook_meta(pi_payload => v_body);
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;

    BEGIN
        v_sig := :x_hub_signature_256;
    EXCEPTION
        WHEN OTHERS THEN v_sig := NULL;
    END;

    IF v_sig IS NULL THEN
        BEGIN v_sig := owa_util.get_cgi_env('HTTP_X_HUB_SIGNATURE_256'); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
    IF v_sig IS NULL THEN
        BEGIN v_sig := owa_util.get_cgi_env('X-Hub-Signature-256'); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    IF NVL(pkg_aox_meta_api.fn_verify_webhook_signature(v_body_blob, v_sig), 0) <> 1 THEN
        :status_code := 403;
        v_response.put('status', 'error');
        v_response.put('message', 'Firma de webhook invalida o META_APP_SECRET no configurado.');
        owa_util.mime_header('application/json', FALSE);
        owa_util.http_header_close;
        htp.prn(v_response.to_clob());
        RETURN;
    END IF;

    APEX_JSON.parse(v_body);

    v_nfm_json := APEX_JSON.get_varchar2(
        p_path => 'entry[1].changes[1].value.messages[1].interactive.nfm_reply.response_json'
    );
    v_phone_from := APEX_JSON.get_varchar2(
        p_path => 'entry[1].changes[1].value.messages[1].from'
    );

    IF v_nfm_json IS NOT NULL THEN
        pkg_aox_meta_api.pr_apply_survey_nfm_reply(
            pi_response_json => v_nfm_json,
            pi_phone_from    => v_phone_from
        );
        :status_code := 200;
        v_response.put('status', 'success');
        v_response.put('message', 'Encuesta registrada.');
        owa_util.mime_header('application/json', FALSE);
        owa_util.http_header_close;
        htp.prn(v_response.to_clob());
        RETURN;
    END IF;

    v_payload := APEX_JSON.get_varchar2(
        p_path => 'entry[1].changes[1].value.messages[1].button.payload'
    );

    IF v_payload IS NULL THEN
        v_payload := APEX_JSON.get_varchar2(
            p_path => 'entry[1].changes[1].value.messages[1].interactive.button_reply.id'
        );
    END IF;

    IF v_payload IS NULL THEN
        v_payload := APEX_JSON.get_varchar2(
            p_path => 'entry[1].changes[1].value.messages[1].interactive.button_reply.payload'
        );
    END IF;

    IF v_payload IS NULL
       OR NOT REGEXP_LIKE(
            UPPER(TRIM(v_payload)),
            '^(CONFIRMAR_RESERVA_ID_|CANCELAR_RESERVA_ID_)[0-9]+$'
       ) THEN
        :status_code := 200;
        v_response.put('status', 'ignored');
        v_response.put('message', 'Evento sin payload de asistencia o encuesta valido.');
        owa_util.mime_header('application/json', FALSE);
        owa_util.http_header_close;
        htp.prn(v_response.to_clob());
        RETURN;
    END IF;

    pkg_aox_meta_api.pr_apply_attendance_payload(pi_payload => v_payload);

    :status_code := 200;
    v_response.put('status', 'success');
    v_response.put('message', 'Respuesta registrada.');
    owa_util.mime_header('application/json', FALSE);
    owa_util.http_header_close;
    htp.prn(v_response.to_clob());
EXCEPTION
    WHEN OTHERS THEN
        :status_code := 400;
        v_response := json_object_t();
        v_response.put('status', 'error');
        v_response.put('message', REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''));
        owa_util.mime_header('application/json', FALSE);
        owa_util.http_header_close;
        htp.prn(v_response.to_clob());
END;
]',
        p_items_per_page => 0
    );
    COMMIT;
END;
/

PROMPT === 20260908_appointment_survey_ords done ===
