PROMPT CREATE OR REPLACE PACKAGE pkg_aox_ia_api
CREATE OR REPLACE PACKAGE pkg_aox_ia_api IS

    -- Procedimiento principal para ser consumido por ORDS (Frontend)
    PROCEDURE pr_get_dashboard_summary(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_parse_voice_appointment_draft(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );
END pkg_aox_ia_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_ia_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_ia_api IS

    PROCEDURE pr_get_dashboard_summary(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id       NUMBER;
        v_org_id        NUMBER;
        v_role_id       NUMBER;
        v_prof_id       NUMBER; -- Ya no hace falta el := NULL acá

        v_ai_response   CLOB;
        v_summary_short   VARCHAR2(500);
        v_summary_full    VARCHAR2(4000);
        v_sections_arr    json_array_t;
        v_api_code      VARCHAR2(30);
        v_error_message VARCHAR2(4000);
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();
    BEGIN
        -- 1. Identidad completa desde JWT
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        -- Gate de suscripción: el resumen IA requiere el feature del plan y se desactiva en READ_ONLY.
        pkg_aox_subscription_api.pr_assert_org_has_feature(v_org_id, 'AI_MORNING_DIGEST');
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        -- 2. Buscamos su ID de profesional (¡Para TODOS los roles!)
        -- Porque un Admin también puede ser un peluquero/barbero/doctor en el sistema.
        BEGIN
            SELECT id_professional INTO v_prof_id
            FROM professional
            WHERE usr_id_user = v_user_id AND org_id_organization = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_prof_id := -1; -- Si es una recepcionista sin perfil, por ejemplo.
        END;

        -- 3. Llamar a la IA
        v_ai_response := pkg_aox_ia_manager.fn_get_gemini_summary(
            v_org_id,
            v_role_id,
            v_prof_id,
            v_user_id
        );

        SELECT
            json_value(v_ai_response, '$.summary_short' RETURNING VARCHAR2(500)),
            json_value(v_ai_response, '$.summary_full' RETURNING VARCHAR2(4000))
        INTO
            v_summary_short,
            v_summary_full
        FROM dual;

        BEGIN
            v_sections_arr := json_array_t(json_query(v_ai_response, '$.sections'));
        EXCEPTION
            WHEN OTHERS THEN
                v_sections_arr := json_array_t();
        END;

        IF v_summary_full IS NULL OR TRIM(v_summary_full) IS NULL THEN
            v_summary_full := DBMS_LOB.SUBSTR(v_ai_response, 4000, 1);
        END IF;

        IF v_summary_short IS NULL OR TRIM(v_summary_short) IS NULL THEN
            v_summary_short := SUBSTR(REPLACE(v_summary_full, CHR(10), ' '), 1, 160);
        END IF;

        IF v_sections_arr IS NULL THEN
            v_sections_arr := json_array_t();
        END IF;

        -- 4. Armar JSON de respuesta
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');

        v_data_obj.put('ai_summary_short', v_summary_short);
        v_data_obj.put('ai_summary', v_summary_full);
        v_data_obj.put('ai_summary_sections', v_sections_arr);
        v_response_json.put('data', v_data_obj);

        po_response_body := v_response_json.to_clob();

    EXCEPTION
        -- (Tu bloque de excepciones sigue igual)
        WHEN OTHERS THEN
            pkg_aox_util.pr_resolve_api_error(SQLCODE, SQLERRM, po_status_code, v_api_code, v_error_message);
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'IA_DASHBOARD_SUMMARY',
                pi_process_name    => 'PKG_AOX_IA_API.PR_GET_DASHBOARD_SUMMARY',
                pi_http_method     => 'GET',
                pi_endpoint        => '/dashboard/ai-summary',
                pi_org_id          => v_org_id,
                pi_user_id         => v_user_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            pkg_aox_util.pr_log_ai(
                pi_process_name    => 'PKG_AOX_IA_API.PR_GET_DASHBOARD_SUMMARY',
                pi_org_id          => v_org_id,
                pi_user_id         => v_user_id,
                pi_role_id         => v_role_id,
                pi_pro_id          => v_prof_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_response_body   => v_ai_response
            );
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => v_error_message,
                po_response_body => po_response_body
            );
    END pr_get_dashboard_summary;

    PROCEDURE pr_parse_voice_appointment_draft(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id       NUMBER;
        v_org_id        NUMBER;
        v_role_id       NUMBER;
        v_prof_id       NUMBER;
        v_audio_base64  CLOB;
        v_mime_type     VARCHAR2(100);
        v_filename      VARCHAR2(200);
        v_ai_response   CLOB;
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();
        v_api_code      VARCHAR2(30);
        v_error_message VARCHAR2(4000);
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        -- Gate de suscripción: recepción por voz requiere el feature del plan y estado con escritura.
        pkg_aox_subscription_api.pr_assert_org_has_feature(v_org_id, 'VOICE_RECEPTION');
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        BEGIN
            SELECT id_professional INTO v_prof_id
            FROM professional
            WHERE usr_id_user = v_user_id AND org_id_organization = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_prof_id := -1;
        END;

        IF pi_body IS NULL OR DBMS_LOB.GETLENGTH(pi_body) = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Debes enviar un archivo de audio.');
        END IF;

        SELECT JSON_VALUE(pi_body, '$.audio_base64' RETURNING CLOB)
        INTO v_audio_base64
        FROM dual;
        v_mime_type := NVL(TRIM(JSON_VALUE(pi_body, '$.mime_type')), 'audio/webm');
        v_filename  := NVL(TRIM(JSON_VALUE(pi_body, '$.filename')), 'cita.webm');

        IF v_audio_base64 IS NULL OR DBMS_LOB.GETLENGTH(v_audio_base64) = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Debes enviar un archivo de audio.');
        END IF;

        v_ai_response := pkg_aox_ia_manager.fn_process_voice_appointment_draft(
            v_org_id,
            v_role_id,
            v_prof_id,
            v_audio_base64,
            v_mime_type,
            v_filename,
            v_user_id
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_data_obj := json_object_t.parse(v_ai_response);
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_resolve_api_error(SQLCODE, SQLERRM, po_status_code, v_api_code, v_error_message);
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'IA_VOICE_APPOINTMENT_DRAFT',
                pi_process_name    => 'PKG_AOX_IA_API.PR_PARSE_VOICE_APPOINTMENT_DRAFT',
                pi_http_method     => 'POST',
                pi_endpoint        => '/ai/appointments/voice-draft',
                pi_org_id          => v_org_id,
                pi_user_id         => v_user_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            pkg_aox_util.pr_log_ai(
                pi_process_name    => 'PKG_AOX_IA_API.PR_PARSE_VOICE_APPOINTMENT_DRAFT',
                pi_org_id          => v_org_id,
                pi_user_id         => v_user_id,
                pi_role_id         => v_role_id,
                pi_pro_id          => v_prof_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_response_body   => v_ai_response
            );
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => v_error_message,
                po_response_body => po_response_body
            );
    END pr_parse_voice_appointment_draft;

END pkg_aox_ia_api;
/

