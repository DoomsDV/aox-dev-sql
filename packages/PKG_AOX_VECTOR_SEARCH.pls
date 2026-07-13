PROMPT CREATE OR REPLACE PACKAGE pkg_aox_vector_search
CREATE OR REPLACE PACKAGE pkg_aox_vector_search IS
    c_entity_customer     CONSTANT VARCHAR2(30) := 'CUSTOMER';
    c_entity_professional CONSTANT VARCHAR2(30) := 'PROFESSIONAL';
    c_entity_service      CONSTANT VARCHAR2(30) := 'SERVICE';
    c_entity_location     CONSTANT VARCHAR2(30) := 'LOCATION';
    c_embedding_dims      CONSTANT PLS_INTEGER := 1536;

    /** Llama Azure OpenAI embeddings y devuelve el array JSON del vector. */
    FUNCTION fn_embed_text(pi_text IN VARCHAR2) RETURN CLOB;

    /** Indexa o actualiza un embedding de entidad de la org. */
    PROCEDURE pr_sync_entity_embedding(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_entity_id   IN NUMBER
    );

    /** Elimina el embedding de una entidad. */
    PROCEDURE pr_delete_entity_embedding(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_entity_id   IN NUMBER
    );

    /** Reindexa todas las entidades activas de una organizacion. */
    PROCEDURE pr_sync_org_embeddings(pi_org_id IN NUMBER);

    /** Reindexa todas las organizaciones (job nocturno / mantenimiento). */
    PROCEDURE pr_sync_all_orgs_embeddings;

    /**
     * Punto de entrada para triggers DML.
     * No propaga errores de Azure para no bloquear altas/ediciones.
     */
    PROCEDURE pr_on_entity_embedding_changed(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_entity_id   IN NUMBER,
        pi_deleted     IN BOOLEAN DEFAULT FALSE
    );

    /**
     * Busqueda top-k por similitud coseno dentro de la org.
     * Retorna JSON array: [{entity_type, entity_id, source_text, label, distance, score}, ...]
     */
    FUNCTION fn_search_top_k(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_query_text  IN VARCHAR2,
        pi_top_k       IN NUMBER DEFAULT 5
    ) RETURN CLOB;

