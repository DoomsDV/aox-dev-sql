PROMPT CREATE OR REPLACE PACKAGE pkg_aox_session
CREATE OR REPLACE PACKAGE pkg_aox_session AS
/**
 * Unico escritor de AOX_TENANT_CTX (CREATE CONTEXT ... USING pkg_aox_session).
 * Fail-closed: sin ORG_ID la policy VPD aplica 1=2.
 * No expone begin_ops ni 1=1 invocable desde ORDS tenant.
 */
    PROCEDURE clear;

    /**
     * Modo TENANT. Si pi_user_id viene informado, revalida membresia activa
     * en ORG_MEMBER (tabla sin VPD; no hay recursion).
     */
    PROCEDURE set_org(
        pi_org_id  IN NUMBER,
        pi_user_id IN NUMBER DEFAULT NULL
    );

    /**
     * No es 1=1 global. ACCESS_MODE=BOOTSTRAP sin ORG_ID: las tablas tenant
     * siguen fail-closed. Identidad/credenciales viven fuera de VPD.
     */
    PROCEDURE begin_bootstrap;
    PROCEDURE end_bootstrap;

    /**
     * Solo si USERENV.BG_JOB_ID no es nulo (proceso de scheduler).
     * 1=1 de job queda acotado a esa sesion; llamar end_job en EXCEPTION.
     * ACCESSIBLE BY el wrapper de scheduler: no invocable desde ORDS.
     */
    PROCEDURE begin_job
        ACCESSIBLE BY (PACKAGE pkg_aox_job_wrapper);
    PROCEDURE end_job
        ACCESSIBLE BY (PACKAGE pkg_aox_job_wrapper);

    /**
     * Choke JWT: clear -> decode -> validar member -> set_org.
     * Si falla, deja el contexto limpio (1=2) y relanza.
     */
    PROCEDURE pr_bind_tenant_from_jwt(
        pi_auth_header IN VARCHAR2
    );

    PROCEDURE pr_bind_tenant_from_jwt(
        pi_auth_header IN  VARCHAR2,
        po_org_id      OUT NUMBER
    );

    PROCEDURE pr_bind_tenant_from_jwt(
        pi_auth_header IN  VARCHAR2,
        po_org_id      OUT NUMBER,
        po_user_id     OUT NUMBER,
        po_role_id     OUT NUMBER
    );

    /**
     * Publico: lookup slug en ORG_PUBLIC_DIRECTORY (sin VPD) -> set_org.
     * Nunca set_org desde org_id crudo de JSON.
     */
    PROCEDURE pr_bind_tenant_from_public_slug(
        pi_org_slug IN VARCHAR2
    );

    PROCEDURE pr_bind_tenant_from_public_slug(
        pi_org_slug IN  VARCHAR2,
        po_org_id   OUT NUMBER
    );

    /**
     * Publico: token_hash -> org_id en ORG_PUBLIC_TOKEN (sin VPD) -> set_org.
     */
    PROCEDURE pr_bind_tenant_from_public_token(
        pi_token IN VARCHAR2
    );

    PROCEDURE pr_bind_tenant_from_public_token(
        pi_token          IN  VARCHAR2,
        po_org_id         OUT NUMBER,
        po_appointment_id OUT NUMBER
    );

    /**
     * Publico/webhook: token de cita (sin VPD) o fallback a APPOINTMENT.
     * El fallback solo ve filas si ya hay contexto o VPD esta off.
     */
    PROCEDURE pr_bind_tenant_from_appointment_id(
        pi_appointment_id IN NUMBER
    );

    /**
     * Entra a modo JOB solo si USERENV.BG_JOB_ID no es nulo (no-op fuera
     * del scheduler). end_job/clear en pr_leave_scheduler_job.
     */
    PROCEDURE pr_enter_scheduler_job;
    PROCEDURE pr_leave_scheduler_job;

    FUNCTION fn_current_org_id RETURN NUMBER;
    FUNCTION fn_current_user_id RETURN NUMBER;
    FUNCTION fn_access_mode RETURN VARCHAR2;
