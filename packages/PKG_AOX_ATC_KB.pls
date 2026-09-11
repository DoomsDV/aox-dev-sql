PROMPT CREATE OR REPLACE PACKAGE pkg_aox_atc_kb
CREATE OR REPLACE PACKAGE pkg_aox_atc_kb IS
    /**
     * Deprecated: la KB ATC se gestiona en HASEL_ADMIN (panel admin).
     * Hasel solo consume hasel_admin.ops_atc_kb_* via PKG_AOX_ATC_CHAT.
     */
    PROCEDURE pr_ingest_document(
        pi_filename     IN VARCHAR2,
        pi_mime_type    IN VARCHAR2,
        pi_blob         IN BLOB,
        po_document_id  OUT NUMBER
    );

    PROCEDURE pr_reprocess_document(pi_document_id IN NUMBER);

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

    PROCEDURE pr_raise_moved IS
    BEGIN
        RAISE_APPLICATION_ERROR(
            -20036,
            'La base de conocimiento del chatbot se gestiona en el panel admin (HASEL_ADMIN).'
        );
    END pr_raise_moved;

    PROCEDURE pr_ingest_document(
        pi_filename     IN VARCHAR2,
        pi_mime_type    IN VARCHAR2,
        pi_blob         IN BLOB,
        po_document_id  OUT NUMBER
    ) IS
    BEGIN
        po_document_id := NULL;
        pr_raise_moved;
    END pr_ingest_document;

    PROCEDURE pr_reprocess_document(pi_document_id IN NUMBER) IS
    BEGIN
        pr_raise_moved;
    END pr_reprocess_document;

    PROCEDURE pr_set_text_and_process(
        pi_document_id IN NUMBER,
        pi_text        IN CLOB
    ) IS
    BEGIN
        pr_raise_moved;
    END pr_set_text_and_process;

    PROCEDURE pr_delete_document(pi_document_id IN NUMBER) IS
    BEGIN
        pr_raise_moved;
    END pr_delete_document;

    FUNCTION fn_list_documents RETURN CLOB IS
    BEGIN
        pr_raise_moved;
        RETURN '[]';
    END fn_list_documents;

END pkg_aox_atc_kb;
/