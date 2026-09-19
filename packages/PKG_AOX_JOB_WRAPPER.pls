PROMPT CREATE OR REPLACE PACKAGE pkg_aox_job_wrapper
CREATE OR REPLACE PACKAGE pkg_aox_job_wrapper AS
/**
 * Unico invocador de pkg_aox_session.begin_job (ACCESSIBLE BY).
 * Cada procedimiento: begin_job (exige BG_JOB_ID) -> trabajo -> end_job.
 * Fuera del scheduler begin_job rechaza; no hay 1=1 desde ORDS.
 */
    PROCEDURE pr_dispatch_push_campaigns;
    PROCEDURE pr_expire_pending_payments;
    PROCEDURE pr_process_holiday_reminders;
    PROCEDURE pr_process_embedding_outbox;
    PROCEDURE pr_process_survey_requests;
    PROCEDURE pr_process_refund_disputes;
    PROCEDURE pr_expire_pagopar_payments;
    PROCEDURE pr_revoke_expired_sessions;
    PROCEDURE pr_sync_org_embeddings;
END pkg_aox_job_wrapper;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_job_wrapper
CREATE OR REPLACE PACKAGE BODY pkg_aox_job_wrapper AS

    PROCEDURE pr_dispatch_push_campaigns IS
    BEGIN
        pkg_aox_session.begin_job;
        BEGIN
            pkg_aox_push_campaign.pr_dispatch_campaign_deliveries(100);
            pkg_aox_session.end_job;
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_session.end_job;
                RAISE;
        END;
    END pr_dispatch_push_campaigns;

    PROCEDURE pr_expire_pending_payments IS
    BEGIN
        pkg_aox_session.begin_job;
        BEGIN
            pkg_aox_payments_api.pr_expire_pending_payments;
            pkg_aox_session.end_job;
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_session.end_job;
                RAISE;
        END;
    END pr_expire_pending_payments;

    PROCEDURE pr_process_holiday_reminders IS
    BEGIN
        pkg_aox_session.begin_job;
        BEGIN
            pkg_aox_inbox_api.pr_process_holiday_reminders;
            pkg_aox_session.end_job;
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_session.end_job;
                RAISE;
        END;
    END pr_process_holiday_reminders;

    PROCEDURE pr_process_embedding_outbox IS
    BEGIN
        pkg_aox_session.begin_job;
        BEGIN
            pkg_aox_vector_search.pr_process_embedding_outbox(50);
            pkg_aox_session.end_job;
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_session.end_job;
                RAISE;
        END;
    END pr_process_embedding_outbox;

    PROCEDURE pr_process_survey_requests IS
    BEGIN
        pkg_aox_session.begin_job;
        BEGIN
            pkg_aox_meta_api.pr_process_survey_requests;
            pkg_aox_session.end_job;
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_session.end_job;
                RAISE;
        END;
    END pr_process_survey_requests;

    PROCEDURE pr_process_refund_disputes IS
    BEGIN
        pkg_aox_session.begin_job;
        BEGIN
            pkg_aox_refund_disputes_api.pr_process_dispute_timeouts(100);
            pkg_aox_refund_disputes_api.pr_process_notify_outbox(50);
            pkg_aox_session.end_job;
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_session.end_job;
                RAISE;
        END;
    END pr_process_refund_disputes;

    PROCEDURE pr_expire_pagopar_payments IS
    BEGIN
        -- Compat: el job legado duplica HASEL_EXPIRE_PENDING_PAYMENTS.
        pkg_aox_session.begin_job;
        BEGIN
            pkg_aox_pagopar_api.pr_expire_pending_payments;
            pkg_aox_session.end_job;
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_session.end_job;
                RAISE;
        END;
    END pr_expire_pagopar_payments;

    PROCEDURE pr_revoke_expired_sessions IS
    BEGIN
        -- APP_USER_SESSION es taxonomia C (sin VPD). begin_job sigue gated.
        pkg_aox_session.begin_job;
        BEGIN
            pkg_aox_auth_api.pr_revoke_expired_sessions;
            pkg_aox_session.end_job;
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_session.end_job;
                RAISE;
        END;
    END pr_revoke_expired_sessions;

    PROCEDURE pr_sync_org_embeddings IS
    BEGIN
        pkg_aox_session.begin_job;
        BEGIN
            pkg_aox_vector_search.pr_sync_all_orgs_embeddings;
            pkg_aox_session.end_job;
        EXCEPTION
            WHEN OTHERS THEN
                pkg_aox_session.end_job;
                RAISE;
        END;
    END pr_sync_org_embeddings;

END pkg_aox_job_wrapper;
/
