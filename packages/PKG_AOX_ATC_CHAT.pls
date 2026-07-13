PROMPT CREATE OR REPLACE PACKAGE pkg_aox_atc_chat
CREATE OR REPLACE PACKAGE pkg_aox_atc_chat IS
    FUNCTION fn_retrieve_chunks(
        pi_question IN VARCHAR2,
        pi_top_k    IN NUMBER DEFAULT 5
    ) RETURN CLOB;

    FUNCTION fn_answer_question(
        pi_question IN VARCHAR2,
        pi_top_k    IN NUMBER DEFAULT 5
    ) RETURN CLOB;
END pkg_aox_atc_chat;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_atc_chat
CREATE OR REPLACE PACKAGE BODY pkg_aox_atc_chat IS

    c_embed_dims CONSTANT PLS_INTEGER := 1536;

    FUNCTION fn_call_azure_chat(
        pi_system_prompt IN CLOB,
        pi_user_prompt   IN CLOB
    ) RETURN CLOB IS
        v_endpoint    VARCHAR2(500) := fn_get_parameter('AZURE_OPENAI_ENDPOINT');
        v_deployment  VARCHAR2(100) := fn_get_parameter('AZURE_OPENAI_DEPLOYMENT');
        v_api_version VARCHAR2(50)  := fn_get_parameter('AZURE_OPENAI_API_VERSION');
        v_api_key     VARCHAR2(4000) := fn_get_parameter('AZURE_OPENAI_API_KEY');
        v_url         VARCHAR2(2000);
        v_body        CLOB;
        v_response    CLOB;
        v_ai_text     CLOB;
    BEGIN
        IF v_endpoint IS NULL OR v_deployment IS NULL OR v_api_version IS NULL OR v_api_key IS NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'Faltan parametros Azure OpenAI.');
        END IF;

        v_url := RTRIM(v_endpoint, '/')
              || '/openai/deployments/'
              || v_deployment
              || '/chat/completions?api-version='
              || v_api_version;

        SELECT json_object(
            'messages' VALUE json_array(
                json_object('role' VALUE 'system', 'content' VALUE pi_system_prompt),
                json_object('role' VALUE 'user',   'content' VALUE pi_user_prompt)
            ),
            'temperature' VALUE 0.2,
            'max_tokens'  VALUE 900
            RETURNING CLOB
        )
        INTO v_body
        FROM dual;

        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';
        apex_web_service.g_request_headers(2).name  := 'api-key';
        apex_web_service.g_request_headers(2).value := v_api_key;

        v_response := apex_web_service.make_rest_request(
            p_url         => v_url,
            p_http_method => 'POST',
            p_body        => v_body
        );

        SELECT json_value(v_response, '$.choices[0].message.content' RETURNING CLOB)
          INTO v_ai_text
          FROM dual;

        RETURN v_ai_text;
    END fn_call_azure_chat;

    FUNCTION fn_retrieve_chunks(
        pi_question IN VARCHAR2,
        pi_top_k    IN NUMBER DEFAULT 5
    ) RETURN CLOB IS
        v_query_json CLOB;
        v_query_vec  VECTOR;
        v_top_k      NUMBER := GREATEST(1, LEAST(NVL(pi_top_k, 5), 12));
        v_results    json_array_t := json_array_t();
        v_item       json_object_t;
        v_distance   NUMBER;
        v_score      NUMBER;
        v_text       CLOB;
    BEGIN
        IF pi_question IS NULL OR TRIM(pi_question) IS NULL THEN
            RETURN '[]';
        END IF;

        v_query_json := pkg_aox_vector_search.fn_embed_text(SUBSTR(TRIM(pi_question), 1, 4000));
        v_query_vec  := TO_VECTOR(v_query_json, c_embed_dims, FLOAT32);

        FOR rec IN (
            SELECT c.id_chunk,
                   c.doc_id_document,
                   c.chunk_index,
                   c.chunk_text,
                   d.file_name,
                   VECTOR_DISTANCE(c.embedding, v_query_vec, COSINE) AS distance
              FROM atc_kb_chunk c
              JOIN atc_kb_document d ON d.id_document = c.doc_id_document
             WHERE d.status = 'READY'
             ORDER BY VECTOR_DISTANCE(c.embedding, v_query_vec, COSINE)
             FETCH FIRST v_top_k ROWS ONLY
        ) LOOP
            v_distance := rec.distance;
            v_score := GREATEST(0, 1 - NVL(v_distance, 1));
            v_text := rec.chunk_text;

            v_item := json_object_t();
            v_item.put('id_chunk', rec.id_chunk);
            v_item.put('doc_id_document', rec.doc_id_document);
            v_item.put('file_name', rec.file_name);
            v_item.put('chunk_index', rec.chunk_index);
            v_item.put('chunk_text', v_text);
            v_item.put('distance', v_distance);
            v_item.put('score', v_score);
            v_results.append(v_item);
        END LOOP;

        RETURN v_results.to_clob();
    END fn_retrieve_chunks;

    FUNCTION fn_answer_question(
        pi_question IN VARCHAR2,
        pi_top_k    IN NUMBER DEFAULT 5
    ) RETURN CLOB IS
        v_chunks_json CLOB;
        v_arr         json_array_t;
        v_item        json_object_t;
        v_context     CLOB;
        v_system      CLOB;
        v_user        CLOB;
        v_answer      CLOB;
        v_piece       CLOB;
        i             PLS_INTEGER;
    BEGIN
        IF pi_question IS NULL OR TRIM(pi_question) IS NULL THEN
            RETURN 'Necesito que escribas una pregunta.';
        END IF;

        v_chunks_json := fn_retrieve_chunks(pi_question, pi_top_k);
        v_arr := json_array_t.parse(v_chunks_json);

        IF v_arr.get_size() = 0 THEN
            RETURN 'Todavia no hay documentos de ayuda cargados, o no encontre informacion relevante. Subi manuales PDF/DOCX desde APEX para habilitar el asistente ATC.';
        END IF;

        DBMS_LOB.CREATETEMPORARY(v_context, TRUE);

        FOR i IN 0 .. v_arr.get_size() - 1 LOOP
            v_item := TREAT(v_arr.get(i) AS json_object_t);
            v_piece := '[' || NVL(v_item.get_string('file_name'), 'doc')
                    || ' #' || NVL(TO_CHAR(v_item.get_number('chunk_index')), '?')
                    || ']' || CHR(10)
                    || v_item.get_clob('chunk_text')
                    || CHR(10) || CHR(10);
            DBMS_LOB.APPEND(v_context, v_piece);
        END LOOP;

        v_system := 'Sos el asistente de Atencion al Cliente (ATC) de Hasel. '
                 || 'Responde en espanol, claro y breve. Usa SOLO el contexto de documentos provisto. '
                 || 'Si el contexto no alcanza, dilo explicitamente. No inventes funciones ni datos.';

        v_user := 'Contexto de documentos:' || CHR(10) || v_context
               || CHR(10) || 'Pregunta del usuario:' || CHR(10) || pi_question;

        v_answer := fn_call_azure_chat(v_system, v_user);

        IF v_answer IS NULL OR TRIM(v_answer) IS NULL THEN
            RETURN 'No pude generar una respuesta en este momento.';
        END IF;

        RETURN v_answer;
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_ai(
                pi_process_name    => 'PKG_AOX_ATC_CHAT.FN_ANSWER_QUESTION',
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_prompt          => pi_question
            );
            RETURN 'Tuvimos un problema procesando tu pregunta. Detalle: ' || SQLERRM;
    END fn_answer_question;

END pkg_aox_atc_chat;
/
