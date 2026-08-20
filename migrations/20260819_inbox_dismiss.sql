-- Soft delete de notificaciones del inbox (campanita).
-- No usar DELETE fisico: pr_ensure_upcoming_holiday_inbox re-encola por dedupe_key.
-- ORDS: POST /inbox/:id/dismiss y POST /inbox/dismiss-all

DECLARE
    v_exists NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_exists
      FROM user_tab_columns
     WHERE table_name = 'USER_NOTIFICATION'
       AND column_name = 'DELETED_AT';

    IF v_exists = 0 THEN
        EXECUTE IMMEDIATE
            'ALTER TABLE user_notification ADD (
                deleted_at TIMESTAMP(6) WITH TIME ZONE NULL
            )';
    END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE
        'CREATE INDEX idx_unotif_member_deleted
            ON user_notification (
                org_member_id,
                deleted_at
            )';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -955 THEN
            RAISE;
        END IF;
END;
/

COMMENT ON COLUMN user_notification.deleted_at IS 'Soft delete. NULL = visible. Conserva dedupe_key para que el feriado no reaparezca.';

BEGIN
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'inbox/:id/dismiss');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'inbox/:id/dismiss',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_inbox_api.pr_dismiss(
        pi_auth_header     => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_notification_id => TO_NUMBER(:id),
        po_status_code     => v_status_code,
        po_response_body   => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'inbox/dismiss-all');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'inbox/dismiss-all',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_inbox_api.pr_dismiss_all(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
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

PROMPT === Inbox dismiss: columna + ORDS ===
