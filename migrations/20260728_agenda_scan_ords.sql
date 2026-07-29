-- Escaneo de agenda manuscrita -> citas masivas (IA visión)
-- 1) customer.phone_number pasa a NULLABLE (permite guardar citas de escaneo sin teléfono).
-- 2) Handler ORDS POST /ai/appointments/image-draft -> PKG_AOX_IA_API.PR_PARSE_AGENDA_IMAGE
-- 3) Recompilación del esquema.
--
-- Requiere desplegar antes (o junto):
--   @packages/PKG_AOX_BUCKET.pls
--   @packages/PKG_AOX_IA_MANAGER.pls
--   @packages/PKG_AOX_IA_API.pls
--   @packages/PKG_AOX_APPOINTMENT_API.pls

-- 1) Teléfono opcional en customer -------------------------------------------
DECLARE
    v_nullable VARCHAR2(1);
BEGIN
    SELECT nullable
      INTO v_nullable
      FROM user_tab_columns
     WHERE table_name = 'CUSTOMER'
       AND column_name = 'PHONE_NUMBER';

    IF v_nullable = 'N' THEN
        EXECUTE IMMEDIATE 'ALTER TABLE customer MODIFY (phone_number NULL)';
    END IF;
END;
/

-- 2) Handler ORDS ------------------------------------------------------------
BEGIN
    ORDS.define_template(
        p_module_name => 'ai',
        p_pattern     => 'appointments/image-draft'
    );

    ORDS.define_handler(
        p_module_name => 'ai',
        p_pattern     => 'appointments/image-draft',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
    v_body_clob     CLOB;
    v_dest_offset   INTEGER := 1;
    v_src_offset    INTEGER := 1;
    v_lang_context  INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
    v_warning       INTEGER;
BEGIN
    IF :body IS NOT NULL THEN
        DBMS_LOB.CREATETEMPORARY(v_body_clob, TRUE);
        DBMS_LOB.CONVERTTOCLOB(
            dest_lob     => v_body_clob,
            src_blob     => :body,
            amount       => DBMS_LOB.LOBMAXSIZE,
            dest_offset  => v_dest_offset,
            src_offset   => v_src_offset,
            blob_csid    => DBMS_LOB.DEFAULT_CSID,
            lang_context => v_lang_context,
            warning      => v_warning
        );
    END IF;

    pkg_aox_ia_api.pr_parse_agenda_image(
        pi_auth_header   => owa_util.get_cgi_env('HTTP_AUTHORIZATION'),
        pi_body          => v_body_clob,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );

    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    htp.prn(v_response_body);
END;
        ]'
    );

    COMMIT;
END;
/

-- 3) Recompilación -----------------------------------------------------------
BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/
