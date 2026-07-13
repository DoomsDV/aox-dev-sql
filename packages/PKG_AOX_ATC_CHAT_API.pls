PROMPT CREATE OR REPLACE PACKAGE pkg_aox_atc_chat_api
CREATE OR REPLACE PACKAGE pkg_aox_atc_chat_api IS
    PROCEDURE pr_ask(
        pi_auth_header   IN VARCHAR2,
        pi_body          IN CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );
END pkg_aox_atc_chat_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_atc_chat_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_atc_chat_api IS

    PROCEDURE pr_ask(
        pi_auth_header   IN VARCHAR2,
        pi_body          IN CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id       NUMBER;
        v_org_id        NUMBER;
        v_role_id       NUMBER;
        v_json_req      json_object_t;
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();
        v_question      CLOB;
        v_answer        CLOB;
        v_top_k         NUMBER := 5;
        v_api_code      VARCHAR2(30);
        v_error_message VARCHAR2(4000);
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        v_json_req := json_object_t.parse(pi_body);
        v_question := v_json_req.get_clob('message');
        IF v_question IS NULL THEN
            v_question := v_json_req.get_clob('question');
        END IF;
        IF v_json_req.has('top_k') THEN
            v_top_k := v_json_req.get_number('top_k');
        END IF;

        IF v_question IS NULL OR TRIM(v_question) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20002, 'El mensaje no puede estar vacio.');
        END IF;

        v_answer := pkg_aox_atc_chat.fn_answer_question(
            pi_question => v_question,
            pi_top_k    => v_top_k
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_data_obj.put('response', v_answer);
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_resolve_api_error(SQLCODE, SQLERRM, po_status_code, v_api_code, v_error_message);
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'AI_ATC_ASK',
                pi_process_name    => 'PKG_AOX_ATC_CHAT_API.PR_ASK',
                pi_http_method     => 'POST',
                pi_endpoint        => '/ai/atc/ask',
                pi_org_id          => v_org_id,
                pi_user_id         => v_user_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body    => pi_body
            );
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => v_api_code,
                pi_message       => v_error_message,
                po_response_body => po_response_body
            );
    END pr_ask;

END pkg_aox_atc_chat_api;
/
