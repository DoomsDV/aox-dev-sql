PROMPT CREATE OR REPLACE PACKAGE pkg_aox_ai_context
CREATE OR REPLACE PACKAGE pkg_aox_ai_context IS
    PROCEDURE pr_set_context(
        pi_org_id     IN NUMBER,
        pi_user_id    IN NUMBER,
        pi_role_id    IN NUMBER,
        pi_pro_id     IN NUMBER,
        pi_session_id IN NUMBER
    );

    PROCEDURE pr_clear_context;
END pkg_aox_ai_context;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_ai_context
CREATE OR REPLACE PACKAGE BODY pkg_aox_ai_context IS
    PROCEDURE pr_set_context(
        pi_org_id     IN NUMBER,
        pi_user_id    IN NUMBER,
        pi_role_id    IN NUMBER,
        pi_pro_id     IN NUMBER,
        pi_session_id IN NUMBER
    ) IS
    BEGIN
        DBMS_SESSION.SET_CONTEXT('AOX_AI_CTX', 'ORG_ID', TO_CHAR(pi_org_id));
        DBMS_SESSION.SET_CONTEXT('AOX_AI_CTX', 'USER_ID', TO_CHAR(pi_user_id));
        DBMS_SESSION.SET_CONTEXT('AOX_AI_CTX', 'ROLE_ID', TO_CHAR(pi_role_id));
        DBMS_SESSION.SET_CONTEXT('AOX_AI_CTX', 'PRO_ID', TO_CHAR(NVL(pi_pro_id, -1)));
        DBMS_SESSION.SET_CONTEXT('AOX_AI_CTX', 'SESSION_ID', TO_CHAR(pi_session_id));
    END pr_set_context;

    PROCEDURE pr_clear_context IS
    BEGIN
        DBMS_SESSION.CLEAR_CONTEXT('AOX_AI_CTX', NULL, 'ORG_ID');
        DBMS_SESSION.CLEAR_CONTEXT('AOX_AI_CTX', NULL, 'USER_ID');
        DBMS_SESSION.CLEAR_CONTEXT('AOX_AI_CTX', NULL, 'ROLE_ID');
        DBMS_SESSION.CLEAR_CONTEXT('AOX_AI_CTX', NULL, 'PRO_ID');
        DBMS_SESSION.CLEAR_CONTEXT('AOX_AI_CTX', NULL, 'SESSION_ID');
    END pr_clear_context;
END pkg_aox_ai_context;
/

