PROMPT CREATE OR REPLACE PACKAGE pkg_aox_permission_api (specificacion adelantada)
CREATE OR REPLACE PACKAGE pkg_aox_permission_api IS

    -- Especificación adelantada para romper la dependencia circular con
    -- PKG_AOX_SUBSCRIPTION_API. El cuerpo completo se compila después de
    -- que exista la especificación de suscripciones.
    FUNCTION fn_has_capability(
        pi_org_id  IN NUMBER,
        pi_role_id IN NUMBER,
        pi_code    IN VARCHAR2
    ) RETURN NUMBER;

    PROCEDURE pr_assert_capability(
        pi_org_id  IN NUMBER,
        pi_role_id IN NUMBER,
        pi_code    IN VARCHAR2,
        pi_message IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE pr_get_my_capabilities(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_get_matrix(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_put_matrix(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_reset_matrix(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_permission_api;
/
