PROMPT CREATE OR REPLACE PACKAGE pkg_aox_auth_api
CREATE OR REPLACE package pkg_aox_auth_api as
/**
 * Paquete encargado de la lógica de autenticación y registro de usuarios vía API.
 * Proporciona la interfaz necesaria para el aprovisionamiento de tenants (Organizaciones)
 * y usuarios iniciales desde plataformas externas (Landing Pages).
 *
 * @author Daniel Villasanti
 * @version 1.0
 */

    /**
     * Realiza el registro completo de una nueva organización, su usuario administrador
     * y, opcionalmente, el perfil profesional.
     *
     * @param pi_business_name  Nombre comercial de la organización.
     * @param pi_phone          Número de contacto de la organización.
     * @param pi_email          Correo electrónico del usuario (será usado como username).
     * @param pi_password       Contraseña en texto plano (será hasheada internamente).
     * @param pi_first_name     Nombre del usuario administrador.
     * @param pi_last_name      Apellido del usuario administrador.
     * @param pi_account_type   Tipo de cuenta: 'INDEPENDIENTE' o 'EMPRESA'.
     * @param po_status_code    Código de estado HTTP resultante.
     * @param po_response_body  Cuerpo de la respuesta en formato JSON (CLOB).
     */
    procedure pr_api_authenticate (
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    /**
     * Procedimiento estandarizado para la estructuración de respuestas de error en formato JSON.
     *
     * @param pi_error_msg      Mensaje descriptivo del error.
     * @param pi_status_code    Código de error asociado (ej. 400, 500).
     * @param po_response_body  Objeto JSON de salida con la estructura de error.
     */
    procedure pr_error_handling (
        pi_error_msg        in varchar2,
        pi_status_code      in number,
        po_response_body    out clob
    );

     function fn_validate_login_inputs(
        pi_identifier in varchar2, -- cambiado a identifier
        pi_password   in varchar2
    ) return json_array_t;

    procedure pr_login_auth(
        pi_body          in clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_select_organization(
        pi_body          in clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_list_my_organizations(
        pi_auth_header   in varchar2,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_switch_organization(
        pi_auth_header   in varchar2,
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_logout(
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_verify_email(
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_resend_verification_code(
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_forgot_password(
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_reset_password(
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_get_invitation(
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_accept_invitation(
        pi_auth_header   in  varchar2 default null,
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    /** Valida que la membresía del JWT siga activa para usar el panel. */
    procedure pr_validate_panel_session(
        pi_auth_header   in  varchar2,
        po_status_code   out number,
        po_response_body out clob
    );

    /**
     * Crea una organizacion nueva para un platform_user ya existente (autenticado).
     * Asigna rol ADMIN, perfil profesional y emite JWT de la nueva membresia.
     */
    procedure pr_create_organization(
        pi_auth_header   in  varchar2,
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_send_invitation_email(
        pi_email         in  varchar2,
        pi_org_name      in  varchar2,
        pi_invite_url    in  varchar2,
        pi_expires_at    in  varchar2,
        po_sent          out number
    );

    function fn_verification_code_hash(
        pi_user_id in number,
        pi_email   in varchar2,
        pi_code    in varchar2
    ) return VARCHAR2;
end pkg_aox_auth_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_auth_api
CREATE OR REPLACE package body pkg_aox_auth_api as
    -- CONSTANTES PRIVADAS PARA CÓDIGOS DE RESPUESTA
    c_verification_template       constant varchar2(50) := 'VERIFICATIONCODE';
    c_verification_ttl_minutes    constant number       := 5;
    c_verification_max_attempts   constant number       := 5;
    c_resend_wait_seconds         constant number       := 60;
    c_invitation_ttl_days         constant number       := 7;
    c_invitation_template         constant varchar2(50) := 'ACCEPTINVITE';

    function fn_json_escape(pi_value in varchar2) return varchar2 is
    begin
        return replace(replace(nvl(pi_value, ''), chr(92), chr(92) || chr(92)), '"', chr(92) || '"');
    end fn_json_escape;

    function fn_generate_verification_code return varchar2 is
        v_random_hex varchar2(8);
        v_random_num number;
    begin
        v_random_hex := rawtohex(dbms_crypto.randombytes(4));
        v_random_num := to_number(v_random_hex, 'XXXXXXXX');

        return lpad(to_char(mod(v_random_num, 1000000)), 6, '0');
    exception
        when others then
            return lpad(to_char(trunc(dbms_random.value(0, 1000000))), 6, '0');
    end fn_generate_verification_code;

    function fn_verification_code_hash(
        pi_user_id in number,
        pi_email   in varchar2,
        pi_code    in varchar2
    ) return varchar2 is
    begin
        return pkg_aox_util.fn_hash_password(
            to_char(pi_user_id) || ':' || upper(trim(pi_email)) || ':' || trim(pi_code)
        );
    end fn_verification_code_hash;

    procedure pr_create_verification_code(
        pi_user_id in number,
        pi_email   in varchar2,
        po_code    out varchar2
    ) is
    begin
        po_code := fn_generate_verification_code;

        update app_user_email_verification
        set consumed_at = current_timestamp
        where usr_id_user = pi_user_id
          and consumed_at is null;

        insert into app_user_email_verification (
            usr_id_user,
            code_hash,
            expires_at,
            max_attempts
        ) values (
            pi_user_id,
            fn_verification_code_hash(pi_user_id, pi_email, po_code),
            current_timestamp + numtodsinterval(c_verification_ttl_minutes, 'MINUTE'),
            c_verification_max_attempts
        );
    end pr_create_verification_code;

    procedure pr_send_verification_email(
        pi_email      in varchar2,
        pi_first_name in varchar2,
        pi_code       in varchar2,
        po_sent       out number
    ) is
        v_apex_session_created boolean := false;
    begin
        po_sent := 0;

        apex_session.create_session(
            p_app_id   => 100,
            p_page_id  => 1,
            p_username => 'AOX'
        );
        v_apex_session_created := true;

        apex_mail.send(
            p_to                 => trim(pi_email),
            p_from               => NVL(fn_get_parameter('MAIL_FROM_ADDRESS'), 'noreply@hasel.app'),
            p_template_static_id => c_verification_template,
            p_placeholders       => '{' ||
                                    '"NOMBRE": "' || fn_json_escape(pi_first_name) || '",' ||
                                    '"CODIGO": "' || fn_json_escape(pi_code) || '"' ||
                                    '}'
        );

        apex_mail.push_queue;
        commit;
        po_sent := 1;

        if v_apex_session_created then
            begin
                apex_session.delete_session;
            exception
                when others then
                    null;
            end;
        end if;
    exception
        when others then
            if v_apex_session_created then
                begin
                    apex_session.delete_session;
                exception
                    when others then
                        null;
                end;
            end if;
            po_sent := 0;
    end pr_send_verification_email;

    function fn_validate_register_inputs(
        pi_business_name in varchar2,
        pi_phone         in varchar2,
        pi_email         in varchar2,
        pi_password      in varchar2,
        pi_first_name    in varchar2,
        pi_last_name     in VARCHAR2,
        pi_company_email    in varchar2 default null,
        pi_id_org_specialty in number   default null
    ) return json_array_t is
        v_errors             json_array_t := json_array_t();
        v_error              json_object_t;

        -- Variables para longitudes dinámicas
        v_org_name_max       number;
        v_user_name_max      number;
        v_email_max          number;
        v_phone_max          number := 20; -- WhatsApp general
        v_comp_email_max     number;
    begin
        -- Extraer longitudes dinámicas del diccionario de datos de Oracle
        begin
            select
                data_length
            into v_org_name_max
            from user_tab_columns
            where table_name    = 'ORGANIZATION'
                and column_name = 'NAME';
        exception
            when no_data_found then
                v_org_name_max := 100;
        end;

        begin
            select
                data_length
            into
                v_user_name_max
            from user_tab_columns
            where table_name    = 'APP_USER'
                and column_name = 'FIRST_NAME';
        exception
            when no_data_found then
                v_user_name_max := 100;
        end;

        begin
            select
                data_length
            into
                v_email_max
            from user_tab_columns
            where table_name    = 'APP_USER'
                and column_name = 'EMAIL';
        exception
            when no_data_found then
                v_email_max := 100;
        end;

        begin
            select
                data_length
            into
                v_comp_email_max
            from user_tab_columns
            where table_name    = 'ORGANIZATION'
                and column_name = 'COMPANY_EMAIL';
        exception
            when no_data_found then
                v_comp_email_max := 150;
        end;

        -- Validación: Nombre de la empresa
        if pi_business_name is null or trim(pi_business_name) = '' then
            v_error := json_object_t();
            v_error.put('field', 'business_name');
            v_error.put('message', 'El nombre de la empresa es obligatorio.');
            v_errors.append(v_error);
        elsif length(pi_business_name) > v_org_name_max then
            v_error := json_object_t();
            v_error.put('field', 'business_name');
            v_error.put('message', 'Excede ' || v_org_name_max || ' caracteres.');
            v_errors.append(v_error);
        end if;

        -- Validación: Correo corporativo
        if pi_company_email is not null and trim(pi_company_email) != '' then
            if length(pi_company_email) > v_comp_email_max then
                v_error := json_object_t(); v_error.put('field', 'company_email'); v_error.put('message', 'Excede ' || v_comp_email_max || ' caracteres.'); v_errors.append(v_error);
            elsif instr(pi_company_email, '@') = 0 then
                v_error := json_object_t(); v_error.put('field', 'company_email'); v_error.put('message', 'El formato del correo corporativo no es válido.'); v_errors.append(v_error);
            end if;
        end if;

        -- Validación: ID Especialidad de Organización
        if pi_id_org_specialty is not null and pi_id_org_specialty <= 0 then
            v_error := json_object_t();
            v_error.put('field'   , 'id_org_specialty');
            v_error.put('message' , 'El ID de la especialidad no es válido.');
            v_errors.append(v_error);
        end if;

        -- Validación: Correo electrónico
        if pi_email is null or trim(pi_email) = '' then
            v_error := json_object_t();
            v_error.put('field', 'email');
            v_error.put('message', 'El correo electrónico es obligatorio.');
            v_errors.append(v_error);
        elsif length(pi_email) > v_email_max then
            v_error := json_object_t();
            v_error.put('field', 'email');
            v_error.put('message', 'Excede ' || v_email_max || ' caracteres.');
            v_errors.append(v_error);
        elsif instr(pi_email, '@') = 0 then
            v_error := json_object_t();
            v_error.put('field', 'email');
            v_error.put('message', 'El formato del correo electrónico no es válido.');
            v_errors.append(v_error);
        end if;

        -- Validación: Contraseña
        if pi_password is null or length(trim(pi_password)) < 8 then
            v_error := json_object_t();
            v_error.put('field', 'password');
            v_error.put('message', 'La contraseña debe tener al menos 8 caracteres.');
            v_errors.append(v_error);
        elsif not regexp_like(pi_password, '[A-Z]') then
            v_error := json_object_t();
            v_error.put('field', 'password');
            v_error.put('message', 'La contraseña debe contener al menos una letra mayúscula.');
            v_errors.append(v_error);
        elsif not regexp_like(pi_password, '[0-9]') then
            v_error := json_object_t();
            v_error.put('field', 'password');
            v_error.put('message', 'La contraseña debe contener al menos un número.');
            v_errors.append(v_error);
        end if;

        -- Validación: Nombre
        if pi_first_name is null or trim(pi_first_name) = '' then
            v_error := json_object_t();
            v_error.put('field', 'first_name');
            v_error.put('message', 'El nombre es obligatorio.');
            v_errors.append(v_error);
        elsif length(pi_first_name) > v_user_name_max then
            v_error := json_object_t();
            v_error.put('field', 'first_name');
            v_error.put('message', 'Excede ' || v_user_name_max || ' caracteres.');
            v_errors.append(v_error);
        end if;

        -- Validación: Apellido
        if pi_last_name is null or trim(pi_last_name) = '' then
            v_error := json_object_t();
            v_error.put('field', 'last_name');
            v_error.put('message', 'El apellido es obligatorio.');
            v_errors.append(v_error);
        elsif length(pi_last_name) > v_user_name_max then
            v_error := json_object_t();
            v_error.put('field', 'last_name');
            v_error.put('message', 'Excede ' || v_user_name_max || ' caracteres.');
            v_errors.append(v_error);
        end if;

        -- Validación: Teléfono requerido por el perfil profesional inicial
        if pi_phone is null or trim(pi_phone) = '' then
            v_error := json_object_t();
            v_error.put('field', 'phone');
            v_error.put('message', 'El teléfono corporativo es obligatorio.');
            v_errors.append(v_error);
        elsif length(pi_phone) > v_phone_max then
            v_error := json_object_t();
            v_error.put('field', 'phone');
            v_error.put('message', 'Excede ' || v_phone_max || ' caracteres.');
            v_errors.append(v_error);
        end if;

        return v_errors;
    end fn_validate_register_inputs;

    function fn_validate_organization_inputs(
        pi_business_name    in varchar2,
        pi_phone            in varchar2,
        pi_company_email    in varchar2,
        pi_id_org_specialty in number
    ) return json_array_t is
        v_errors         json_array_t := json_array_t();
        v_error          json_object_t;
        v_org_name_max   number;
        v_comp_email_max number;
        v_phone_max      number := 20;
    begin
        begin
            select data_length
              into v_org_name_max
              from user_tab_columns
             where table_name = 'ORGANIZATION'
               and column_name = 'NAME';
        exception
            when no_data_found then
                v_org_name_max := 100;
        end;

        begin
            select data_length
              into v_comp_email_max
              from user_tab_columns
             where table_name = 'ORGANIZATION'
               and column_name = 'COMPANY_EMAIL';
        exception
            when no_data_found then
                v_comp_email_max := 150;
        end;

        if pi_business_name is null or trim(pi_business_name) = '' then
            v_error := json_object_t();
            v_error.put('field', 'business_name');
            v_error.put('message', 'El nombre de la empresa es obligatorio.');
            v_errors.append(v_error);
        elsif length(pi_business_name) > v_org_name_max then
            v_error := json_object_t();
            v_error.put('field', 'business_name');
            v_error.put('message', 'Excede ' || v_org_name_max || ' caracteres.');
            v_errors.append(v_error);
        end if;

        if pi_company_email is null or trim(pi_company_email) = '' then
            v_error := json_object_t();
            v_error.put('field', 'company_email');
            v_error.put('message', 'El correo de la compania es obligatorio.');
            v_errors.append(v_error);
        elsif length(pi_company_email) > v_comp_email_max then
            v_error := json_object_t();
            v_error.put('field', 'company_email');
            v_error.put('message', 'Excede ' || v_comp_email_max || ' caracteres.');
            v_errors.append(v_error);
        elsif instr(pi_company_email, '@') = 0 then
            v_error := json_object_t();
            v_error.put('field', 'company_email');
            v_error.put('message', 'El formato del correo corporativo no es valido.');
            v_errors.append(v_error);
        end if;

        if pi_id_org_specialty is null or pi_id_org_specialty <= 0 then
            v_error := json_object_t();
            v_error.put('field', 'id_org_specialty');
            v_error.put('message', 'Selecciona una especialidad valida.');
            v_errors.append(v_error);
        end if;

        if pi_phone is null or trim(pi_phone) = '' then
            v_error := json_object_t();
            v_error.put('field', 'phone');
            v_error.put('message', 'El telefono corporativo es obligatorio.');
            v_errors.append(v_error);
        elsif length(pi_phone) > v_phone_max then
            v_error := json_object_t();
            v_error.put('field', 'phone');
            v_error.put('message', 'Excede ' || v_phone_max || ' caracteres.');
            v_errors.append(v_error);
        end if;

        return v_errors;
    end fn_validate_organization_inputs;

    -- PROCEDIMIENTOS PÚBLICOS (API)

    procedure pr_api_authenticate (
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req          json_object_t;
        v_validation_errors json_array_t;
        v_response_json     json_object_t := json_object_t();

        -- Variables del Payload
        v_business_name     varchar2(4000);
        v_phone             varchar2(4000);
        v_email             varchar2(4000);
        v_password          varchar2(4000);
        v_first_name        varchar2(4000);
        v_last_name         varchar2(4000);
        v_company_email     varchar2(4000);
        v_id_org_specialty  number; -- Variable actualizada

        -- Identificadores de base de datos
        v_org_id            number;
        v_role_id           number;
        v_user_id           number;
        v_platform_user_id  number;
        v_public_slug       platform_user.public_slug%type;
        v_pro_id            number;
        v_org_slug          varchar2(200);
        v_verification_code varchar2(6);
        v_email_sent        number := 0;
    begin
        -- Parsear el JSON entrante
        if pi_body is null or dbms_lob.getlength(pi_body) = 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('El cuerpo de la petición (JSON) está vacío.', po_status_code, po_response_body);
            return;
        end if;

        begin
            v_json_req := json_object_t.parse(pi_body);
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling('JSON inválido o malformado.', po_status_code, po_response_body);
                return;
        end;

        -- Extraer valores
        v_business_name    := v_json_req.get_string('business_name');
        v_phone            := v_json_req.get_string('phone');
        v_email            := v_json_req.get_string('email');
        v_password         := v_json_req.get_string('password');
        v_first_name       := v_json_req.get_string('first_name');
        v_last_name        := v_json_req.get_string('last_name');
        v_company_email    := v_json_req.get_string('company_email');
        v_id_org_specialty := v_json_req.get_number('id_org_specialty');

        -- Llamar a la función validadora
        v_validation_errors := fn_validate_register_inputs(
            pi_business_name    => v_business_name,
            pi_phone            => v_phone,
            pi_email            => v_email,
            pi_password         => v_password,
            pi_first_name       => v_first_name,
            pi_last_name        => v_last_name,
            pi_company_email    => v_company_email,
            pi_id_org_specialty => v_id_org_specialty
        );

        -- Evaluar si hubo errores
        if v_validation_errors.get_size() > 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Por favor, corrija los errores en el formulario.');
            v_response_json.put('errors'  , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        -- INICIO DE LA TRANSACCIÓN DML
        insert into organization (
            name,
            company_email,
            org_spe_id_specialty
        ) values (
            trim(v_business_name),
            trim(v_company_email),
            v_id_org_specialty
        )
        returning id_organization into v_org_id;

        -- Crear Configuración del Workspace y Slug (unico y no reservado)
        v_org_slug := pkg_aox_util.fn_allocate_org_profile_slug(trim(v_business_name));
        insert into workspace_setting (
            org_id_organization,
            profile_slug,
            public_whatsapp,
            time_format,
            theme_pref,
            unanswered_alert_action,
            rsi_id_slot_interval,
            rh_id_reminder_hours
        ) values (
            v_org_id,
            v_org_slug,
            trim(v_phone),
            '24H',
            'dark',
            'KEEP',
            (SELECT id_slot_interval FROM ref_booking_slot_interval WHERE minutes_value = 30 AND is_active = 1 FETCH FIRST 1 ROW ONLY),
            (SELECT id_reminder_hours FROM ref_reminder_hours WHERE hours_value = 24 AND is_active = 1 FETCH FIRST 1 ROW ONLY)
        );

        -- Obtener ID del rol ADMIN
        begin
            select id_role into v_role_id
            from role where name = 'ADMIN';
        exception
            when no_data_found then
                raise_application_error(-20001, 'Rol ADMIN no encontrado en la base de datos.');
        end;

        -- Identidad global + membresía ADMIN (id_org_member = antiguo id_user para JWT/FKs)
        insert into platform_user (
            apex_user_name,
            email,
            password_hash,
            first_name,
            last_name,
            is_active
        ) values (
            upper(trim(v_email)),
            lower(trim(v_email)),
            pkg_aox_util.fn_hash_password(v_password),
            trim(v_first_name),
            trim(v_last_name),
            0
        ) returning id_platform_user into v_platform_user_id;

        v_public_slug := pkg_aox_util.fn_build_platform_user_public_slug(
            trim(v_first_name),
            trim(v_last_name),
            v_platform_user_id
        );

        update platform_user
           set public_slug = v_public_slug
         where id_platform_user = v_platform_user_id;

        insert into org_member (
            platform_user_id,
            org_id_organization,
            rol_id_role,
            is_active
        ) values (
            v_platform_user_id,
            v_org_id,
            v_role_id,
            0
        ) returning id_org_member into v_user_id;

        -- Crear Perfil de Profesional
        insert into professional (
            org_id_organization,
            usr_id_user,
            phone_number,
            is_active
        ) values (
            v_org_id,
            v_user_id,
            trim(v_phone),
            1
        ) returning id_professional into v_pro_id;

        -- Crear el código de verificación antes de confirmar la cuenta.
        pr_create_verification_code(
            pi_user_id => v_user_id,
            pi_email   => v_email,
            po_code    => v_verification_code
        );

        -- Consolidar transacción
        commit;

        pr_send_verification_email(
            pi_email      => v_email,
            pi_first_name => v_first_name,
            pi_code       => v_verification_code,
            po_sent       => v_email_sent
        );

        -- Generar Respuesta HTTP 201 Created
        po_status_code  := pkg_aox_util.c_success_create_code;
        v_response_json.put('status'          , 'success');
        v_response_json.put('message'         , 'Cuenta creada. Verifica tu correo electrónico para activar el acceso.');
        v_response_json.put('organization_id' , v_org_id);
        v_response_json.put('user_id'         , v_user_id);
        v_response_json.put('professional_id' , v_pro_id);
        v_response_json.put('email_verification_required', 1);
        v_response_json.put('email_sent', v_email_sent);

        po_response_body := v_response_json.to_clob();

    exception
        when dup_val_on_index then
            rollback;
            po_status_code := pkg_aox_util.c_conflict_code;
            v_response_json := json_object_t();
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'El correo electrónico ya se encuentra registrado.');
            po_response_body := v_response_json.to_clob();

        when others then
            rollback;
            po_status_code := pkg_aox_util.c_internal_error_code;
            v_response_json := json_object_t();
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'No fue posible completar el registro.');
            -- Si el error es por la FK (ORA-02291), podemos atajarlo para dar un mensaje más limpio
            if sqlcode = -2291 then
                v_response_json.put('details', 'El ID de la especialidad de la organización no existe en el sistema.');
            else
                v_response_json.put('details' , regexp_replace(sqlerrm, '^ORA-[0-9]+: ', ''));
            end if;
            po_response_body := v_response_json.to_clob();
    end pr_api_authenticate;

    procedure pr_error_handling (
        pi_error_msg        in varchar2,
        pi_status_code      in number,
        po_response_body    out clob
    ) is
    begin
        pkg_aox_util.pr_build_api_error_response(
            pi_status_code   => pi_status_code,
            pi_api_code      => pkg_aox_util.fn_resolve_api_code(pi_status_code, null, pi_error_msg),
            pi_message       => pi_error_msg,
            po_response_body => po_response_body
        );
    end pr_error_handling;

    function fn_validate_login_inputs(
        pi_identifier in varchar2, -- cambiado a identifier
        pi_password   in varchar2
    ) return json_array_t is
        v_errors        json_array_t := json_array_t();
        v_error         json_object_t;
        v_max_length    number;
    begin
        begin
            select data_length into v_max_length
            from user_tab_columns
            where table_name = 'APP_USER' and column_name = 'APEX_USER_NAME';
        exception
            when no_data_found then v_max_length := 100;
        end;

        -- Validaciones para el Identificador (Usuario o Email)
        if pi_identifier is null or trim(pi_identifier) = '' then
            v_error := json_object_t();
            v_error.put('field', 'username'); -- Puedes usar 'username' o 'email' aquí según prefiera tu frontend
            v_error.put('message', 'El usuario o correo es obligatorio.');
            v_errors.append(v_error);
        elsif length(pi_identifier) > v_max_length then
            v_error := json_object_t();
            v_error.put('field', 'username');
            v_error.put('message', 'El usuario o correo no puede exceder los ' || v_max_length || ' caracteres.');
            v_errors.append(v_error);
        elsif instr(pi_identifier, '@') > 0 and not regexp_like(pi_identifier, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') THEN
            v_error := json_object_t();
            v_error.put('field', 'username');
            v_error.put('message', 'El formato del correo electrónico no es válido.');
            v_errors.append(v_error);
        end if;

        -- Validaciones para la contraseña
        if pi_password is null or trim(pi_password) = '' then
            v_error := json_object_t();
            v_error.put('field', 'password');
            v_error.put('message', 'La contraseña es obligatoria.');
            v_errors.append(v_error);
        end if;

        return v_errors;
    end fn_validate_login_inputs;

    procedure pr_login_auth(
        pi_body          in clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_user_id            org_member.id_org_member%type;
        v_org_id             org_member.org_id_organization%type;
        v_id_rol             role.id_role%type;
        v_platform_user_id   platform_user.id_platform_user%type;
        v_password_hash      platform_user.password_hash%type;
        v_email_verified_at  platform_user.email_verified_at%type;
        v_email              platform_user.email%type;
        v_pu_active          platform_user.is_active%type;
        v_membership_count   number;
        v_requested_member   org_member.id_org_member%type;

        v_json_req           json_object_t;
        v_identifier         varchar2(100);
        v_password           varchar2(255);
        v_validation_errors  json_array_t;
        v_response_json      json_object_t;
        v_orgs_arr           json_array_t;
        v_org_obj            json_object_t;
        v_access_token       clob;
        v_refresh_token      varchar2(255);
        v_selection_token    clob;
    begin
        v_response_json := json_object_t();

        begin
            v_json_req := json_object_t.parse(pi_body);
            v_identifier := v_json_req.get_string('username');
            if v_identifier is null then
                v_identifier := v_json_req.get_string('email');
            end if;
            v_password := v_json_req.get_string('password');
            if v_json_req.has('org_member_id') then
                v_requested_member := v_json_req.get_number('org_member_id');
            end if;
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'El cuerpo de la petición (JSON) es inválido o está vacío.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        v_validation_errors := fn_validate_login_inputs(v_identifier, v_password);
        if v_validation_errors.get_size() > 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Errores de validación en los campos enviados.');
            v_response_json.put('errors', v_validation_errors);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        begin
            select
                pu.id_platform_user,
                pu.password_hash,
                pu.email_verified_at,
                pu.email,
                pu.is_active
            into
                v_platform_user_id,
                v_password_hash,
                v_email_verified_at,
                v_email,
                v_pu_active
            from platform_user pu
            where upper(pu.apex_user_name) = upper(trim(v_identifier))
               or upper(pu.email) = upper(trim(v_identifier));
        exception
            when no_data_found then
                raise_application_error(-20001, 'Credenciales inválidas.');
        end;

        if pkg_aox_util.fn_hash_password(v_password) != v_password_hash then
            raise_application_error(-20001, 'Usuario o contraseña incorrectos.');
        end if;

        if v_pu_active = 0 and v_email_verified_at is null then
            po_status_code := pkg_aox_util.c_unauthorized_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Error de autenticación.');
            v_response_json.put('details', 'Debes verificar tu correo electrónico antes de iniciar sesión.');
            v_response_json.put('email_verification_required', 1);
            v_response_json.put('email', v_email);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        if v_pu_active = 0 then
            raise_application_error(-20002, 'La cuenta de usuario está inactiva. Contacte al administrador.');
        end if;

        select count(*)
          into v_membership_count
          from org_member m
         where m.platform_user_id = v_platform_user_id
           and m.is_active = 1;

        if v_membership_count = 0 then
            raise_application_error(-20002, 'La cuenta de usuario está inactiva. Contacte al administrador.');
        end if;

        if v_requested_member is not null and v_requested_member > 0 then
            begin
                select m.id_org_member, m.org_id_organization, m.rol_id_role
                  into v_user_id, v_org_id, v_id_rol
                  from org_member m
                 where m.id_org_member = v_requested_member
                   and m.platform_user_id = v_platform_user_id
                   and m.is_active = 1;
            exception
                when no_data_found then
                    raise_application_error(-20041, 'La organización seleccionada no está disponible.');
            end;
        elsif v_membership_count = 1 then
            select m.id_org_member, m.org_id_organization, m.rol_id_role
              into v_user_id, v_org_id, v_id_rol
              from org_member m
             where m.platform_user_id = v_platform_user_id
               and m.is_active = 1;
        else
            v_orgs_arr := json_array_t();
            for rec in (
                select
                    m.id_org_member,
                    m.org_id_organization,
                    o.name as org_name,
                    m.rol_id_role,
                    r.name as role_name
                from org_member m
                inner join organization o on o.id_organization = m.org_id_organization
                inner join role r on r.id_role = m.rol_id_role
                where m.platform_user_id = v_platform_user_id
                  and m.is_active = 1
                order by o.name, m.id_org_member
            ) loop
                v_org_obj := json_object_t();
                v_org_obj.put('org_member_id', rec.id_org_member);
                v_org_obj.put('organization_id', rec.org_id_organization);
                v_org_obj.put('organization_name', rec.org_name);
                v_org_obj.put('role_id', rec.rol_id_role);
                v_org_obj.put('role_name', rec.role_name);
                v_orgs_arr.append(v_org_obj);
            end loop;

            pkg_aox_jwt.pr_generate_org_selection_token(
                pi_platform_user_id => v_platform_user_id,
                pi_identifier       => v_identifier,
                po_selection_token  => v_selection_token
            );

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('message', 'Selecciona la organización a la que deseas ingresar.');
            v_response_json.put('selection_required', 1);
            v_response_json.put('selection_token', v_selection_token);
            v_response_json.put('organizations', v_orgs_arr);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        pkg_aox_jwt.pr_generate_auth_tokens(
            pi_user_id       => v_user_id,
            pi_org_id        => v_org_id,
            pi_username      => v_identifier,
            pi_role_id       => v_id_rol,
            po_access_token  => v_access_token,
            po_refresh_token => v_refresh_token
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Autenticación exitosa.');
        v_response_json.put('selection_required', 0);
        v_response_json.put('user_id', v_user_id);
        v_response_json.put('organization_id', v_org_id);
        v_response_json.put('access_token', v_access_token);
        v_response_json.put('refresh_token', v_refresh_token);
        v_response_json.put('expires_in', pkg_aox_util.fn_param_number('JWT_ACCESS_EXP_SEC', 3600));
        po_response_body := v_response_json.to_clob();

    exception
        when others then
            po_status_code := pkg_aox_util.c_unauthorized_code;
            v_response_json := json_object_t();
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Error de autenticación.');
            v_response_json.put('details', regexp_replace(sqlerrm, '^ORA-[0-9]+: ', ''));
            po_response_body := v_response_json.to_clob();
    end pr_login_auth;

    procedure pr_select_organization(
        pi_body          in clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req           json_object_t;
        v_selection_token    varchar2(4000);
        v_org_member_id      org_member.id_org_member%type;
        v_platform_user_id platform_user.id_platform_user%type;
        v_user_id            org_member.id_org_member%type;
        v_org_id             org_member.org_id_organization%type;
        v_id_rol             role.id_role%type;
        v_identifier         platform_user.apex_user_name%type;
        v_access_token       clob;
        v_refresh_token      varchar2(255);
        v_response_json      json_object_t := json_object_t();
    begin
        begin
            v_json_req := json_object_t.parse(pi_body);
            v_selection_token := v_json_req.get_string('selection_token');
            v_org_member_id := v_json_req.get_number('org_member_id');
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'JSON inválido.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        if v_selection_token is null or trim(v_selection_token) = '' then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'El token de selección es obligatorio.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        if v_org_member_id is null or v_org_member_id <= 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Debe seleccionar una organización.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        v_platform_user_id := pkg_aox_jwt.fn_get_platform_user_from_selection_token(v_selection_token);
        if v_platform_user_id is null then
            po_status_code := pkg_aox_util.c_unauthorized_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'La sesión de selección expiró. Vuelve a iniciar sesión.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        begin
            select
                m.id_org_member,
                m.org_id_organization,
                m.rol_id_role,
                pu.apex_user_name
            into
                v_user_id,
                v_org_id,
                v_id_rol,
                v_identifier
            from org_member m
            inner join platform_user pu on pu.id_platform_user = m.platform_user_id
            where m.id_org_member = v_org_member_id
              and m.platform_user_id = v_platform_user_id
              and m.is_active = 1
              and pu.is_active = 1;
        exception
            when no_data_found then
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'La organización seleccionada no está disponible.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        pkg_aox_jwt.pr_generate_auth_tokens(
            pi_user_id       => v_user_id,
            pi_org_id        => v_org_id,
            pi_username      => v_identifier,
            pi_role_id       => v_id_rol,
            po_access_token  => v_access_token,
            po_refresh_token => v_refresh_token
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Autenticación exitosa.');
        v_response_json.put('selection_required', 0);
        v_response_json.put('user_id', v_user_id);
        v_response_json.put('organization_id', v_org_id);
        v_response_json.put('access_token', v_access_token);
        v_response_json.put('refresh_token', v_refresh_token);
        v_response_json.put('expires_in', pkg_aox_util.fn_param_number('JWT_ACCESS_EXP_SEC', 3600));
        po_response_body := v_response_json.to_clob();
    exception
        when others then
            po_status_code := pkg_aox_util.c_internal_error_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'No fue posible completar el acceso a la organización.');
            v_response_json.put('details', regexp_replace(sqlerrm, '^ORA-[0-9]+: ', ''));
            po_response_body := v_response_json.to_clob();
    end pr_select_organization;

    procedure pr_list_my_organizations(
        pi_auth_header   in varchar2,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_caller_member_id   org_member.id_org_member%type;
        v_platform_user_id   platform_user.id_platform_user%type;
        v_orgs_arr           json_array_t := json_array_t();
        v_org_obj            json_object_t;
        v_response_json      json_object_t := json_object_t();
        v_membership_count   number;
    begin
        if pi_auth_header is null or trim(pi_auth_header) = '' then
            po_status_code := pkg_aox_util.c_unauthorized_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Debes iniciar sesion.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        begin
            v_caller_member_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
            select m.platform_user_id
              into v_platform_user_id
              from org_member m
             where m.id_org_member = v_caller_member_id
               and m.is_active = 1;
        exception
            when others then
                po_status_code := pkg_aox_util.c_unauthorized_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Sesion invalida o expirada.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        select count(*)
          into v_membership_count
          from org_member m
         where m.platform_user_id = v_platform_user_id
           and m.is_active = 1;

        for rec in (
            select
                m.id_org_member,
                m.org_id_organization,
                o.name as org_name,
                m.rol_id_role,
                r.name as role_name
            from org_member m
            inner join organization o on o.id_organization = m.org_id_organization
            inner join role r on r.id_role = m.rol_id_role
            where m.platform_user_id = v_platform_user_id
              and m.is_active = 1
            order by o.name, m.id_org_member
        ) loop
            v_org_obj := json_object_t();
            v_org_obj.put('org_member_id', rec.id_org_member);
            v_org_obj.put('organization_id', rec.org_id_organization);
            v_org_obj.put('organization_name', rec.org_name);
            v_org_obj.put('role_id', rec.rol_id_role);
            v_org_obj.put('role_name', rec.role_name);
            v_org_obj.put('is_current', case when rec.id_org_member = v_caller_member_id then 1 else 0 end);
            v_orgs_arr.append(v_org_obj);
        end loop;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Organizaciones disponibles.');
        v_response_json.put('current_org_member_id', v_caller_member_id);
        v_response_json.put('membership_count', v_membership_count);
        v_response_json.put('organizations', v_orgs_arr);
        po_response_body := v_response_json.to_clob();
    exception
        when others then
            po_status_code := pkg_aox_util.c_internal_error_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'No fue posible obtener tus organizaciones.');
            v_response_json.put('details', regexp_replace(sqlerrm, '^ORA-[0-9]+: ', ''));
            po_response_body := v_response_json.to_clob();
    end pr_list_my_organizations;

    procedure pr_switch_organization(
        pi_auth_header   in varchar2,
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req             json_object_t;
        v_org_member_id        org_member.id_org_member%type;
        v_caller_member_id     org_member.id_org_member%type;
        v_platform_user_id     platform_user.id_platform_user%type;
        v_user_id              org_member.id_org_member%type;
        v_org_id               org_member.org_id_organization%type;
        v_id_rol               role.id_role%type;
        v_identifier           platform_user.apex_user_name%type;
        v_access_token         clob;
        v_refresh_token        varchar2(255);
        v_response_json        json_object_t := json_object_t();
    begin
        if pi_auth_header is null or trim(pi_auth_header) = '' then
            po_status_code := pkg_aox_util.c_unauthorized_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Debes iniciar sesion.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        begin
            v_json_req := json_object_t.parse(pi_body);
            v_org_member_id := v_json_req.get_number('org_member_id');
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'JSON invalido.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        if v_org_member_id is null or v_org_member_id <= 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Debe seleccionar una organizacion.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        begin
            v_caller_member_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
            select m.platform_user_id
              into v_platform_user_id
              from org_member m
             where m.id_org_member = v_caller_member_id
               and m.is_active = 1;
        exception
            when others then
                po_status_code := pkg_aox_util.c_unauthorized_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Sesion invalida o expirada.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        begin
            select
                m.id_org_member,
                m.org_id_organization,
                m.rol_id_role,
                pu.apex_user_name
            into
                v_user_id,
                v_org_id,
                v_id_rol,
                v_identifier
            from org_member m
            inner join platform_user pu on pu.id_platform_user = m.platform_user_id
            where m.id_org_member = v_org_member_id
              and m.platform_user_id = v_platform_user_id
              and m.is_active = 1
              and pu.is_active = 1;
        exception
            when no_data_found then
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'La organizacion seleccionada no esta disponible.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        if v_user_id = v_caller_member_id then
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('message', 'Ya estas en esta organizacion.');
            v_response_json.put('user_id', v_user_id);
            v_response_json.put('organization_id', v_org_id);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        pkg_aox_jwt.pr_generate_auth_tokens(
            pi_user_id       => v_user_id,
            pi_org_id        => v_org_id,
            pi_username      => v_identifier,
            pi_role_id       => v_id_rol,
            po_access_token  => v_access_token,
            po_refresh_token => v_refresh_token
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Organizacion cambiada correctamente.');
        v_response_json.put('selection_required', 0);
        v_response_json.put('user_id', v_user_id);
        v_response_json.put('organization_id', v_org_id);
        v_response_json.put('access_token', v_access_token);
        v_response_json.put('refresh_token', v_refresh_token);
        v_response_json.put('expires_in', pkg_aox_util.fn_param_number('JWT_ACCESS_EXP_SEC', 3600));
        po_response_body := v_response_json.to_clob();
    exception
        when others then
            po_status_code := pkg_aox_util.c_internal_error_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'No fue posible cambiar de organizacion.');
            v_response_json.put('details', regexp_replace(sqlerrm, '^ORA-[0-9]+: ', ''));
            po_response_body := v_response_json.to_clob();
    end pr_switch_organization;

    procedure pr_logout(
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req       json_object_t;
        v_refresh_token  varchar2(255);
        v_response_json  json_object_t := json_object_t();
    begin
        -- Extraer el refresh_token del JSON
        begin
            v_json_req      := json_object_t.parse(pi_body);
            v_refresh_token := v_json_req.get_string('refresh_token');
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code; -- Bad Request
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'El cuerpo de la petición no es un JSON válido.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        -- Si no envían token, asumimos éxito (cierre de sesión idempotente)
        if v_refresh_token is not null then
            -- 2. Revocar el token en la base de datos
            update app_user_session
            set is_revoked      = 1
            where refresh_token = v_refresh_token;
        end if;

        -- Devolver éxito
        po_status_code      := pkg_aox_util.c_success_ok_code; -- OK
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Sesión cerrada correctamente.');
        po_response_body    := v_response_json.to_clob();

    exception
        when others then
            po_status_code := pkg_aox_util.c_internal_error_code; -- Internal Server Error
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Error interno al cerrar sesión.');
            po_response_body := v_response_json.to_clob();
    end pr_logout;

    procedure pr_verify_email(
        pi_body          in clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req        json_object_t;
        v_email           varchar2(255);
        v_code            varchar2(20);
        v_user_id         org_member.id_org_member%type;
        v_platform_user_id platform_user.id_platform_user%type;
        v_is_active       org_member.is_active%type;
        v_verified_at     platform_user.email_verified_at%type;
        v_id_verification app_user_email_verification.id_verification%type;
        v_code_hash       app_user_email_verification.code_hash%type;
        v_attempt_count   app_user_email_verification.attempt_count%type;
        v_max_attempts    app_user_email_verification.max_attempts%type;
        v_response_json   json_object_t := json_object_t();
    begin
        begin
            v_json_req := json_object_t.parse(pi_body);
            v_email    := v_json_req.get_string('email');
            v_code     := v_json_req.get_string('code');
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling('JSON inválido o malformado.', po_status_code, po_response_body);
                return;
        end;

        if v_email is null or trim(v_email) = '' then
            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('El correo electrónico es obligatorio.', po_status_code, po_response_body);
            return;
        end if;

        if v_code is null or not regexp_like(trim(v_code), '^[0-9]{6}$') then
            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('El código debe tener 6 dígitos.', po_status_code, po_response_body);
            return;
        end if;

        begin
            select m.id_org_member, m.is_active, pu.email_verified_at, m.platform_user_id
            into v_user_id, v_is_active, v_verified_at, v_platform_user_id
            from platform_user pu
            inner join org_member m on m.platform_user_id = pu.id_platform_user
            where upper(pu.email) = upper(trim(v_email))
            order by m.created_at
            fetch first 1 row only;
        exception
            when no_data_found then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling('El código es inválido o ha expirado.', po_status_code, po_response_body);
                return;
        end;

        if v_verified_at is not null and v_is_active = 1 then
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('message', 'Tu correo ya estaba verificado. Puedes iniciar sesión.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        begin
            select id_verification, code_hash, attempt_count, max_attempts
            into v_id_verification, v_code_hash, v_attempt_count, v_max_attempts
            from (
                select id_verification, code_hash, attempt_count, max_attempts
                from app_user_email_verification
                where usr_id_user = v_user_id
                  and consumed_at is null
                  and expires_at > current_timestamp
                  and attempt_count < max_attempts
                order by created_at desc
            )
            where rownum = 1;
        exception
            when no_data_found then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling('El código es inválido, fue utilizado o ha expirado.', po_status_code, po_response_body);
                return;
        end;

        if v_code_hash != fn_verification_code_hash(v_user_id, v_email, v_code) then
            update app_user_email_verification
            set attempt_count = least(attempt_count + 1, max_attempts)
            where id_verification = v_id_verification;

            commit;

            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('El código ingresado no es correcto.', po_status_code, po_response_body);
            return;
        end if;

        update platform_user
        set email_verified_at = coalesce(email_verified_at, current_timestamp),
            is_active         = 1
        where id_platform_user = v_platform_user_id;

        update org_member
        set is_active = 1
        where platform_user_id = v_platform_user_id;

        update app_user_email_verification
        set consumed_at = current_timestamp
        where usr_id_user = v_user_id
          and consumed_at is null;

        commit;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Correo verificado correctamente. Ya puedes iniciar sesión.');
        po_response_body := v_response_json.to_clob();
    exception
        when others then
            rollback;
            po_status_code := pkg_aox_util.c_internal_error_code;
            pr_error_handling('Error interno al verificar el correo electrónico.', po_status_code, po_response_body);
    end pr_verify_email;

    procedure pr_resend_verification_code(
        pi_body          in clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req          json_object_t;
        v_email             varchar2(255);
        v_user_id           org_member.id_org_member%type;
        v_first_name        platform_user.first_name%type;
        v_is_active         org_member.is_active%type;
        v_verified_at       platform_user.email_verified_at%type;
        v_last_sent_at      app_user_email_verification.sent_at%type;
        v_verification_code varchar2(6);
        v_email_sent        number := 0;
        v_response_json     json_object_t := json_object_t();
    begin
        begin
            v_json_req := json_object_t.parse(pi_body);
            v_email    := v_json_req.get_string('email');
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling('JSON inválido o malformado.', po_status_code, po_response_body);
                return;
        end;

        if v_email is null or trim(v_email) = '' then
            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('El correo electrónico es obligatorio.', po_status_code, po_response_body);
            return;
        end if;

        begin
            select m.id_org_member, pu.first_name, m.is_active, pu.email_verified_at
            into v_user_id, v_first_name, v_is_active, v_verified_at
            from platform_user pu
            inner join org_member m on m.platform_user_id = pu.id_platform_user
            where upper(pu.email) = upper(trim(v_email))
            order by m.created_at
            fetch first 1 row only;
        exception
            when no_data_found then
                po_status_code := pkg_aox_util.c_success_ok_code;
                v_response_json.put('status', 'success');
                v_response_json.put('message', 'Si existe una cuenta pendiente para este correo, enviaremos un nuevo código.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        if v_verified_at is not null and v_is_active = 1 then
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('message', 'Este correo ya está verificado. Puedes iniciar sesión.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        begin
            select sent_at
            into v_last_sent_at
            from (
                select sent_at
                from app_user_email_verification
                where usr_id_user = v_user_id
                  and consumed_at is null
                order by sent_at desc
            )
            where rownum = 1;
        exception
            when no_data_found then
                v_last_sent_at := null;
        end;

        if v_last_sent_at is not null
           and v_last_sent_at > current_timestamp - numtodsinterval(c_resend_wait_seconds, 'SECOND') then
            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('Espera un minuto antes de solicitar un nuevo código.', po_status_code, po_response_body);
            return;
        end if;

        pr_create_verification_code(
            pi_user_id => v_user_id,
            pi_email   => v_email,
            po_code    => v_verification_code
        );

        commit;

        pr_send_verification_email(
            pi_email      => v_email,
            pi_first_name => v_first_name,
            pi_code       => v_verification_code,
            po_sent       => v_email_sent
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Te enviamos un nuevo código de verificación.');
        v_response_json.put('email_sent', v_email_sent);
        po_response_body := v_response_json.to_clob();
    exception
        when others then
            rollback;
            po_status_code := pkg_aox_util.c_internal_error_code;
            pr_error_handling('Error interno al reenviar el código de verificación.', po_status_code, po_response_body);
    end pr_resend_verification_code;

    procedure pr_forgot_password(
        pi_body          in clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req      json_object_t;
        v_email         varchar2(255);
        v_user_id       number;
        v_token         varchar2(100);
        v_response_json json_object_t := json_object_t();
        v_first_name    platform_user.first_name%TYPE;
        v_apex_session_created boolean := false;
    begin
        -- Parsear JSON
        begin
            v_json_req := json_object_t.parse(pi_body);
            v_email    := v_json_req.get_string('email');
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling('JSON inválido o malformado.', po_status_code, po_response_body);
                return;
        end;

        if v_email is null or trim(v_email) = '' then
            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('El correo electrónico es obligatorio.', po_status_code, po_response_body);
            return;
        end if;

        -- Buscar si el usuario existe y está activo
        begin
            select
                m.id_org_member,
                pu.first_name
            into
                v_user_id,
                v_first_name
            from platform_user pu
            inner join org_member m
                    on m.platform_user_id = pu.id_platform_user
                   and m.is_active = 1
            where upper(pu.email) = upper(trim(v_email))
              and pu.is_active = 1
            order by m.created_at
            fetch first 1 row only;
        exception
            when no_data_found then
                -- Por seguridad, respondemos igual que si el correo existiera.
                po_status_code := pkg_aox_util.c_success_ok_code;
                v_response_json.put('status', 'success');
                v_response_json.put(
                    'message',
                    'Si el correo está registrado, recibirás un enlace para restablecer tu contraseña.'
                );
                po_response_body := v_response_json.to_clob();
                return;
        end;

        -- Generar un Token Único (SYS_GUID genera 32 caracteres hexadecimales aleatorios)
        v_token := lower(rawtohex(sys_guid()));

        -- Insertar el token con 5 minutos de validez
        insert into app_user_pwd_reset (
            usr_id_user,
            reset_token,
            expires_at
        ) values (
            v_user_id,
            v_token,
            current_timestamp + interval '5' minute
        );

        commit;

        -- Responder con éxito
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Se ha generado el token de recuperación.');

        -- Aquí devolvemos el token para Postman.
        -- v_response_json.put('reset_token', v_token);

        -- Enviar el Token usando el Template de APEX
        begin
            apex_session.create_session(
                p_app_id   => 100,
                p_page_id  => 1,
                p_username => 'AOX'
            );
            v_apex_session_created := true;

            apex_mail.send(
                p_to                 => trim(v_email),
                p_from               => NVL(fn_get_parameter('MAIL_FROM_ADDRESS'), 'noreply@hasel.app'),
                p_template_static_id => 'PWDRESET',
                p_placeholders       => '{' ||
                                        '"NOMBRE": "' || v_first_name || '",' ||
                                        '"TOKEN": "' || v_token || '"' ||
                                        '}'
            );

            -- Forzar el envío inmediato
            apex_mail.push_queue;

        exception
            when others then
                null; -- Silenciamos el error para el usuario
        end;

        if v_apex_session_created then
            begin
                apex_session.delete_session;
            exception
                when others then
                    null;
            end;
        end if;

        po_response_body := v_response_json.to_clob();

    exception
        when others then
            rollback;
            po_status_code := pkg_aox_util.c_internal_error_code;
            pr_error_handling('Error interno al generar recuperación de contraseña.', po_status_code, po_response_body);
    end pr_forgot_password;


    procedure pr_reset_password(
        pi_body          in clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req      json_object_t;
        v_token         varchar2(100);
        v_new_password  varchar2(255);
        v_user_id       number;
        v_id_reset      number;
        v_response_json json_object_t := json_object_t();
        v_validation_errors json_array_t := json_array_t();
        v_error         json_object_t;
    begin
        -- Parsear JSON
        begin
            v_json_req     := json_object_t.parse(pi_body);
            v_token        := v_json_req.get_string('token');
            v_new_password := v_json_req.get_string('new_password');
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling('JSON inválido o malformado.', po_status_code, po_response_body);
                return;
        end;

        if v_token is null then
            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('El token es obligatorio.', po_status_code, po_response_body);
            return;
        end if;

        -- Aplicamos las mismas reglas de seguridad de contraseña que en el registro
        if v_new_password is null or length(trim(v_new_password)) < 8 then
            v_error := json_object_t();
            v_error.put('field', 'new_password');
            v_error.put('message', 'La contraseña debe tener al menos 8 caracteres.');
            v_validation_errors.append(v_error);
        elsif not regexp_like(v_new_password, '[A-Z]') then
            v_error := json_object_t();
            v_error.put('field', 'new_password');
            v_error.put('message', 'La contraseña debe contener al menos una letra mayúscula.');
            v_validation_errors.append(v_error);
        elsif not regexp_like(v_new_password, '[0-9]') then
            v_error := json_object_t();
            v_error.put('field', 'new_password');
            v_error.put('message', 'La contraseña debe contener al menos un número.');
            v_validation_errors.append(v_error);
        end if;

        if v_validation_errors.get_size() > 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'La contraseña no cumple con los requisitos de seguridad.');
            v_response_json.put('errors'  , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        -- Validar el token en la base de datos
        begin
            select
                id_reset,
                usr_id_user
            into
                v_id_reset,
                v_user_id
            from app_user_pwd_reset
            where reset_token = v_token
                and is_used = 0
                and expires_at > current_timestamp;
        exception
            when no_data_found then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling(
                    'El token es inválido, ya fue utilizado o ha expirado.',
                    po_status_code,
                    po_response_body
                );
                return;
        end;

        -- Actualizar la contraseña de la identidad global
        update platform_user pu
        set password_hash = pkg_aox_util.fn_hash_password(v_new_password)
        where pu.id_platform_user = (
            select m.platform_user_id from org_member m where m.id_org_member = v_user_id
        );

        -- Invalidar el token para que no se pueda volver a usar
        update app_user_pwd_reset
        set is_used     = 1
        where id_reset  = v_id_reset;

        -- Revocar todas las sesiones activas del usuario
        update app_user_session
        set is_revoked    = 1
        where use_id_user = v_user_id;

        commit;

        -- Responder con éxito
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Tu contraseña ha sido actualizada exitosamente.');
        po_response_body := v_response_json.to_clob();

    exception
        when others then
            rollback;
            po_status_code := pkg_aox_util.c_internal_error_code;
            pr_error_handling('Error interno al actualizar la contraseña.', po_status_code, po_response_body);
    end pr_reset_password;


    procedure pr_send_invitation_email(
        pi_email         in  varchar2,
        pi_org_name      in  varchar2,
        pi_invite_url    in  varchar2,
        pi_expires_at    in  varchar2,
        po_sent          out number
    ) is
        v_apex_session_created boolean := false;
        v_org_name               varchar2(200);
    begin
        po_sent := 0;

        if pi_email is null or trim(pi_email) = '' then
            return;
        end if;

        v_org_name := nvl(trim(pi_org_name), 'tu organizacion');

        apex_session.create_session(
            p_app_id   => 100,
            p_page_id  => 1,
            p_username => 'AOX'
        );
        v_apex_session_created := true;

        apex_mail.send(
            p_to                 => trim(pi_email),
            p_from               => nvl(fn_get_parameter('MAIL_FROM_ADDRESS'), 'noreply@hasel.app'),
            p_template_static_id => c_invitation_template,
            p_placeholders       => '{' ||
                                    '"ORG_NAME": "' || fn_json_escape(v_org_name) || '",' ||
                                    '"INVITE_URL": "' || fn_json_escape(trim(pi_invite_url)) || '",' ||
                                    '"EXPIRES_AT": "' || fn_json_escape(trim(pi_expires_at)) || '"' ||
                                    '}'
        );

        apex_mail.push_queue;
        commit;
        po_sent := 1;

        if v_apex_session_created then
            begin
                apex_session.delete_session;
            exception
                when others then
                    null;
            end;
        end if;
    exception
        when others then
            if v_apex_session_created then
                begin
                    apex_session.delete_session;
                exception
                    when others then
                        null;
                end;
            end if;
            po_sent := 0;
    end pr_send_invitation_email;


    procedure pr_create_organization(
        pi_auth_header   in  varchar2,
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req           json_object_t;
        v_validation_errors  json_array_t;
        v_response_json      json_object_t := json_object_t();
        v_business_name      varchar2(4000);
        v_phone              varchar2(4000);
        v_company_email      varchar2(4000);
        v_id_org_specialty   number;
        v_caller_member_id   org_member.id_org_member%type;
        v_platform_user_id   platform_user.id_platform_user%type;
        v_pu_active          platform_user.is_active%type;
        v_email_verified_at  platform_user.email_verified_at%type;
        v_apex_user_name     platform_user.apex_user_name%type;
        v_org_id             organization.id_organization%type;
        v_role_id            role.id_role%type;
        v_user_id            org_member.id_org_member%type;
        v_pro_id             professional.id_professional%type;
        v_org_slug           varchar2(200);
        v_access_token       clob;
        v_refresh_token      varchar2(255);
    begin
        if pi_auth_header is null or trim(pi_auth_header) = '' then
            po_status_code := pkg_aox_util.c_unauthorized_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Debes iniciar sesion para crear una organizacion.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        v_platform_user_id := pkg_aox_jwt.fn_get_platform_user_from_selection_token(
            regexp_replace(trim(pi_auth_header), '^Bearer ', '', 1, 1, 'i')
        );

        if v_platform_user_id is null then
            begin
                v_caller_member_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

                select m.platform_user_id
                  into v_platform_user_id
                  from org_member m
                 where m.id_org_member = v_caller_member_id;
            exception
                when others then
                    po_status_code := pkg_aox_util.c_unauthorized_code;
                    v_response_json.put('status', 'error');
                    v_response_json.put('message', 'Sesion invalida o expirada.');
                    po_response_body := v_response_json.to_clob();
                    return;
            end;
        end if;

        if v_platform_user_id is null then
            po_status_code := pkg_aox_util.c_unauthorized_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'No fue posible identificar tu cuenta.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        begin
            select pu.is_active, pu.email_verified_at, pu.apex_user_name
              into v_pu_active, v_email_verified_at, v_apex_user_name
              from platform_user pu
             where pu.id_platform_user = v_platform_user_id;
        exception
            when no_data_found then
                po_status_code := pkg_aox_util.c_unauthorized_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Cuenta no encontrada.');
                po_response_body := v_response_json.to_clob();
                return;
        end;

        if v_pu_active = 0 and v_email_verified_at is null then
            po_status_code := pkg_aox_util.c_unauthorized_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Debes verificar tu correo electronico antes de crear una organizacion.');
            v_response_json.put('email_verification_required', 1);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        if v_pu_active = 0 then
            po_status_code := pkg_aox_util.c_forbidden_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Tu cuenta esta inactiva. Contacta al administrador.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        if pi_body is null or dbms_lob.getlength(pi_body) = 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('El cuerpo de la peticion (JSON) esta vacio.', po_status_code, po_response_body);
            return;
        end if;

        begin
            v_json_req := json_object_t.parse(pi_body);
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling('JSON invalido o malformado.', po_status_code, po_response_body);
                return;
        end;

        v_business_name    := v_json_req.get_string('business_name');
        v_phone            := v_json_req.get_string('phone');
        v_company_email    := v_json_req.get_string('company_email');
        v_id_org_specialty := v_json_req.get_number('id_org_specialty');

        v_validation_errors := fn_validate_organization_inputs(
            pi_business_name    => v_business_name,
            pi_phone            => v_phone,
            pi_company_email    => v_company_email,
            pi_id_org_specialty => v_id_org_specialty
        );

        if v_validation_errors.get_size() > 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Por favor, corrija los errores en el formulario.');
            v_response_json.put('errors', v_validation_errors);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        insert into organization (
            name,
            company_email,
            org_spe_id_specialty
        ) values (
            trim(v_business_name),
            lower(trim(v_company_email)),
            v_id_org_specialty
        )
        returning id_organization into v_org_id;

        v_org_slug := pkg_aox_util.fn_allocate_org_profile_slug(trim(v_business_name));
        insert into workspace_setting (
            org_id_organization,
            profile_slug,
            public_whatsapp,
            time_format,
            theme_pref,
            unanswered_alert_action,
            rsi_id_slot_interval,
            rh_id_reminder_hours
        ) values (
            v_org_id,
            v_org_slug,
            trim(v_phone),
            '24H',
            'dark',
            'KEEP',
            (select id_slot_interval from ref_booking_slot_interval where minutes_value = 30 and is_active = 1 fetch first 1 row only),
            (select id_reminder_hours from ref_reminder_hours where hours_value = 24 and is_active = 1 fetch first 1 row only)
        );

        begin
            select id_role
              into v_role_id
              from role
             where name = 'ADMIN';
        exception
            when no_data_found then
                raise_application_error(-20001, 'Rol ADMIN no encontrado en la base de datos.');
        end;

        insert into org_member (
            platform_user_id,
            org_id_organization,
            rol_id_role,
            is_active
        ) values (
            v_platform_user_id,
            v_org_id,
            v_role_id,
            1
        ) returning id_org_member into v_user_id;

        insert into professional (
            org_id_organization,
            usr_id_user,
            phone_number,
            is_active
        ) values (
            v_org_id,
            v_user_id,
            trim(v_phone),
            1
        ) returning id_professional into v_pro_id;

        -- Suscripción TRIAL (Premium, 14 días) para la nueva organización
        pkg_aox_subscription_api.pr_ensure_trial_subscription(v_org_id);

        commit;

        pkg_aox_jwt.pr_generate_auth_tokens(
            pi_user_id       => v_user_id,
            pi_org_id        => v_org_id,
            pi_username      => v_apex_user_name,
            pi_role_id       => v_role_id,
            po_access_token  => v_access_token,
            po_refresh_token => v_refresh_token
        );

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Organizacion creada correctamente.');
        v_response_json.put('organization_id', v_org_id);
        v_response_json.put('user_id', v_user_id);
        v_response_json.put('professional_id', v_pro_id);
        v_response_json.put('access_token', v_access_token);
        v_response_json.put('refresh_token', v_refresh_token);
        v_response_json.put('expires_in', pkg_aox_util.fn_param_number('JWT_ACCESS_EXP_SEC', 3600));
        po_response_body := v_response_json.to_clob();
    exception
        when others then
            rollback;
            po_status_code := pkg_aox_util.c_internal_error_code;
            v_response_json := json_object_t();
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'No fue posible crear la organizacion.');
            if sqlcode = -2291 then
                v_response_json.put('details', 'El ID de la especialidad de la organizacion no existe en el sistema.');
            else
                v_response_json.put('details', regexp_replace(sqlerrm, '^ORA-[0-9]+: ', ''));
            end if;
            po_response_body := v_response_json.to_clob();
    end pr_create_organization;

    procedure pr_get_invitation(
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req      json_object_t;
        v_token         varchar2(64);
        v_response_json json_object_t := json_object_t();
        v_org_name        organization.name%type;
        v_expires_label   varchar2(100);
        v_login_required  number;
        v_user_exists     number;
    begin
        begin
            v_json_req := json_object_t.parse(pi_body);
            v_token    := lower(trim(v_json_req.get_string('token')));
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling('JSON invalido o malformado.', po_status_code, po_response_body);
                return;
        end;

        if v_token is null then
            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('El token de invitacion es obligatorio.', po_status_code, po_response_body);
            return;
        end if;

        begin
            select o.name,
                   to_char(i.expires_at, 'DD/MM/YYYY HH24:MI', 'NLS_DATE_LANGUAGE=SPANISH')
              into v_org_name, v_expires_label
              from org_invitation i
              join organization o on o.id_organization = i.org_id_organization
             where i.invite_token = v_token
               and i.status = 'PENDING'
               and i.expires_at > current_timestamp;
        exception
            when no_data_found then
                po_status_code := pkg_aox_util.c_not_found_code;
                pr_error_handling(
                    'La invitacion no existe, ya fue utilizada o expiro.',
                    po_status_code,
                    po_response_body
                );
                return;
        end;

        for rec in (
            select i.invite_email,
                   i.platform_user_id
              from org_invitation i
             where i.invite_token = v_token
               and i.status = 'PENDING'
               and i.expires_at > current_timestamp
        ) loop
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('organization_name', v_org_name);
            v_response_json.put('email', rec.invite_email);
            v_response_json.put('expires_at_label', v_expires_label);

            v_login_required := 0;
            if rec.platform_user_id is not null then
                v_login_required := 1;
            else
                select count(*)
                  into v_user_exists
                  from platform_user pu
                 where lower(pu.email) = lower(trim(rec.invite_email));

                if v_user_exists > 0 then
                    v_login_required := 1;
                end if;
            end if;

            v_response_json.put('login_required', v_login_required);
            po_response_body := v_response_json.to_clob();
            return;
        end loop;

        po_status_code := pkg_aox_util.c_not_found_code;
        pr_error_handling('La invitacion no existe o expiro.', po_status_code, po_response_body);
    exception
        when others then
            po_status_code := pkg_aox_util.c_internal_error_code;
            pr_error_handling('Error interno al consultar la invitacion.', po_status_code, po_response_body);
    end pr_get_invitation;


    procedure pr_accept_invitation(
        pi_auth_header   in  varchar2 default null,
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_json_req           json_object_t;
        v_token              varchar2(64);
        v_password           varchar2(255);
        v_first_name         varchar2(50);
        v_last_name          varchar2(50);
        v_response_json      json_object_t := json_object_t();
        v_validation_errors  json_array_t := json_array_t();
        v_error              json_object_t;

        v_invitation_id      org_invitation.id_org_invitation%type;
        v_org_id             org_invitation.org_id_organization%type;
        v_pro_id             org_invitation.pro_id_professional%type;
        v_role_id            org_invitation.rol_id_role%type;
        v_invite_email       org_invitation.invite_email%type;
        v_apex_user_name     org_invitation.apex_user_name%type;
        v_platform_user_id   org_invitation.platform_user_id%type;

        v_new_platform_id    platform_user.id_platform_user%type;
        v_new_member_id      org_member.id_org_member%type;
        v_caller_member_id   org_member.id_org_member%type;
        v_caller_platform_id platform_user.id_platform_user%type;
        v_existing_member    number;
        v_existing_member_id org_member.id_org_member%type;
        v_existing_member_active org_member.is_active%type;
        v_existing_prof_id   professional.id_professional%type;
        v_access_token       clob;
        v_refresh_token      varchar2(255);
        v_session_username   platform_user.apex_user_name%type;
        v_public_slug        platform_user.public_slug%type;
    begin
        begin
            v_json_req   := json_object_t.parse(pi_body);
            v_token      := lower(trim(v_json_req.get_string('token')));
            v_password   := v_json_req.get_string('password');
            v_first_name := trim(v_json_req.get_string('first_name'));
            v_last_name  := trim(v_json_req.get_string('last_name'));
        exception
            when others then
                po_status_code := pkg_aox_util.c_bad_request_code;
                pr_error_handling('JSON invalido o malformado.', po_status_code, po_response_body);
                return;
        end;

        if v_token is null then
            po_status_code := pkg_aox_util.c_bad_request_code;
            pr_error_handling('El token de invitacion es obligatorio.', po_status_code, po_response_body);
            return;
        end if;

        begin
            select i.id_org_invitation,
                   i.org_id_organization,
                   i.pro_id_professional,
                   i.rol_id_role,
                   i.invite_email,
                   i.apex_user_name,
                   i.platform_user_id
              into v_invitation_id,
                   v_org_id,
                   v_pro_id,
                   v_role_id,
                   v_invite_email,
                   v_apex_user_name,
                   v_platform_user_id
              from org_invitation i
             where i.invite_token = v_token
               and i.status = 'PENDING'
               and i.expires_at > current_timestamp
             for update;
        exception
            when no_data_found then
                po_status_code := pkg_aox_util.c_not_found_code;
                pr_error_handling(
                    'La invitacion no existe, ya fue utilizada o expiro.',
                    po_status_code,
                    po_response_body
                );
                return;
        end;

        if v_platform_user_id is null then
            begin
                select id_platform_user
                  into v_platform_user_id
                  from platform_user
                 where lower(email) = lower(trim(v_invite_email));
            exception
                when no_data_found then
                    v_platform_user_id := null;
            end;
        end if;

        if v_platform_user_id is not null then
            if v_password is not null and length(trim(v_password)) >= 8 then
                po_status_code := pkg_aox_util.c_conflict_code;
                v_response_json.put('status', 'error');
                v_response_json.put('login_required', 1);
                v_response_json.put(
                    'message',
                    'Este correo ya tiene cuenta. Cierra la sesion actual e inicia sesion con ese correo para aceptar la invitacion.'
                );
                po_response_body := v_response_json.to_clob();
                return;
            end if;

            if pi_auth_header is null or trim(pi_auth_header) = '' then
                po_status_code := 401;
                v_response_json.put('status', 'error');
                v_response_json.put('login_required', 1);
                v_response_json.put(
                    'message',
                    'Ya tienes una cuenta. Inicia sesion para aceptar la invitacion.'
                );
                po_response_body := v_response_json.to_clob();
                return;
            end if;

            v_caller_platform_id := pkg_aox_jwt.fn_get_platform_user_from_selection_token(
                regexp_replace(trim(pi_auth_header), '^Bearer ', '', 1, 1, 'i')
            );

            if v_caller_platform_id is null then
                v_caller_member_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
                select m.platform_user_id
                  into v_caller_platform_id
                  from org_member m
                 where m.id_org_member = v_caller_member_id;
            end if;

            if v_caller_platform_id is null or v_caller_platform_id <> v_platform_user_id then
                po_status_code := pkg_aox_util.c_forbidden_code;
                pr_error_handling(
                    'La sesion activa no corresponde al correo invitado.',
                    po_status_code,
                    po_response_body
                );
                return;
            end if;
        else
            if v_first_name is null or trim(v_first_name) = '' then
                v_error := json_object_t();
                v_error.put('field', 'first_name');
                v_error.put('message', 'El nombre es obligatorio.');
                v_validation_errors.append(v_error);
            end if;

            if v_last_name is null or trim(v_last_name) = '' then
                v_error := json_object_t();
                v_error.put('field', 'last_name');
                v_error.put('message', 'El apellido es obligatorio.');
                v_validation_errors.append(v_error);
            end if;

            if v_password is null or length(trim(v_password)) < 8 then
                v_error := json_object_t();
                v_error.put('field', 'password');
                v_error.put('message', 'La contrasena debe tener al menos 8 caracteres.');
                v_validation_errors.append(v_error);
            end if;

            if v_validation_errors.get_size() > 0 then
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Errores de validacion.');
                v_response_json.put('errors', v_validation_errors);
                po_response_body := v_response_json.to_clob();
                return;
            end if;

            select count(*)
              into v_existing_member
              from platform_user
             where upper(apex_user_name) = upper(trim(v_apex_user_name));
            if v_existing_member > 0 then
                v_apex_user_name := upper(substr(replace(v_invite_email, '@', '_'), 1, 100));
            end if;

            insert into platform_user (
                apex_user_name,
                email,
                password_hash,
                first_name,
                last_name,
                is_active,
                email_verified_at
            ) values (
                upper(trim(v_apex_user_name)),
                lower(trim(v_invite_email)),
                pkg_aox_util.fn_hash_password(v_password),
                trim(v_first_name),
                trim(v_last_name),
                1,
                current_timestamp
            ) returning id_platform_user into v_new_platform_id;

            v_public_slug := pkg_aox_util.fn_build_platform_user_public_slug(
                trim(v_first_name),
                trim(v_last_name),
                v_new_platform_id
            );

            update platform_user
               set public_slug = v_public_slug
             where id_platform_user = v_new_platform_id;

            v_platform_user_id := v_new_platform_id;
        end if;

        v_existing_member_id := null;
        v_existing_member_active := 0;

        begin
            select m.id_org_member,
                   m.is_active
              into v_existing_member_id,
                   v_existing_member_active
              from org_member m
             where m.platform_user_id    = v_platform_user_id
               and m.org_id_organization = v_org_id;
        exception
            when no_data_found then
                v_existing_member_id := null;
        end;

        if v_existing_member_id is not null and v_existing_member_active = 1 then
            po_status_code := pkg_aox_util.c_conflict_code;
            pr_error_handling('Ya perteneces a esta organizacion.', po_status_code, po_response_body);
            return;
        end if;

        if v_existing_member_id is not null and v_existing_member_active = 0 then
            -- Reingreso: reactivar membresía existente (sin duplicar org_member).
            v_new_member_id := v_existing_member_id;

            update org_member
               set is_active   = 1,
                   rol_id_role = v_role_id
             where id_org_member = v_existing_member_id;

            begin
                select p.id_professional
                  into v_existing_prof_id
                  from professional p
                 where p.usr_id_user = v_existing_member_id
                   and p.org_id_organization = v_org_id
                 order by p.id_professional desc
                 fetch first 1 row only;
            exception
                when no_data_found then
                    v_existing_prof_id := null;
            end;

            if v_existing_prof_id is not null and v_existing_prof_id <> v_pro_id then
                -- Fusionar datos del stub de invitación en el professional histórico.
                update professional p_keep
                   set phone_number = nvl(
                           (select p_inv.phone_number
                              from professional p_inv
                             where p_inv.id_professional = v_pro_id),
                           p_keep.phone_number
                       ),
                       spe_id_specialty = nvl(
                           (select p_inv.spe_id_specialty
                              from professional p_inv
                             where p_inv.id_professional = v_pro_id),
                           p_keep.spe_id_specialty
                       ),
                       profile_slug = nvl(
                           nullif(trim((select p_inv.profile_slug
                                          from professional p_inv
                                         where p_inv.id_professional = v_pro_id)), ''),
                           p_keep.profile_slug
                       ),
                       is_active = 1
                 where p_keep.id_professional = v_existing_prof_id;

                insert into professional_service (
                    org_id_organization,
                    pro_id_professional,
                    ser_id_service
                )
                select ps.org_id_organization,
                       v_existing_prof_id,
                       ps.ser_id_service
                  from professional_service ps
                 where ps.pro_id_professional = v_pro_id
                   and ps.org_id_organization = v_org_id
                   and not exists (
                       select 1
                         from professional_service ps2
                        where ps2.pro_id_professional = v_existing_prof_id
                          and ps2.ser_id_service = ps.ser_id_service
                          and ps2.org_id_organization = ps.org_id_organization
                   );

                delete from professional_service
                 where pro_id_professional = v_pro_id
                   and org_id_organization = v_org_id;

                begin
                    pkg_aox_bucket.pr_delete_profile_image(v_pro_id);
                exception
                    when others then
                        null;
                end;

                delete from professional
                 where id_professional = v_pro_id
                   and org_id_organization = v_org_id;

                v_pro_id := v_existing_prof_id;
            else
                update professional
                   set usr_id_user = v_new_member_id,
                       is_active   = 1
                 where id_professional = v_pro_id
                   and org_id_organization = v_org_id;
            end if;
        else
            insert into org_member (
                platform_user_id,
                org_id_organization,
                rol_id_role,
                is_active
            ) values (
                v_platform_user_id,
                v_org_id,
                v_role_id,
                1
            ) returning id_org_member into v_new_member_id;

            update professional
               set usr_id_user = v_new_member_id,
                   is_active   = 1
             where id_professional = v_pro_id
               and org_id_organization = v_org_id;
        end if;

        update org_invitation
           set pro_id_professional = v_pro_id
         where id_org_invitation = v_invitation_id;

        update org_invitation
           set status = 'CANCELLED'
         where org_id_organization = v_org_id
           and lower(invite_email) = lower(trim(v_invite_email))
           and status = 'PENDING'
           and id_org_invitation <> v_invitation_id;

        update org_invitation
           set status = 'ACCEPTED',
               accepted_at = current_timestamp,
               platform_user_id = v_platform_user_id
         where id_org_invitation = v_invitation_id;

        commit;

        select pu.apex_user_name
          into v_session_username
          from platform_user pu
         where pu.id_platform_user = v_platform_user_id;

        pkg_aox_jwt.pr_generate_auth_tokens(
            pi_user_id       => v_new_member_id,
            pi_org_id        => v_org_id,
            pi_username      => v_session_username,
            pi_role_id       => v_role_id,
            po_access_token  => v_access_token,
            po_refresh_token => v_refresh_token
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Invitacion aceptada correctamente.');
        v_response_json.put('user_id', v_new_member_id);
        v_response_json.put('organization_id', v_org_id);
        v_response_json.put('access_token', v_access_token);
        v_response_json.put('refresh_token', v_refresh_token);
        v_response_json.put('expires_in', pkg_aox_util.fn_param_number('JWT_ACCESS_EXP_SEC', 3600));
        po_response_body := v_response_json.to_clob();
    exception
        when others then
            rollback;
            po_status_code := pkg_aox_util.c_internal_error_code;
            pr_error_handling('Error interno al aceptar la invitacion.', po_status_code, po_response_body);
    end pr_accept_invitation;

    procedure pr_validate_panel_session(
        pi_auth_header   in  varchar2,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_user_id        org_member.id_org_member%type;
        v_org_id         org_member.org_id_organization%type;
        v_role_id        org_member.rol_id_role%type;
        v_member_active  org_member.is_active%type;
        v_pu_active      platform_user.is_active%type;
        v_prof_exists    number := 0;
        v_response_json  json_object_t := json_object_t();
        v_admin_role_id  org_member.rol_id_role%type := pkg_aox_util.fn_rol('ADMIN');
        v_prof_role_id   org_member.rol_id_role%type := pkg_aox_util.fn_rol('PROFESIONAL');
    begin
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        begin
            select m.is_active,
                   pu.is_active
              into v_member_active,
                   v_pu_active
              from org_member m
              join platform_user pu
                on pu.id_platform_user = m.platform_user_id
             where m.id_org_member       = v_user_id
               and m.org_id_organization = v_org_id;
        exception
            when no_data_found then
                po_status_code := pkg_aox_util.c_unauthorized_code;
                v_response_json.put('status', 'error');
                v_response_json.put('code', pkg_aox_util.c_api_code_org_access_inactive);
                v_response_json.put(
                    'message',
                    'Tu acceso a esta organización ya no está disponible. Contactá al administrador.'
                );
                po_response_body := v_response_json.to_clob();
                return;
        end;

        if v_member_active = 0 or v_pu_active = 0 then
            po_status_code := pkg_aox_util.c_unauthorized_code;
            v_response_json.put('status', 'error');
            v_response_json.put('code', pkg_aox_util.c_api_code_org_access_inactive);
            v_response_json.put(
                'message',
                'Tu acceso a esta organización fue desactivado. Contactá al administrador si necesitás volver a ingresar.'
            );
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        if v_role_id = v_prof_role_id then
            begin
                select 1
                  into v_prof_exists
                  from professional p
                 where p.usr_id_user         = v_user_id
                   and p.org_id_organization = v_org_id;
            exception
                when no_data_found then
                    v_prof_exists := 0;
            end;

            if v_prof_exists = 0 then
                po_status_code := pkg_aox_util.c_unauthorized_code;
                v_response_json.put('status', 'error');
                v_response_json.put('code', pkg_aox_util.c_api_code_org_access_inactive);
                v_response_json.put(
                    'message',
                    'Tu perfil profesional en esta organización no está disponible. Contactá al administrador.'
                );
                po_response_body := v_response_json.to_clob();
                return;
            end if;
        elsif v_role_id = v_admin_role_id then
            null;
        end if;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('active', 1);
        po_response_body := v_response_json.to_clob();
    exception
        when others then
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    end pr_validate_panel_session;

end pkg_aox_auth_api;
/

