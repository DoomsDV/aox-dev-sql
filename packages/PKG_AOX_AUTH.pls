PROMPT CREATE OR REPLACE PACKAGE pkg_aox_auth
CREATE OR REPLACE package pkg_aox_auth as
/**
 * Paquete de seguridad para la gestión de autenticación personalizada en Oracle APEX.
 * Contiene las funciones necesarias para validar las credenciales de los usuarios
 * contra la tabla maestra de la aplicación.
 *
 * @author Generado por Sistema
 * @version 1.0
 */

    /**
     * Valida las credenciales de un usuario comparando el hash de la contraseña proporcionada
     * con el almacenado en la base de datos.
     *
     * @param pi_username  Nombre de usuario (normalizado internamente a MAYÚSCULAS).
     * @param pi_password  Contraseña en texto plano para validar.
     * @return boolean     Retorna TRUE si las credenciales son válidas y el usuario está activo,
     * FALSE en cualquier otro caso.
     */
    function fn_custom_authenticate (
        p_username in varchar2,
        p_password in varchar2
    ) return boolean;

    /**
     * Procedimiento que se ejecuta después de una autenticación exitosa.
     * Se encarga de cargar en la sesión de APEX información adicional del usuario,
     * como su ID de organización y rol, para facilitar la gestión de permisos y personalización.
     */
    procedure pr_post_authentication;
end pkg_aox_auth;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_auth
CREATE OR REPLACE package body pkg_aox_auth as

    function fn_custom_authenticate (
        p_username in varchar2,
        p_password in varchar2
    ) return boolean is
        v_stored_hash   varchar2(255);
        v_is_active     number;
        v_password_salt       varchar2(64);
        v_password_algo       varchar2(30);
        v_password_iterations number;
    begin
        -- 1. Recuperación de credenciales y estado de cuenta
        -- Se utiliza UPPER para garantizar que el login sea insensible a mayúsculas/minúsculas.
        begin
            select
                pu.password_hash,
                pu.is_active,
                pu.password_salt,
                pu.password_algo,
                pu.password_iterations
            into
                v_stored_hash,
                v_is_active,
                v_password_salt,
                v_password_algo,
                v_password_iterations
            from platform_user pu
            where pu.apex_user_name = upper(p_username);
        exception
            when no_data_found then
                return false;
        end;

        -- 2. Verificación de estado de cuenta
        -- Solo se permite el acceso si la cuenta tiene el flag de activo (1).
        if v_is_active = 0 then
            return false;
        end if;

        -- 3. Validación de integridad de la contraseña. Soporta ambos algoritmos
        -- (SHA256_LEGACY y PBKDF2_HMAC_SHA256_V1); la migración al nuevo algoritmo
        -- ocurre en el login de la API (PKG_AOX_AUTH_API.pr_login_auth), no aquí.
        return pkg_aox_util.fn_verify_password(
            pi_password    => p_password,
            pi_stored_hash => v_stored_hash,
            pi_salt        => v_password_salt,
            pi_algo        => v_password_algo,
            pi_iterations  => v_password_iterations
        );

    exception
        when others then
            -- Fallo de seguridad por defecto: ante cualquier error inesperado, denegar acceso.
            return false;
    end fn_custom_authenticate;

    procedure pr_post_authentication is
        v_org_id    number;
        v_role_name varchar2(50);
    begin
        -- Buscamos el ID de la organización y el nombre del rol del usuario que acaba de loguearse (:APP_USER)
        select
            m.org_id_organization,
            r.name
        into
            v_org_id,
            v_role_name
        from platform_user pu
        join org_member m on m.platform_user_id = pu.id_platform_user and m.is_active = 1
        join role r on m.rol_id_role = r.id_role
        where pu.apex_user_name = upper(v('APP_USER'))
          and pu.is_active = 1
        order by m.created_at desc
        fetch first 1 row only;

        -- Guardamos esos valores en las variables de sesión de APEX
        apex_util.set_session_state('APP_ORG_ID', v_org_id);
        apex_util.set_session_state('APP_USER_ROLE', v_role_name);
    exception
        when no_data_found then
            -- Por seguridad, si algo falla, limpiamos las variables
            apex_util.set_session_state('APP_ORG_ID', NULL);
            apex_util.set_session_state('APP_USER_ROLE', NULL);
    end pr_post_authentication;
end pkg_aox_auth;
/