END pkg_aox_session;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_session
CREATE OR REPLACE PACKAGE BODY pkg_aox_session AS

    c_ctx            CONSTANT VARCHAR2(30) := 'AOX_TENANT_CTX';
    c_attr_org       CONSTANT VARCHAR2(30) := 'ORG_ID';
    c_attr_user      CONSTANT VARCHAR2(30) := 'USER_ID';
    c_attr_mode      CONSTANT VARCHAR2(30) := 'ACCESS_MODE';
    c_mode_tenant    CONSTANT VARCHAR2(30) := 'TENANT';
    c_mode_bootstrap CONSTANT VARCHAR2(30) := 'BOOTSTRAP';
    c_mode_job       CONSTANT VARCHAR2(30) := 'JOB';

    PROCEDURE pr_clear_safe IS
    BEGIN
        clear;
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END pr_clear_safe;

    PROCEDURE clear IS
    BEGIN
        DBMS_SESSION.CLEAR_ALL_CONTEXT(c_ctx);
    END clear;

    PROCEDURE set_org(
        pi_org_id  IN NUMBER,
        pi_user_id IN NUMBER DEFAULT NULL
    ) IS
        v_ok NUMBER;
    BEGIN
        IF pi_org_id IS NULL OR pi_org_id <= 0 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_session,
                'Identificador de organizacion invalido.'
            );
        END IF;

        IF pi_user_id IS NOT NULL THEN
            SELECT COUNT(*)
              INTO v_ok
              FROM org_member m
              JOIN platform_user pu
                ON pu.id_platform_user = m.platform_user_id
             WHERE m.org_id_organization = pi_org_id
               AND m.id_org_member       = pi_user_id
               AND m.is_active           = 1
               AND pu.is_active          = 1;

            IF v_ok = 0 THEN
                RAISE_APPLICATION_ERROR(
                    pkg_aox_util.c_sqlcode_session,
                    'Tu acceso a esta organizacion ya no esta disponible.'
                );
            END IF;
        END IF;

        clear;
        DBMS_SESSION.SET_CONTEXT(c_ctx, c_attr_org,  TO_CHAR(pi_org_id));
        DBMS_SESSION.SET_CONTEXT(c_ctx, c_attr_mode, c_mode_tenant);
        IF pi_user_id IS NOT NULL THEN
            DBMS_SESSION.SET_CONTEXT(c_ctx, c_attr_user, TO_CHAR(pi_user_id));
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            pr_clear_safe;
            RAISE;
    END set_org;

    PROCEDURE begin_bootstrap IS
    BEGIN
        clear;
        DBMS_SESSION.SET_CONTEXT(c_ctx, c_attr_mode, c_mode_bootstrap);
    END begin_bootstrap;

    PROCEDURE end_bootstrap IS
    BEGIN
        pr_clear_safe;
    END end_bootstrap;

    PROCEDURE begin_job
        ACCESSIBLE BY (PACKAGE pkg_aox_job_wrapper)
    IS
    BEGIN
        IF SYS_CONTEXT('USERENV', 'BG_JOB_ID') IS NULL THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'begin_job solo se permite en un job del scheduler.'
            );
        END IF;
        clear;
        DBMS_SESSION.SET_CONTEXT(c_ctx, c_attr_mode, c_mode_job);
    EXCEPTION
        WHEN OTHERS THEN
            pr_clear_safe;
            RAISE;
    END begin_job;

    PROCEDURE end_job
        ACCESSIBLE BY (PACKAGE pkg_aox_job_wrapper)
    IS
    BEGIN
        pr_clear_safe;
    END end_job;

    FUNCTION fn_json_number(
        pi_obj IN json_object_t,
        pi_key IN VARCHAR2
    ) RETURN NUMBER IS
    BEGIN
        IF pi_obj IS NULL OR NOT pi_obj.has(pi_key) THEN
            RETURN NULL;
        END IF;
        RETURN pi_obj.get_number(pi_key);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END fn_json_number;

    PROCEDURE pr_bind_tenant_from_jwt(
        pi_auth_header IN  VARCHAR2,
        po_org_id      OUT NUMBER,
        po_user_id     OUT NUMBER,
        po_role_id     OUT NUMBER
    ) IS
        v_payload json_object_t;
    BEGIN
        clear;
        v_payload := pkg_aox_util.fn_decode_validated_jwt_payload(pi_auth_header);
        po_org_id  := fn_json_number(v_payload, 'organization_id');
        po_user_id := fn_json_number(v_payload, 'user_id');
        po_role_id := fn_json_number(v_payload, 'role_id');

        IF po_org_id IS NULL THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_session,
                'Falta identificador de organizacion en el token.'
            );
        END IF;

        set_org(po_org_id, po_user_id);
    EXCEPTION
        WHEN OTHERS THEN
            pr_clear_safe;
            RAISE;
    END pr_bind_tenant_from_jwt;

    PROCEDURE pr_bind_tenant_from_jwt(
        pi_auth_header IN VARCHAR2
    ) IS
        v_org_id  NUMBER;
        v_user_id NUMBER;
        v_role_id NUMBER;
    BEGIN
        pr_bind_tenant_from_jwt(
            pi_auth_header => pi_auth_header,
            po_org_id      => v_org_id,
            po_user_id     => v_user_id,
            po_role_id     => v_role_id
        );
    END pr_bind_tenant_from_jwt;

    PROCEDURE pr_bind_tenant_from_jwt(
        pi_auth_header IN  VARCHAR2,
        po_org_id      OUT NUMBER
    ) IS
        v_user_id NUMBER;
        v_role_id NUMBER;
    BEGIN
        pr_bind_tenant_from_jwt(
            pi_auth_header => pi_auth_header,
            po_org_id      => po_org_id,
            po_user_id     => v_user_id,
            po_role_id     => v_role_id
        );
    END pr_bind_tenant_from_jwt;

    PROCEDURE pr_bind_tenant_from_public_slug(
        pi_org_slug IN  VARCHAR2,
        po_org_id   OUT NUMBER
    ) IS
    BEGIN
        clear;
        IF TRIM(pi_org_slug) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20003, 'organization_slug es obligatorio.');
        END IF;

        po_org_id := pkg_aox_public_directory.fn_org_id_by_slug(pi_org_slug);
        IF po_org_id IS NULL THEN
            RAISE_APPLICATION_ERROR(-20025, 'Negocio no encontrado.');
        END IF;

        set_org(po_org_id);
    EXCEPTION
        WHEN OTHERS THEN
            pr_clear_safe;
            RAISE;
    END pr_bind_tenant_from_public_slug;

    PROCEDURE pr_bind_tenant_from_public_slug(
        pi_org_slug IN VARCHAR2
    ) IS
        v_org_id NUMBER;
    BEGIN
        pr_bind_tenant_from_public_slug(
            pi_org_slug => pi_org_slug,
            po_org_id   => v_org_id
        );
    END pr_bind_tenant_from_public_slug;

    PROCEDURE pr_bind_tenant_from_public_token(
        pi_token          IN  VARCHAR2,
        po_org_id         OUT NUMBER,
        po_appointment_id OUT NUMBER
    ) IS
    BEGIN
        clear;
        IF TRIM(pi_token) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20003, 'Token publico obligatorio.');
        END IF;

        pkg_aox_public_directory.pr_resolve_token(
            pi_token          => pi_token,
            po_org_id         => po_org_id,
            po_appointment_id => po_appointment_id
        );

        IF po_org_id IS NULL THEN
            RAISE_APPLICATION_ERROR(-20025, 'Reserva no encontrada.');
        END IF;

        set_org(po_org_id);
    EXCEPTION
        WHEN OTHERS THEN
            pr_clear_safe;
            RAISE;
    END pr_bind_tenant_from_public_token;

    PROCEDURE pr_bind_tenant_from_public_token(
        pi_token IN VARCHAR2
    ) IS
        v_org_id NUMBER;
        v_app_id NUMBER;
    BEGIN
        pr_bind_tenant_from_public_token(
            pi_token          => pi_token,
            po_org_id         => v_org_id,
            po_appointment_id => v_app_id
        );
    END pr_bind_tenant_from_public_token;

    PROCEDURE pr_bind_tenant_from_appointment_id(
        pi_appointment_id IN NUMBER
    ) IS
        v_org_id NUMBER;
    BEGIN
        IF NVL(pi_appointment_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(-20003, 'Cita invalida.');
        END IF;

        BEGIN
            SELECT t.org_id_organization
              INTO v_org_id
              FROM org_public_token t
             WHERE t.app_id_appointment = pi_appointment_id
               AND t.token_kind = pkg_aox_public_directory.c_kind_appointment_manage
               AND ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                SELECT a.org_id_organization
                  INTO v_org_id
                  FROM appointment a
                 WHERE a.id_appointment = pi_appointment_id;
        END;

        set_org(v_org_id);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            pr_clear_safe;
            RAISE_APPLICATION_ERROR(-20025, 'Reserva no encontrada.');
        WHEN OTHERS THEN
            pr_clear_safe;
            RAISE;
    END pr_bind_tenant_from_appointment_id;

    PROCEDURE pr_enter_scheduler_job IS
    BEGIN
        IF SYS_CONTEXT('USERENV', 'BG_JOB_ID') IS NOT NULL THEN
            begin_job;
        END IF;
    END pr_enter_scheduler_job;

    PROCEDURE pr_leave_scheduler_job IS
    BEGIN
        end_job;
    END pr_leave_scheduler_job;

    FUNCTION fn_current_org_id RETURN NUMBER IS
    BEGIN
        RETURN TO_NUMBER(
            SYS_CONTEXT(c_ctx, c_attr_org)
            DEFAULT NULL ON CONVERSION ERROR
        );
    END fn_current_org_id;

    FUNCTION fn_current_user_id RETURN NUMBER IS
    BEGIN
        RETURN TO_NUMBER(
            SYS_CONTEXT(c_ctx, c_attr_user)
            DEFAULT NULL ON CONVERSION ERROR
        );
    END fn_current_user_id;

    FUNCTION fn_access_mode RETURN VARCHAR2 IS
    BEGIN
        RETURN SYS_CONTEXT(c_ctx, c_attr_mode);
    END fn_access_mode;

END pkg_aox_session;
/
