PROMPT CREATE OR REPLACE PACKAGE pkg_aox_atc_kb
CREATE OR REPLACE PACKAGE pkg_aox_atc_kb IS
    /**
     * Ingesta KB global ATC: sube a OCI bucket, extrae texto, genera chunks y embeddings.
     * Llamar desde formulario APEX (File Browse -> process).
     */
    PROCEDURE pr_ingest_document(
        pi_filename     IN VARCHAR2,
        pi_mime_type    IN VARCHAR2,
        pi_blob         IN BLOB,
        po_document_id  OUT NUMBER
    );

    /** Reprocesa extract+chunks desde el objeto ya guardado en bucket. */
    PROCEDURE pr_reprocess_document(pi_document_id IN NUMBER);

    /**
     * Actualiza el texto del documento, sincroniza el bucket (.txt UTF-8)
     * y regenera chunks/embeddings. Pensado para edicion desde APEX.
     */
    PROCEDURE pr_set_text_and_process(
        pi_document_id IN NUMBER,
        pi_text        IN CLOB
    );

    PROCEDURE pr_delete_document(pi_document_id IN NUMBER);

    FUNCTION fn_list_documents RETURN CLOB;
END pkg_aox_atc_kb;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_atc_kb
CREATE OR REPLACE PACKAGE BODY pkg_aox_atc_kb IS

    c_chunk_size    CONSTANT PLS_INTEGER := 1000;
    c_chunk_overlap CONSTANT PLS_INTEGER := 150;
    c_embed_dims    CONSTANT PLS_INTEGER := 1536;

    PROCEDURE pr_set_status(
        pi_document_id IN NUMBER,
        pi_status      IN VARCHAR2,
        pi_error       IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        UPDATE atc_kb_document
           SET status        = pi_status,
               error_message = CASE WHEN pi_status = 'ERROR' THEN SUBSTR(pi_error, 1, 4000) ELSE NULL END,
               updated_at    = CURRENT_TIMESTAMP
         WHERE id_document = pi_document_id;
    END pr_set_status;

    FUNCTION fn_blob_to_clob(pi_blob IN BLOB) RETURN CLOB IS
        v_clob CLOB;
        v_dest INTEGER := 1;
        v_src  INTEGER := 1;
        v_ctx  INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
        v_warn INTEGER;
    BEGIN
        IF pi_blob IS NULL OR DBMS_LOB.GETLENGTH(pi_blob) = 0 THEN
            RETURN NULL;
        END IF;

        DBMS_LOB.CREATETEMPORARY(v_clob, TRUE);
        DBMS_LOB.CONVERTTOCLOB(
            dest_lob     => v_clob,
            src_blob     => pi_blob,
            amount       => DBMS_LOB.LOBMAXSIZE,
            dest_offset  => v_dest,
            src_offset   => v_src,
            blob_csid    => NLS_CHARSET_ID('AL32UTF8'),
            lang_context => v_ctx,
            warning      => v_warn
        );
        RETURN v_clob;
    END fn_blob_to_clob;

    FUNCTION fn_strip_xml(pi_xml IN CLOB) RETURN CLOB IS
        v_text CLOB;
    BEGIN
        IF pi_xml IS NULL THEN
            RETURN NULL;
        END IF;

        v_text := REGEXP_REPLACE(pi_xml, '<[^>]+>', ' ');
        v_text := REGEXP_REPLACE(v_text, '&amp;', '&');
        v_text := REGEXP_REPLACE(v_text, '&lt;', '<');
        v_text := REGEXP_REPLACE(v_text, '&gt;', '>');
        v_text := REGEXP_REPLACE(v_text, '&quot;', '"');
        v_text := REGEXP_REPLACE(v_text, '&#160;|&nbsp;', ' ');
        v_text := REGEXP_REPLACE(v_text, '[[:space:]]+', ' ');
        RETURN TRIM(v_text);
    END fn_strip_xml;

    FUNCTION fn_extract_docx(pi_blob IN BLOB) RETURN CLOB IS
        v_xml  BLOB;
        v_clob CLOB;
    BEGIN
        v_xml := APEX_ZIP.GET_FILE_CONTENT(
            p_zipped_blob => pi_blob,
            p_file_name   => 'word/document.xml'
        );

        IF v_xml IS NULL OR DBMS_LOB.GETLENGTH(v_xml) = 0 THEN
            RAISE_APPLICATION_ERROR(-20031, 'DOCX sin word/document.xml.');
        END IF;

        v_clob := fn_blob_to_clob(v_xml);
        RETURN fn_strip_xml(v_clob);
    END fn_extract_docx;

    FUNCTION fn_extract_pdf_di(pi_blob IN BLOB) RETURN CLOB IS
        v_endpoint    VARCHAR2(500) := fn_get_parameter('AZURE_DI_ENDPOINT');
        v_api_key     VARCHAR2(4000) := fn_get_parameter('AZURE_DI_API_KEY');
        v_api_version VARCHAR2(50) := NVL(fn_get_parameter('AZURE_DI_API_VERSION'), '2024-11-30');
        v_url         VARCHAR2(2000);
        v_op_loc      VARCHAR2(2000);
        v_response    CLOB;
        v_status      VARCHAR2(50);
        v_result      CLOB;
        v_text        CLOB;
        i             PLS_INTEGER;
    BEGIN
        IF v_endpoint IS NULL OR v_api_key IS NULL THEN
            RAISE_APPLICATION_ERROR(
                -20032,
                'PDF requiere AZURE_DI_ENDPOINT y AZURE_DI_API_KEY, o usar pr_set_text_and_process.'
            );
        END IF;

        v_url := RTRIM(v_endpoint, '/')
              || '/documentintelligence/documentModels/prebuilt-read:analyze?api-version='
              || v_api_version;

        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/pdf';
        apex_web_service.g_request_headers(2).name  := 'Ocp-Apim-Subscription-Key';
        apex_web_service.g_request_headers(2).value := v_api_key;

        v_response := apex_web_service.make_rest_request(
            p_url         => v_url,
            p_http_method => 'POST',
            p_body_blob   => pi_blob
        );

        IF apex_web_service.g_status_code NOT IN (200, 202) THEN
            RAISE_APPLICATION_ERROR(
                -20033,
                'Document Intelligence analyze fallo HTTP ' || apex_web_service.g_status_code
            );
        END IF;

        FOR i IN 1 .. apex_web_service.g_headers.COUNT LOOP
            IF LOWER(apex_web_service.g_headers(i).name) IN ('operation-location', 'operationlocation') THEN
                v_op_loc := apex_web_service.g_headers(i).value;
                EXIT;
            END IF;
        END LOOP;

        IF v_op_loc IS NULL THEN
            RAISE_APPLICATION_ERROR(-20033, 'Document Intelligence no devolvio Operation-Location.');
        END IF;

        FOR i IN 1 .. 30 LOOP
            apex_web_service.g_request_headers.delete;
            apex_web_service.g_request_headers(1).name  := 'Ocp-Apim-Subscription-Key';
            apex_web_service.g_request_headers(1).value := v_api_key;

            v_result := apex_web_service.make_rest_request(
                p_url         => v_op_loc,
                p_http_method => 'GET'
            );

            SELECT JSON_VALUE(v_result, '$.status')
              INTO v_status
              FROM dual;

            EXIT WHEN UPPER(NVL(v_status, 'X')) IN ('SUCCEEDED', 'FAILED');
            DBMS_SESSION.SLEEP(2);
        END LOOP;

        IF UPPER(NVL(v_status, 'X')) != 'SUCCEEDED' THEN
            RAISE_APPLICATION_ERROR(-20033, 'Document Intelligence status=' || NVL(v_status, 'NULL'));
        END IF;

        SELECT JSON_VALUE(v_result, '$.analyzeResult.content' RETURNING CLOB)
          INTO v_text
          FROM dual;

        IF v_text IS NULL OR DBMS_LOB.GETLENGTH(v_text) = 0 THEN
            RAISE_APPLICATION_ERROR(-20033, 'Document Intelligence no extrajo texto.');
        END IF;

        RETURN v_text;
    END fn_extract_pdf_di;

    FUNCTION fn_extract_text(
        pi_blob      IN BLOB,
        pi_mime_type IN VARCHAR2,
        pi_filename  IN VARCHAR2
    ) RETURN CLOB IS
        v_mime VARCHAR2(150) := LOWER(NVL(TRIM(pi_mime_type), ''));
        v_name VARCHAR2(255) := LOWER(NVL(TRIM(pi_filename), ''));
    BEGIN
        IF v_mime LIKE 'text/%' OR v_name LIKE '%.txt' OR v_name LIKE '%.md' THEN
            RETURN fn_blob_to_clob(pi_blob);
        END IF;

        IF v_mime LIKE '%wordprocessingml%' OR v_mime LIKE '%docx%' OR v_name LIKE '%.docx' THEN
            RETURN fn_extract_docx(pi_blob);
        END IF;

        IF v_mime = 'application/pdf' OR v_name LIKE '%.pdf' THEN
            RETURN fn_extract_pdf_di(pi_blob);
        END IF;

        RAISE_APPLICATION_ERROR(-20034, 'Tipo de archivo no soportado: ' || NVL(pi_mime_type, pi_filename));
    END fn_extract_text;

    PROCEDURE pr_build_chunks(
        pi_document_id IN NUMBER,
        pi_text        IN CLOB
    ) IS
        v_len      INTEGER;
        v_pos      INTEGER := 1;
        v_idx      INTEGER := 0;
        v_chunk    VARCHAR2(4000);
        v_end      INTEGER;
        v_emb_json CLOB;
        v_emb_vec  VECTOR;
        v_step     INTEGER := GREATEST(1, c_chunk_size - c_chunk_overlap);
    BEGIN
        DELETE FROM atc_kb_chunk WHERE doc_id_document = pi_document_id;

        IF pi_text IS NULL OR DBMS_LOB.GETLENGTH(pi_text) = 0 THEN
            RAISE_APPLICATION_ERROR(-20035, 'Texto vacio para chunking.');
        END IF;

        v_len := DBMS_LOB.GETLENGTH(pi_text);

        WHILE v_pos <= v_len LOOP
            v_end := LEAST(v_pos + c_chunk_size - 1, v_len);
            v_chunk := DBMS_LOB.SUBSTR(pi_text, v_end - v_pos + 1, v_pos);
            v_chunk := TRIM(v_chunk);

            IF v_chunk IS NOT NULL AND LENGTH(v_chunk) > 20 THEN
                v_idx := v_idx + 1;
                v_emb_json := pkg_aox_vector_search.fn_embed_text(SUBSTR(v_chunk, 1, 4000));
                v_emb_vec := TO_VECTOR(v_emb_json, c_embed_dims, FLOAT32);

                INSERT INTO atc_kb_chunk (
                    doc_id_document,
                    chunk_index,
                    chunk_text,
                    embedding,
                    updated_at
                ) VALUES (
                    pi_document_id,
                    v_idx,
                    v_chunk,
                    v_emb_vec,
                    CURRENT_TIMESTAMP
                );
            END IF;

            EXIT WHEN v_end >= v_len;
            v_pos := v_pos + v_step;
        END LOOP;

        IF v_idx = 0 THEN
            RAISE_APPLICATION_ERROR(-20035, 'No se generaron chunks utiles.');
        END IF;
    END pr_build_chunks;

    PROCEDURE pr_process_blob(
        pi_document_id IN NUMBER,
        pi_blob        IN BLOB,
        pi_mime_type   IN VARCHAR2,
        pi_filename    IN VARCHAR2
    ) IS
        v_text CLOB;
    BEGIN
        pr_set_status(pi_document_id, 'PROCESSING');

        v_text := fn_extract_text(pi_blob, pi_mime_type, pi_filename);

        UPDATE atc_kb_document
           SET extracted_text = v_text,
               updated_at     = CURRENT_TIMESTAMP
         WHERE id_document = pi_document_id;

        pr_build_chunks(pi_document_id, v_text);
        pr_set_status(pi_document_id, 'READY');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pr_set_status(pi_document_id, 'ERROR', SQLERRM);
            COMMIT;
            RAISE;
    END pr_process_blob;

    PROCEDURE pr_ingest_document(
        pi_filename     IN VARCHAR2,
        pi_mime_type    IN VARCHAR2,
        pi_blob         IN BLOB,
        po_document_id  OUT NUMBER
    ) IS
        v_url         VARCHAR2(1000);
        v_object_key  VARCHAR2(500);
        v_size_bytes  NUMBER;
        v_placeholder VARCHAR2(20) := 'pending';
    BEGIN
        IF pi_blob IS NULL OR DBMS_LOB.GETLENGTH(pi_blob) = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'El archivo esta vacio.');
        END IF;

        v_size_bytes := DBMS_LOB.GETLENGTH(pi_blob);

        INSERT INTO atc_kb_document (
            file_name,
            mime_type,
            size_bytes,
            storage_url,
            object_key,
            status
        ) VALUES (
            NVL(TRIM(pi_filename), 'documento'),
            NVL(TRIM(pi_mime_type), 'application/octet-stream'),
            v_size_bytes,
            v_placeholder,
            v_placeholder,
            'PENDING'
        ) RETURNING id_document INTO po_document_id;

        pkg_aox_bucket.pr_upload_atc_kb_document(
            pi_blob        => pi_blob,
            pi_filename    => pi_filename,
            pi_mime_type   => pi_mime_type,
            pi_document_id => po_document_id,
            po_url         => v_url,
            po_object_key  => v_object_key
        );

        UPDATE atc_kb_document
           SET storage_url = v_url,
               object_key  = v_object_key,
               updated_at  = CURRENT_TIMESTAMP
         WHERE id_document = po_document_id;

        COMMIT;

        pr_process_blob(po_document_id, pi_blob, pi_mime_type, pi_filename);
    EXCEPTION
        WHEN OTHERS THEN
            IF po_document_id IS NOT NULL THEN
                BEGIN
                    pr_set_status(po_document_id, 'ERROR', SQLERRM);
                    COMMIT;
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
            END IF;
            RAISE;
    END pr_ingest_document;

    PROCEDURE pr_reprocess_document(pi_document_id IN NUMBER) IS
        v_url      atc_kb_document.storage_url%TYPE;
        v_mime     atc_kb_document.mime_type%TYPE;
        v_name     atc_kb_document.file_name%TYPE;
        v_blob     BLOB;
    BEGIN
        SELECT storage_url, mime_type, file_name
          INTO v_url, v_mime, v_name
          FROM atc_kb_document
         WHERE id_document = pi_document_id;

        v_blob := pkg_aox_bucket.fn_download_atc_kb_document(v_url);
        pr_process_blob(pi_document_id, v_blob, v_mime, v_name);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20036, 'Documento ATC no encontrado.');
    END pr_reprocess_document;

    FUNCTION fn_clob_to_blob_utf8(pi_clob IN CLOB) RETURN BLOB IS
        v_blob BLOB;
        v_dest INTEGER := 1;
        v_src  INTEGER := 1;
        v_ctx  INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
        v_warn INTEGER;
    BEGIN
        IF pi_clob IS NULL OR DBMS_LOB.GETLENGTH(pi_clob) = 0 THEN
            RETURN NULL;
        END IF;

        DBMS_LOB.CREATETEMPORARY(v_blob, TRUE);
        DBMS_LOB.CONVERTTOBLOB(
            dest_lob     => v_blob,
            src_clob     => pi_clob,
            amount       => DBMS_LOB.LOBMAXSIZE,
            dest_offset  => v_dest,
            src_offset   => v_src,
            blob_csid    => NLS_CHARSET_ID('AL32UTF8'),
            lang_context => v_ctx,
            warning      => v_warn
        );
        RETURN v_blob;
    END fn_clob_to_blob_utf8;

    FUNCTION fn_txt_file_name(pi_file_name IN VARCHAR2) RETURN VARCHAR2 IS
        v_name VARCHAR2(255) := NVL(TRIM(pi_file_name), 'documento');
        v_stem VARCHAR2(255);
    BEGIN
        IF LOWER(v_name) LIKE '%.txt' THEN
            RETURN SUBSTR(v_name, 1, 255);
        END IF;

        IF INSTR(v_name, '.', -1) > 1 THEN
            v_stem := SUBSTR(v_name, 1, INSTR(v_name, '.', -1) - 1);
        ELSE
            v_stem := v_name;
        END IF;

        RETURN SUBSTR(v_stem || '.txt', 1, 255);
    END fn_txt_file_name;

    PROCEDURE pr_set_text_and_process(
        pi_document_id IN NUMBER,
        pi_text        IN CLOB
    ) IS
        v_file_name   atc_kb_document.file_name%TYPE;
        v_object_key  atc_kb_document.object_key%TYPE;
        v_url         atc_kb_document.storage_url%TYPE;
        v_new_name    VARCHAR2(255);
        v_blob        BLOB;
        v_new_url     VARCHAR2(1000);
        v_new_key     VARCHAR2(500);
        v_size_bytes  NUMBER;
    BEGIN
        IF pi_text IS NULL OR DBMS_LOB.GETLENGTH(pi_text) = 0 THEN
            RAISE_APPLICATION_ERROR(-20035, 'El texto editado esta vacio.');
        END IF;

        BEGIN
            SELECT file_name, object_key, storage_url
              INTO v_file_name, v_object_key, v_url
              FROM atc_kb_document
             WHERE id_document = pi_document_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20036, 'Documento ATC no encontrado.');
        END;

        pr_set_status(pi_document_id, 'PROCESSING');

        BEGIN
            pkg_aox_bucket.pr_delete_atc_kb_document(NVL(v_url, v_object_key));
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        v_new_name := fn_txt_file_name(v_file_name);
        v_blob := fn_clob_to_blob_utf8(pi_text);
        v_size_bytes := DBMS_LOB.GETLENGTH(v_blob);

        pkg_aox_bucket.pr_upload_atc_kb_document(
            pi_blob        => v_blob,
            pi_filename    => v_new_name,
            pi_mime_type   => 'text/plain',
            pi_document_id => pi_document_id,
            po_url         => v_new_url,
            po_object_key  => v_new_key
        );

        UPDATE atc_kb_document
           SET file_name      = v_new_name,
               mime_type      = 'text/plain',
               size_bytes     = v_size_bytes,
               storage_url    = v_new_url,
               object_key     = v_new_key,
               extracted_text = pi_text,
               updated_at     = CURRENT_TIMESTAMP
         WHERE id_document = pi_document_id;

        pr_build_chunks(pi_document_id, pi_text);
        pr_set_status(pi_document_id, 'READY');
        COMMIT;

        IF v_blob IS NOT NULL THEN
            DBMS_LOB.FREETEMPORARY(v_blob);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            IF v_blob IS NOT NULL THEN
                BEGIN
                    DBMS_LOB.FREETEMPORARY(v_blob);
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
            END IF;
            ROLLBACK;
            pr_set_status(pi_document_id, 'ERROR', SQLERRM);
            COMMIT;
            RAISE;
    END pr_set_text_and_process;

    PROCEDURE pr_delete_document(pi_document_id IN NUMBER) IS
        v_object_key atc_kb_document.object_key%TYPE;
        v_url        atc_kb_document.storage_url%TYPE;
    BEGIN
        SELECT object_key, storage_url
          INTO v_object_key, v_url
          FROM atc_kb_document
         WHERE id_document = pi_document_id;

        DELETE FROM atc_kb_chunk WHERE doc_id_document = pi_document_id;
        DELETE FROM atc_kb_document WHERE id_document = pi_document_id;

        BEGIN
            pkg_aox_bucket.pr_delete_atc_kb_document(NVL(v_url, v_object_key));
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20036, 'Documento ATC no encontrado.');
    END pr_delete_document;

    FUNCTION fn_list_documents RETURN CLOB IS
        v_arr json_array_t := json_array_t();
        v_obj json_object_t;
    BEGIN
        FOR rec IN (
            SELECT id_document,
                   file_name,
                   mime_type,
                   size_bytes,
                   storage_url,
                   status,
                   error_message,
                   TO_CHAR(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at,
                   TO_CHAR(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS updated_at,
                   (SELECT COUNT(*) FROM atc_kb_chunk c WHERE c.doc_id_document = d.id_document) AS chunk_count
              FROM atc_kb_document d
             ORDER BY id_document DESC
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('id_document', rec.id_document);
            v_obj.put('file_name', rec.file_name);
            v_obj.put('mime_type', rec.mime_type);
            v_obj.put('size_bytes', rec.size_bytes);
            v_obj.put('storage_url', rec.storage_url);
            v_obj.put('status', rec.status);
            v_obj.put('error_message', rec.error_message);
            v_obj.put('created_at', rec.created_at);
            v_obj.put('updated_at', rec.updated_at);
            v_obj.put('chunk_count', rec.chunk_count);
            v_arr.append(v_obj);
        END LOOP;

        RETURN v_arr.to_clob();
    END fn_list_documents;

END pkg_aox_atc_kb;
/
