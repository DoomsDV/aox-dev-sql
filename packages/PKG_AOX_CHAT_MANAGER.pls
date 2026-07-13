PROMPT CREATE OR REPLACE PACKAGE pkg_aox_chat_manager
CREATE OR REPLACE PACKAGE pkg_aox_chat_manager IS
    FUNCTION fn_process_chat(
        pi_session_id NUMBER,
        pi_org_id     NUMBER,
        pi_user_id    NUMBER,
        pi_role_id    NUMBER,
        pi_pro_id     NUMBER,
        pi_user_msg   CLOB
    ) RETURN CLOB;
END pkg_aox_chat_manager;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_chat_manager
CREATE OR REPLACE PACKAGE BODY pkg_aox_chat_manager IS

    FUNCTION fn_process_chat(
        pi_session_id NUMBER,
        pi_org_id     NUMBER,
        pi_user_id    NUMBER,
        pi_role_id    NUMBER,
        pi_pro_id     NUMBER,
        pi_user_msg   CLOB
    ) RETURN CLOB IS
        v_params       CLOB;
        v_response     CLOB;
        v_now_local    TIMESTAMP;
        v_role_name    ROLE.name%TYPE;
        v_user_name    VARCHAR2(200);
    BEGIN
        IF pi_user_msg IS NULL OR TRIM(pi_user_msg) IS NULL THEN
            RETURN 'Necesito que escribas un mensaje para ayudarte.';
        END IF;

        pkg_aox_ai_context.pr_set_context(
            pi_org_id     => pi_org_id,
            pi_user_id    => pi_user_id,
            pi_role_id    => pi_role_id,
            pi_pro_id     => pi_pro_id,
            pi_session_id => pi_session_id
        );

        v_now_local := CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP);

        BEGIN
            SELECT name
            INTO v_role_name
            FROM role
            WHERE id_role = pi_role_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_role_name := 'DESCONOCIDO';
        END;

        BEGIN
            SELECT first_name || ' ' || last_name
            INTO v_user_name
            FROM app_user
            WHERE id_user = pi_user_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_user_name := '';
        END;

        SELECT json_object(
            'conversation_id' VALUE 'aox-chat-' || pi_session_id,
            'variables' VALUE json_object(
                'current_date' VALUE TO_CHAR(v_now_local, 'YYYY-MM-DD'),
                'current_time' VALUE TO_CHAR(v_now_local, 'HH24:MI'),
                'timezone' VALUE pkg_aox_util.fn_app_timezone,
                'role_name' VALUE v_role_name,
                'current_user' VALUE v_user_name
            )
            RETURNING CLOB
        )
        INTO v_params
        FROM dual;

        v_response := DBMS_CLOUD_AI_AGENT.RUN_TEAM(
            team_name   => NVL(fn_get_parameter('HASEL_AI_TEAM_NAME'), 'HASEL_AGENDA_TEAM'),
            user_prompt => pi_user_msg,
            params      => v_params
        );

        pkg_aox_ai_context.pr_clear_context;

        IF v_response IS NULL OR TRIM(v_response) IS NULL THEN
            RETURN 'No pude generar una respuesta en este momento.';
        END IF;

        RETURN v_response;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                pkg_aox_ai_context.pr_clear_context;
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
        pkg_aox_util.pr_log_ai(
            pi_process_name    => 'PKG_AOX_CHAT_MANAGER.FN_PROCESS_CHAT',
            pi_session_id      => pi_session_id,
            pi_org_id          => pi_org_id,
            pi_user_id         => pi_user_id,
            pi_role_id         => pi_role_id,
            pi_pro_id          => pi_pro_id,
            pi_status          => 'ERROR',
            pi_error_code      => SQLCODE,
            pi_error_message   => SQLERRM,
            pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
            pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            pi_prompt          => pi_user_msg,
            pi_request_payload => v_params,
            pi_response_body   => v_response
        );
        RETURN 'Tuvimos un problema procesando tu mensaje. Detalle: ' || SQLERRM;
    END fn_process_chat;

END pkg_aox_chat_manager;
/

