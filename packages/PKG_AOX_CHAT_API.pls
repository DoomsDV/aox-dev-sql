PROMPT CREATE OR REPLACE PACKAGE pkg_aox_chat_api
CREATE OR REPLACE PACKAGE pkg_aox_chat_api IS
    PROCEDURE pr_send_message(
        pi_auth_header    IN VARCHAR2,
        pi_body           IN CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );
    PROCEDURE pr_list_sessions(
        pi_auth_header    IN VARCHAR2,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );
    PROCEDURE pr_get_messages(
        pi_auth_header    IN VARCHAR2,
        pi_session_id     IN NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );
    PROCEDURE pr_delete_session(
        pi_auth_header    IN VARCHAR2,
        pi_session_id     IN NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );
END pkg_aox_chat_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_chat_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_chat_api IS

    PROCEDURE pr_send_message(
        pi_auth_header    IN VARCHAR2,
        pi_body           IN CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_user_id       NUMBER;
        v_org_id        NUMBER;
        v_role_id       NUMBER;
        v_pro_id        NUMBER;
        v_json_req      json_object_t;
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();

        v_session_id    NUMBER;
        v_user_msg      CLOB;
        v_ai_msg        CLOB;
        v_owner_check   NUMBER;
        v_api_code      VARCHAR2(30);
        v_error_message VARCHAR2(4000);
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        -- Obtener ID de profesional
        BEGIN
            SELECT id_professional
            INTO
                v_pro_id
            FROM professional
            WHERE usr_id_user           = v_user_id
                AND org_id_organization = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_pro_id := -1;
        END;

        v_json_req := json_object_t.parse(pi_body);
        v_user_msg := v_json_req.get_clob('message');
        IF v_json_req.has('session_id') THEN v_session_id := v_json_req.get_number('session_id'); END IF;

        IF v_user_msg IS NULL THEN RAISE_APPLICATION_ERROR(-20002, 'El mensaje no puede estar vacio.'); END IF;

        IF v_session_id IS NULL THEN
            INSERT INTO ai_chat_session (
                org_id_organization,
                usr_id_user,
                title
            )
            VALUES (
                v_org_id,
                v_user_id,
                DBMS_LOB.SUBSTR(v_user_msg, 50, 1) || '...'
            )
            RETURNING id_session INTO v_session_id;
        ELSE
            SELECT COUNT(*)
            INTO
                v_owner_check
            FROM ai_chat_session
            WHERE id_session            = v_session_id
                AND usr_id_user         = v_user_id
                AND org_id_organization = v_org_id
                AND is_active           = 1;

            IF v_owner_check = 0 THEN RAISE_APPLICATION_ERROR(-20001, 'Sesion invalida.'); END IF;

            UPDATE ai_chat_session
            SET updated_at    = CURRENT_TIMESTAMP
            WHERE id_session  = v_session_id;
        END IF;

        INSERT INTO ai_chat_message (
            ses_id_session,
            sender_role,
            content
        ) VALUES (
            v_session_id,
            'user',
            v_user_msg
        );
        COMMIT;

        v_ai_msg := pkg_aox_chat_manager.fn_process_chat(
            pi_session_id => v_session_id,
            pi_org_id     => v_org_id,
            pi_user_id    => v_user_id,
            pi_role_id    => v_role_id,
            pi_pro_id     => v_pro_id,
            pi_user_msg   => v_user_msg
        );

        INSERT INTO ai_chat_message (
            ses_id_session,
            sender_role,
            content
        ) VALUES (
            v_session_id,
            'assistant',
            v_ai_msg
        );
        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_data_obj.put('session_id'   , v_session_id);
        v_data_obj.put('response'     , v_ai_msg);
        v_response_json.put('data'    , v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        pkg_aox_util.pr_resolve_api_error(SQLCODE, SQLERRM, po_status_code, v_api_code, v_error_message);
        pkg_aox_util.pr_log_api(
            pi_api_name        => 'AI_CHAT_SEND_MESSAGE',
            pi_process_name    => 'PKG_AOX_CHAT_API.PR_SEND_MESSAGE',
            pi_http_method     => 'POST',
            pi_endpoint        => '/ai/chat/messages',
            pi_org_id          => v_org_id,
            pi_user_id         => v_user_id,
            pi_status          => 'ERROR',
            pi_status_code     => po_status_code,
            pi_error_code      => SQLCODE,
            pi_error_message   => SQLERRM,
            pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
            pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            pi_request_body    => pi_body,
            pi_request_params  => 'session_id=' || v_session_id
        );
        pkg_aox_util.pr_log_ai(
            pi_process_name    => 'PKG_AOX_CHAT_API.PR_SEND_MESSAGE',
            pi_session_id      => v_session_id,
            pi_org_id          => v_org_id,
            pi_user_id         => v_user_id,
            pi_role_id         => v_role_id,
            pi_pro_id          => v_pro_id,
            pi_status          => 'ERROR',
            pi_status_code     => po_status_code,
            pi_error_code      => SQLCODE,
            pi_error_message   => SQLERRM,
            pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
            pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            pi_prompt          => v_user_msg,
            pi_response_body   => v_ai_msg
        );
        pkg_aox_util.pr_build_api_error_response(
            pi_status_code   => po_status_code,
            pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
            pi_message       => v_error_message,
            po_response_body => po_response_body
        );
    END pr_send_message;

    PROCEDURE pr_list_sessions(
        pi_auth_header    IN VARCHAR2,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_user_id NUMBER;
        v_org_id NUMBER;
        v_response_json json_object_t := json_object_t();
        v_arr json_array_t := json_array_t();
        v_obj json_object_t;
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        FOR rec IN (
            SELECT
                id_session,
                title,
                updated_at
            FROM ai_chat_session
            WHERE usr_id_user           = v_user_id
                AND org_id_organization = v_org_id
                AND is_active           = 1
            ORDER BY updated_at DESC
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('id_session', rec.id_session);
            v_obj.put('title', rec.title);
            v_obj.put('updated_at', TO_CHAR(rec.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            v_arr.append(v_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success'); v_response_json.put('data', v_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION WHEN OTHERS THEN
        po_status_code := pkg_aox_util.c_internal_error_code;
        pkg_aox_util.pr_log_api(
            pi_api_name        => 'AI_CHAT_LIST_SESSIONS',
            pi_process_name    => 'PKG_AOX_CHAT_API.PR_LIST_SESSIONS',
            pi_http_method     => 'GET',
            pi_endpoint        => '/ai/chat/sessions',
            pi_org_id          => v_org_id,
            pi_user_id         => v_user_id,
            pi_status          => 'ERROR',
            pi_status_code     => po_status_code,
            pi_error_code      => SQLCODE,
            pi_error_message   => SQLERRM,
            pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
            pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
        );
        pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_sessions;

    PROCEDURE pr_get_messages(
        pi_auth_header    IN VARCHAR2,
        pi_session_id     IN NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_user_id NUMBER;
        v_org_id NUMBER;
        v_owner_check NUMBER;
        v_api_code VARCHAR2(30);
        v_error_message VARCHAR2(4000);
        v_response_json json_object_t := json_object_t();
        v_arr json_array_t := json_array_t();
        v_obj json_object_t;
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        SELECT COUNT(*)
        INTO
            v_owner_check
        FROM ai_chat_session
        WHERE id_session              = pi_session_id
            AND usr_id_user           = v_user_id
            AND org_id_organization   = v_org_id
            AND is_active             = 1;

        IF v_owner_check = 0 THEN RAISE_APPLICATION_ERROR(-20001, 'Sesion sin acceso.'); END IF;

        FOR rec IN (
            SELECT
                id_message,
                sender_role,
                content,
                created_at
            FROM ai_chat_message
            WHERE ses_id_session = pi_session_id
            ORDER BY id_message ASC
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('id_message', rec.id_message);
            v_obj.put('role', rec.sender_role);
            v_obj.put('content', rec.content);
            v_obj.put('created_at', TO_CHAR(rec.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            v_arr.append(v_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION WHEN OTHERS THEN
        pkg_aox_util.pr_resolve_api_error(SQLCODE, SQLERRM, po_status_code, v_api_code, v_error_message);
        pkg_aox_util.pr_log_api(
            pi_api_name        => 'AI_CHAT_GET_MESSAGES',
            pi_process_name    => 'PKG_AOX_CHAT_API.PR_GET_MESSAGES',
            pi_http_method     => 'GET',
            pi_endpoint        => '/ai/chat/sessions/:id/messages',
            pi_org_id          => v_org_id,
            pi_user_id         => v_user_id,
            pi_status          => 'ERROR',
            pi_status_code     => po_status_code,
            pi_error_code      => SQLCODE,
            pi_error_message   => SQLERRM,
            pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
            pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            pi_request_params  => 'session_id=' || pi_session_id
        );
        pkg_aox_util.pr_build_api_error_response(
            pi_status_code   => po_status_code,
            pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
            pi_message       => v_error_message,
            po_response_body => po_response_body
        );
    END pr_get_messages;

    PROCEDURE pr_delete_session(
        pi_auth_header    IN VARCHAR2,
        pi_session_id     IN NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_user_id       NUMBER;
        v_org_id        NUMBER;
        v_api_code      VARCHAR2(30);
        v_error_message VARCHAR2(4000);
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        UPDATE ai_chat_session
        SET is_active  = 0,
            updated_at  = CURRENT_TIMESTAMP
        WHERE id_session          = pi_session_id
          AND usr_id_user         = v_user_id
          AND org_id_organization = v_org_id
          AND is_active           = 1;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Sesion no encontrada.');
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Historial eliminado correctamente.');
        v_data_obj.put('id_session', pi_session_id);
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_resolve_api_error(SQLCODE, SQLERRM, po_status_code, v_api_code, v_error_message);
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'AI_CHAT_DELETE_SESSION',
                pi_process_name    => 'PKG_AOX_CHAT_API.PR_DELETE_SESSION',
                pi_http_method     => 'DELETE',
                pi_endpoint        => '/ai/chat/sessions/:id',
                pi_org_id          => v_org_id,
                pi_user_id         => v_user_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'session_id=' || pi_session_id
            );
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => v_error_message,
                po_response_body => po_response_body
            );
    END pr_delete_session;

END pkg_aox_chat_api;
/