END pkg_aox_vector_search;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_vector_search
CREATE OR REPLACE PACKAGE BODY pkg_aox_vector_search IS

    FUNCTION fn_embedding_dimensions RETURN PLS_INTEGER IS
        v_dims NUMBER := NVL(TO_NUMBER(fn_get_parameter('AZURE_OPENAI_EMBEDDING_DIMENSIONS')), c_embedding_dims);
    BEGIN
        IF v_dims <= 0 THEN
            RETURN c_embedding_dims;
        END IF;
        RETURN TRUNC(v_dims);
    END fn_embedding_dimensions;

    FUNCTION fn_call_azure_openai_embedding(pi_text IN VARCHAR2) RETURN CLOB IS
        v_endpoint    VARCHAR2(500) := fn_get_parameter('AZURE_OPENAI_ENDPOINT');
        v_deployment  VARCHAR2(100) := fn_get_parameter('AZURE_OPENAI_EMBEDDING_DEPLOYMENT');
        v_api_version VARCHAR2(50)  := NVL(
            fn_get_parameter('AZURE_OPENAI_EMBEDDING_API_VERSION'),
            fn_get_parameter('AZURE_OPENAI_API_VERSION')
        );
        v_api_key     VARCHAR2(4000) := fn_get_parameter('AZURE_OPENAI_API_KEY');
        v_url         VARCHAR2(2000);
        v_body        CLOB;
        v_response    CLOB;
        v_embedding   CLOB;
        v_input       VARCHAR2(4000) := SUBSTR(TRIM(pi_text), 1, 4000);
    BEGIN
        IF v_input IS NULL THEN
            RETURN NULL;
        END IF;

        IF v_endpoint IS NULL OR v_deployment IS NULL OR v_api_version IS NULL OR v_api_key IS NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'Faltan parametros Azure OpenAI para embeddings.');
        END IF;

        v_url := RTRIM(v_endpoint, '/')
              || '/openai/deployments/'
              || v_deployment
              || '/embeddings?api-version='
              || v_api_version;

        SELECT json_object(
            'input' VALUE v_input
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

        SELECT JSON_QUERY(v_response, '$.data[0].embedding' RETURNING CLOB)
        INTO v_embedding
        FROM dual;

        RETURN v_embedding;
    END fn_call_azure_openai_embedding;

    FUNCTION fn_embedding_json_to_vector(pi_embedding_json IN CLOB) RETURN VECTOR IS
        v_dims PLS_INTEGER := fn_embedding_dimensions();
    BEGIN
        IF pi_embedding_json IS NULL OR DBMS_LOB.GETLENGTH(pi_embedding_json) = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Embedding vacio.');
        END IF;

        RETURN TO_VECTOR(pi_embedding_json, v_dims, FLOAT32);
    END fn_embedding_json_to_vector;

    FUNCTION fn_embed_text(pi_text IN VARCHAR2) RETURN CLOB IS
    BEGIN
        RETURN fn_call_azure_openai_embedding(pi_text);
    END fn_embed_text;

    FUNCTION fn_build_customer_source(pi_org_id IN NUMBER, pi_entity_id IN NUMBER) RETURN VARCHAR2 IS
        v_text VARCHAR2(1000);
    BEGIN
        SELECT TRIM(full_name) || ' | tel: ' || TRIM(phone_number)
        INTO v_text
        FROM customer
        WHERE id_customer = pi_entity_id
          AND org_id_organization = pi_org_id;

        RETURN SUBSTR(v_text, 1, 1000);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_build_customer_source;

    FUNCTION fn_build_professional_source(pi_org_id IN NUMBER, pi_entity_id IN NUMBER) RETURN VARCHAR2 IS
        v_text VARCHAR2(1000);
    BEGIN
        SELECT SUBSTR(
            TRIM(
                NVL(
                    p.display_name,
                    NVL(TRIM(u.first_name || ' ' || u.last_name), TRIM(p.profile_slug))
                )
            )
            || CASE WHEN s.name IS NOT NULL THEN ' | ' || TRIM(s.name) ELSE '' END,
            1,
            1000
        )
        INTO v_text
        FROM professional p
        LEFT JOIN app_user u ON u.id_user = p.usr_id_user
        LEFT JOIN specialty s ON s.id_specialty = p.spe_id_specialty
        WHERE p.id_professional = pi_entity_id
          AND p.org_id_organization = pi_org_id
          AND p.is_active = 1;

        RETURN NULLIF(TRIM(v_text), '');
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_build_professional_source;

    FUNCTION fn_build_service_source(pi_org_id IN NUMBER, pi_entity_id IN NUMBER) RETURN VARCHAR2 IS
        v_text VARCHAR2(1000);
    BEGIN
        SELECT SUBSTR(TRIM(name) || ' | duracion: ' || NVL(duration_minutes, 60) || ' min', 1, 1000)
        INTO v_text
        FROM service
        WHERE id_service = pi_entity_id
          AND org_id_organization = pi_org_id
          AND is_active = 1;

        RETURN NULLIF(TRIM(v_text), '');
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_build_service_source;

    FUNCTION fn_build_location_source(pi_org_id IN NUMBER, pi_entity_id IN NUMBER) RETURN VARCHAR2 IS
        v_text VARCHAR2(1000);
    BEGIN
        SELECT SUBSTR(TRIM(name) || ' | ' || TRIM(address), 1, 1000)
        INTO v_text
        FROM location
        WHERE id_location = pi_entity_id
          AND org_id_organization = pi_org_id
          AND is_active = 1;

        RETURN NULLIF(TRIM(v_text), '');
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_build_location_source;

    FUNCTION fn_build_entity_source(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_entity_id   IN NUMBER
    ) RETURN VARCHAR2 IS
    BEGIN
        CASE UPPER(TRIM(pi_entity_type))
            WHEN c_entity_customer THEN
                RETURN fn_build_customer_source(pi_org_id, pi_entity_id);
            WHEN c_entity_professional THEN
                RETURN fn_build_professional_source(pi_org_id, pi_entity_id);
            WHEN c_entity_service THEN
                RETURN fn_build_service_source(pi_org_id, pi_entity_id);
            WHEN c_entity_location THEN
                RETURN fn_build_location_source(pi_org_id, pi_entity_id);
            ELSE
                RAISE_APPLICATION_ERROR(-20003, 'entity_type invalido: ' || pi_entity_type);
        END CASE;
    END fn_build_entity_source;

    PROCEDURE pr_delete_entity_embedding(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_entity_id   IN NUMBER
    ) IS
    BEGIN
        DELETE FROM org_entity_embedding
         WHERE org_id_organization = pi_org_id
           AND entity_type = UPPER(TRIM(pi_entity_type))
           AND entity_id = pi_entity_id;
    END pr_delete_entity_embedding;

    PROCEDURE pr_upsert_entity_embedding(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_entity_id   IN NUMBER,
        pi_source_text IN VARCHAR2,
        pi_embedding   IN VECTOR
    ) IS
    BEGIN
        MERGE INTO org_entity_embedding t
        USING (
            SELECT
                pi_org_id AS org_id_organization,
                UPPER(TRIM(pi_entity_type)) AS entity_type,
                pi_entity_id AS entity_id,
                pi_source_text AS source_text,
                pi_embedding AS embedding
              FROM dual
        ) s
        ON (
            t.org_id_organization = s.org_id_organization
            AND t.entity_type = s.entity_type
            AND t.entity_id = s.entity_id
        )
        WHEN MATCHED THEN
            UPDATE SET
                t.source_text = s.source_text,
                t.embedding   = s.embedding,
                t.updated_at  = CURRENT_TIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (
                org_id_organization,
                entity_type,
                entity_id,
                source_text,
                embedding,
                updated_at
            ) VALUES (
                s.org_id_organization,
                s.entity_type,
                s.entity_id,
                s.source_text,
                s.embedding,
                CURRENT_TIMESTAMP
            );
    END pr_upsert_entity_embedding;

    PROCEDURE pr_sync_entity_embedding(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_entity_id   IN NUMBER
    ) IS
        v_source_text    VARCHAR2(1000);
        v_embedding_json CLOB;
        v_embedding_vec  VECTOR;
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 OR NVL(pi_entity_id, 0) <= 0 THEN
            RETURN;
        END IF;

        v_source_text := fn_build_entity_source(pi_org_id, pi_entity_type, pi_entity_id);

        IF v_source_text IS NULL THEN
            pr_delete_entity_embedding(pi_org_id, pi_entity_type, pi_entity_id);
            RETURN;
        END IF;

        v_embedding_json := fn_call_azure_openai_embedding(v_source_text);
        v_embedding_vec  := fn_embedding_json_to_vector(v_embedding_json);

        pr_upsert_entity_embedding(
            pi_org_id,
            pi_entity_type,
            pi_entity_id,
            v_source_text,
            v_embedding_vec
        );
    END pr_sync_entity_embedding;

    PROCEDURE pr_sync_org_embeddings(pi_org_id IN NUMBER) IS
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 THEN
            RETURN;
        END IF;

        FOR rec IN (
            SELECT id_customer AS entity_id
              FROM customer
             WHERE org_id_organization = pi_org_id
        ) LOOP
            pr_sync_entity_embedding(pi_org_id, c_entity_customer, rec.entity_id);
        END LOOP;

        FOR rec IN (
            SELECT id_professional AS entity_id
              FROM professional
             WHERE org_id_organization = pi_org_id
               AND is_active = 1
        ) LOOP
            pr_sync_entity_embedding(pi_org_id, c_entity_professional, rec.entity_id);
        END LOOP;

        FOR rec IN (
            SELECT id_service AS entity_id
              FROM service
             WHERE org_id_organization = pi_org_id
               AND is_active = 1
        ) LOOP
            pr_sync_entity_embedding(pi_org_id, c_entity_service, rec.entity_id);
        END LOOP;

        FOR rec IN (
            SELECT id_location AS entity_id
              FROM location
             WHERE org_id_organization = pi_org_id
               AND is_active = 1
        ) LOOP
            pr_sync_entity_embedding(pi_org_id, c_entity_location, rec.entity_id);
        END LOOP;
    END pr_sync_org_embeddings;

    PROCEDURE pr_sync_all_orgs_embeddings IS
    BEGIN
        FOR rec IN (
            SELECT id_organization
              FROM organization
             ORDER BY id_organization
        ) LOOP
            BEGIN
                pr_sync_org_embeddings(rec.id_organization);
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    ROLLBACK;
            END;
        END LOOP;
    END pr_sync_all_orgs_embeddings;

    PROCEDURE pr_on_entity_embedding_changed(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_entity_id   IN NUMBER,
        pi_deleted     IN BOOLEAN DEFAULT FALSE
    ) IS
        v_params json_object_t := json_object_t();
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 OR NVL(pi_entity_id, 0) <= 0 THEN
            RETURN;
        END IF;

        IF pi_deleted THEN
            pr_delete_entity_embedding(pi_org_id, pi_entity_type, pi_entity_id);
        ELSE
            pr_sync_entity_embedding(pi_org_id, pi_entity_type, pi_entity_id);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            v_params.put('entity_type', UPPER(TRIM(pi_entity_type)));
            v_params.put('entity_id', pi_entity_id);
            v_params.put('deleted', CASE WHEN pi_deleted THEN 'true' ELSE 'false' END);
            pkg_aox_util.pr_log_ai(
                pi_process_name    => 'PKG_AOX_VECTOR_SEARCH.PR_ON_ENTITY_EMBEDDING_CHANGED',
                pi_org_id          => pi_org_id,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_parameters      => v_params.to_clob()
            );
    END pr_on_entity_embedding_changed;

    FUNCTION fn_search_top_k(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_query_text  IN VARCHAR2,
        pi_top_k       IN NUMBER DEFAULT 5
    ) RETURN CLOB IS
        v_query_json  CLOB;
        v_query_vec   VECTOR;
        v_top_k       NUMBER := GREATEST(1, LEAST(NVL(pi_top_k, 5), 20));
        v_results     json_array_t := json_array_t();
        v_item        json_object_t;
        v_distance    NUMBER;
        v_score       NUMBER;
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 OR TRIM(pi_query_text) IS NULL THEN
            RETURN v_results.to_clob();
        END IF;

        v_query_json := fn_call_azure_openai_embedding(TRIM(pi_query_text));
        v_query_vec  := fn_embedding_json_to_vector(v_query_json);

        FOR rec IN (
            SELECT
                e.entity_type,
                e.entity_id,
                e.source_text,
                VECTOR_DISTANCE(e.embedding, v_query_vec, COSINE) AS distance
              FROM org_entity_embedding e
             WHERE e.org_id_organization = pi_org_id
               AND e.entity_type = UPPER(TRIM(pi_entity_type))
             ORDER BY distance
             FETCH FIRST v_top_k ROWS ONLY
        ) LOOP
            v_distance := rec.distance;
            v_score      := GREATEST(0, LEAST(1, 1 - NVL(v_distance, 1)));

            v_item := json_object_t();
            v_item.put('entity_type', rec.entity_type);
            v_item.put('entity_id', rec.entity_id);
            v_item.put('source_text', rec.source_text);
            v_item.put('label', rec.source_text);
            v_item.put('distance', ROUND(v_distance, 6));
            v_item.put('score', ROUND(v_score, 6));
            v_results.append(v_item);
        END LOOP;

        RETURN v_results.to_clob();
    END fn_search_top_k;

END pkg_aox_vector_search;
/

