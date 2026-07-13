PROMPT CREATE OR REPLACE PACKAGE pkg_aox_jwt
CREATE OR REPLACE package pkg_aox_jwt as

    procedure pr_generate_auth_tokens(
        pi_user_id       in  number,
        pi_org_id        in  number,
        pi_username      in  varchar2,
        pi_role_id       in  number,       -- ¡Cambiado a NUMBER!
        po_access_token  out clob,
        po_refresh_token out varchar2
    );

    procedure pr_refresh_token(
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_generate_org_selection_token(
        pi_platform_user_id in  number,
        pi_identifier       in  varchar2,
        po_selection_token  out clob
    );

    function fn_get_platform_user_from_selection_token(
        pi_selection_token in varchar2
    ) return number;
end pkg_aox_jwt;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_jwt
CREATE OR REPLACE package body pkg_aox_jwt as

    procedure pr_generate_auth_tokens(
        pi_user_id       in  number,
        pi_org_id        in  number,
        pi_username      in  varchar2,
        pi_role_id       in  number,       -- ¡Cambiado a NUMBER!
        po_access_token  out clob,
        po_refresh_token out varchar2
    ) is
        v_jwt_secret    raw(256);
        v_refresh_token varchar2(255);
    begin
        -- 1. Generar el Access Token (JWT) - Expira en 1 hora
        v_jwt_secret := utl_raw.cast_to_raw(fn_get_parameter('JWT_TOKEN'));

        po_access_token := apex_jwt.encode(
            p_iss           => NVL(fn_get_parameter('JWT_ISSUER'), 'hasel-api'),
            p_sub           => pi_username,
            p_aud           => NVL(fn_get_parameter('JWT_AUDIENCE'), 'hasel-app'),
            p_exp_sec       => pkg_aox_util.fn_param_number('JWT_ACCESS_EXP_SEC', 3600),
            -- ¡Corregido! Ahora genera: "user_id": 5, "role_id": 3, "organization_id": 1
            p_other_claims  => '"user_id": ' || pi_user_id || ', "role_id": ' || pi_role_id || ', "organization_id": ' || pi_org_id,
            p_signature_key => v_jwt_secret
        );

        -- 2. Generar el Refresh Token - Expira en 30 días
        v_refresh_token := lower(rawtohex(sys_guid()) || rawtohex(sys_guid()));
        po_refresh_token := v_refresh_token;

        -- 3. Guardar el Refresh Token en la base de datos
        insert into app_user_session (
          use_id_user,
          refresh_token,
          expires_at
        )
        values (
            pi_user_id,
            v_refresh_token,
            current_timestamp + NUMTODSINTERVAL(pkg_aox_util.fn_param_number('JWT_REFRESH_EXP_DAYS', 30), 'DAY')
        );

        commit;
    end pr_generate_auth_tokens;

    procedure pr_refresh_token(
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req       json_object_t;
        v_refresh_token  varchar2(255);

        -- Datos del usuario recuperados de la sesión
        v_user_id        org_member.id_org_member%TYPE;
        v_org_id         org_member.org_id_organization%TYPE;
        v_identifier     platform_user.apex_user_name%TYPE;
        v_is_active      org_member.is_active%TYPE;
        v_pu_active      platform_user.is_active%TYPE;
        v_id_rol         ROLE.id_role%type;

        -- Nuevos tokens
        v_new_access     clob;
        v_new_refresh    varchar2(255);
        v_response_json  json_object_t;
    begin
        v_response_json := json_object_t();

        -- 1. Extraer el refresh_token del JSON
        begin
            v_json_req := json_object_t.parse(pi_body);
            v_refresh_token := v_json_req.get_string('refresh_token');
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code; -- Bad Request
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'El cuerpo de la petición no es un JSON válido.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        if v_refresh_token is null or trim(v_refresh_token) = '' then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'El campo refresh_token es obligatorio.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        -- 2. Validar el token contra la base de datos
        begin
            select
                m.id_org_member,
                m.org_id_organization,
                pu.apex_user_name,
                m.is_active,
                m.rol_id_role,
                pu.is_active
            into
                v_user_id,
                v_org_id,
                v_identifier,
                v_is_active,
                v_id_rol,
                v_pu_active
            from app_user_session s
            join org_member m on m.id_org_member = s.use_id_user
            join platform_user pu on pu.id_platform_user = m.platform_user_id
            where s.refresh_token         = v_refresh_token
              and s.is_revoked            = 0                     -- que no haya sido revocado
              and s.expires_at            > current_timestamp;    -- Que no haya expirado (30 días)

        exception
            when no_data_found then
                -- Si no existe, caducó o fue revocado, obligamos a hacer login de nuevo
                po_status_code := pkg_aox_util.c_unauthorized_code;
                pkg_aox_util.pr_build_api_error_response(
                    pi_status_code   => po_status_code,
                    pi_api_code      => pkg_aox_util.c_api_code_session_expired,
                    pi_message       => 'Refresh token inválido o expirado. Por favor, vuelva a iniciar sesión.',
                    po_response_body => po_response_body
                );
                return;
        end;

        -- 3. Verificar que la cuenta del usuario no haya sido desactivada
        if v_is_active = 0 or v_pu_active = 0 then
            po_status_code := pkg_aox_util.c_unauthorized_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_session_expired,
                pi_message       => 'La cuenta de usuario está inactiva.',
                po_response_body => po_response_body
            );
            return;
        end if;

        -- 4. Revocar el token usado (Rotación de tokens por seguridad)
        update app_user_session
        set is_revoked      = 1
        where refresh_token = v_refresh_token;

        -- 5. Generar un nuevo par de tokens usando el proceso que ya creamos
        pkg_aox_jwt.pr_generate_auth_tokens(
            pi_user_id       => v_user_id,
            pi_org_id        => v_org_id,
            pi_username      => v_identifier,
            pi_role_id       => v_id_rol,
            po_access_token  => v_new_access,
            po_refresh_token => v_new_refresh
        );

        -- 6. Devolver el éxito
        po_status_code := pkg_aox_util.c_success_ok_code; -- OK
        v_response_json.put('status'        , 'success');
        v_response_json.put('access_token'  , v_new_access);
        v_response_json.put('refresh_token' , v_new_refresh);
        v_response_json.put('expires_in'    , pkg_aox_util.fn_param_number('JWT_ACCESS_EXP_SEC', 3600));
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_refresh_token;

    procedure pr_generate_org_selection_token(
        pi_platform_user_id in  number,
        pi_identifier       in  varchar2,
        po_selection_token  out clob
    ) is
        v_jwt_secret raw(256);
        v_exp_sec    number := pkg_aox_util.fn_param_number('JWT_ORG_SELECTION_EXP_SEC', 600);
    begin
        if pi_platform_user_id is null or pi_platform_user_id <= 0 then
            raise_application_error(-20040, 'Identidad de usuario inválida para selección de organización.');
        end if;

        v_jwt_secret := utl_raw.cast_to_raw(fn_get_parameter('JWT_TOKEN'));

        po_selection_token := apex_jwt.encode(
            p_iss           => nvl(fn_get_parameter('JWT_ISSUER'), 'hasel-api'),
            p_sub           => nvl(trim(pi_identifier), 'org-selection'),
            p_aud           => nvl(fn_get_parameter('JWT_AUDIENCE'), 'hasel-app'),
            p_exp_sec       => v_exp_sec,
            p_other_claims  => '"org_selection": 1, "platform_user_id": ' || pi_platform_user_id,
            p_signature_key => v_jwt_secret
        );
    end pr_generate_org_selection_token;

    function fn_get_platform_user_from_selection_token(
        pi_selection_token in varchar2
    ) return number is
        v_jwt_secret       raw(256);
        v_decoded_token    apex_jwt.t_token;
        v_payload_json     json_object_t;
        v_platform_user_id number;
        v_org_selection    number;
    begin
        if pi_selection_token is null or trim(pi_selection_token) = '' then
            return null;
        end if;

        v_jwt_secret := utl_raw.cast_to_raw(fn_get_parameter('JWT_TOKEN'));

        v_decoded_token := apex_jwt.decode(
            p_value         => pi_selection_token,
            p_signature_key => v_jwt_secret
        );

        v_payload_json := json_object_t.parse(v_decoded_token.payload);

        v_org_selection := v_payload_json.get_number('org_selection');
        if nvl(v_org_selection, 0) <> 1 then
            return null;
        end if;

        v_platform_user_id := v_payload_json.get_number('platform_user_id');
        if v_platform_user_id is null or v_platform_user_id <= 0 then
            return null;
        end if;

        return v_platform_user_id;
    exception
        when others then
            return null;
    end fn_get_platform_user_from_selection_token;
end pkg_aox_jwt;
/

