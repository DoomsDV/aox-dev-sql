PROMPT CREATE OR REPLACE PACKAGE pkg_aox_util
CREATE OR REPLACE package pkg_aox_util as
/**
 * Paquete de utilidades transversales para el sistema AOX.
 * Incluye funciones de seguridad (VPD), hashing de contraseñas,
 * generación de SEO-friendly slugs y lógica de disponibilidad de agenda.
 *
 * @author Generado por Sistema
 * @version 1.0
 */
    c_success_create_code           constant number := 201;
    c_duplicate_email_code          constant number := 400;
    c_internal_error_code           constant number := 500;
    c_invalid_account_type_code     constant number := 422;
    c_success_ok_code               constant number := 200;
    c_bad_request_code              constant number := 400;
    c_unauthorized_code             constant number := 401;
    c_forbidden_code                constant number := 403;
    c_not_found_code                constant number := 404;
    c_conflict_code                 constant number := 409;

    /** Códigos de error API (JSON field "code") — alineados con bookmate/src/lib/session-auth-messages.ts */
    c_api_code_session_expired      constant varchar2(30) := 'SESSION_EXPIRED';
    c_api_code_org_access_inactive  constant varchar2(30) := 'ORG_ACCESS_INACTIVE';
    c_api_code_forbidden            constant varchar2(30) := 'FORBIDDEN';
    c_api_code_invalid_credentials  constant varchar2(30) := 'INVALID_CREDENTIALS';
    c_api_code_validation_error     constant varchar2(30) := 'VALIDATION_ERROR';
    c_api_code_not_found            constant varchar2(30) := 'NOT_FOUND';
    c_api_code_conflict             constant varchar2(30) := 'CONFLICT';
    c_api_code_internal_error       constant varchar2(30) := 'INTERNAL_ERROR';

    /** SQLCODE de aplicación: JWT/sesión (-20001), validación (-20002), permisos (-20011). */
    c_sqlcode_session               constant number := -20001;
    c_sqlcode_validation            constant number := -20002;
    c_sqlcode_forbidden             constant number := -20011;

    function fn_clean_sqlerrm(
        pi_sqlerrm in varchar2 default sqlerrm
    ) return varchar2;

    function fn_resolve_api_code(
        pi_status_code in number,
        pi_sqlcode     in number default sqlcode,
        pi_sqlerrm     in varchar2 default sqlerrm
    ) return varchar2;

    procedure pr_build_api_error_response(
        pi_status_code   in  number,
        pi_api_code      in  varchar2,
        pi_message       in  varchar2,
        po_response_body out clob
    );

    procedure pr_resolve_api_error(
        pi_sqlcode       in  number,
        pi_sqlerrm       in  varchar2,
        po_status_code   out number,
        po_api_code      out varchar2,
        po_message       out varchar2
    );

    procedure pr_handle_api_exception(
        po_status_code   out number,
        po_response_body out clob,
        pi_sqlcode       in  number default sqlcode,
        pi_sqlerrm       in  varchar2 default sqlerrm
    );

    /**
     * Convierte una cadena de texto en un "slug" apto para URLs.
     * Elimina acentos, caracteres especiales y reemplaza espacios por guiones.
     * @param pi_string Cadena de texto original.
     * @return varchar2 Cadena formateada (ej: "hola-mundo").
     */
    function fn_generate_slug (
        pi_string in varchar2
    ) return varchar2;

    /**
     * Indica si un slug de negocio choca con rutas estaticas del sitio
     * (panel, auth, api, u, ...). Retorna 1 si esta reservado, 0 si no.
     */
    function fn_is_reserved_org_slug (
        pi_slug in varchar2
    ) return number;

    /**
     * Genera un profile_slug de organizacion unico y no reservado a partir
     * del nombre del negocio. Si pi_exclude_org_id viene informado, ignora
     * el slug actual de esa org (para reasignaciones).
     */
    function fn_allocate_org_profile_slug (
        pi_source         in varchar2,
        pi_exclude_org_id in number default null
    ) return varchar2;

    /**
     * Slug publico global sugerido para platform_user (/u/{slug}).
     * Base: nombre + apellido normalizados; si pi_id_platform_user viene informado
     * y el base ya existe en otro usuario, agrega -{id}.
     */
    function fn_build_platform_user_public_slug (
        pi_first_name       in varchar2,
        pi_last_name        in varchar2,
        pi_id_platform_user in number default null
    ) return varchar2;

    /**
     * Función de política para Virtual Private Database (VPD).
     * Garantiza el aislamiento de datos entre Tenants (Organizaciones) en APEX.
     * @param pi_schema Esquema de la base de datos (pasado por Oracle).
     * @param pi_table  Nombre de la tabla a filtrar (pasado por Oracle).
     * @return varchar2 Predicado SQL (WHERE clause) para filtrar por org_id.
     */
    function fn_tenant_security_policy (
        pi_schema in varchar2,
        pi_table  in varchar2
    ) return varchar2;

    /**
     * Calcula los bloques de tiempo disponibles para una cita médica/profesional.
     * Utiliza una función PIPELINED para retornar resultados en tiempo real.
     * @param pi_pro_id      ID del profesional.
     * @param pi_loc_id      ID de la sucursal/ubicación.
     * @param pi_ser_id      ID del servicio a realizar (para determinar duración).
     * @param pi_target_date Fecha para la cual se consulta disponibilidad.
     * @return t_slot_tab    Tabla de registros con horas disponibles (HH24:MI).
     */
    function fn_get_available_slots (
        pi_pro_id       in number,
        pi_loc_id       in number,
        pi_ser_id       in number,
        pi_target_date  in date
    ) return t_slot_tab pipelined;

    /**
     * Tipo de excepcion de agenda para una fecha: NULL (usa plantilla), BLOCKED u OVERRIDE.
     */
    function fn_get_schedule_exception_type (
        pi_pro_id      in number,
        pi_target_date in date
    ) return varchar2;

    /**
     * Motivo de desalineacion: DAY_BLOCKED, TIME_OUTSIDE_SCHEDULE, WRONG_LOCATION.
     * NULL si la cita esta alineada con plantilla o excepcion OVERRIDE.
     */
    function fn_get_appointment_schedule_misaligned_reason (
        pi_pro_id      in number,
        pi_start_time  in timestamp,
        pi_end_time    in timestamp,
        pi_loc_id      in number
    ) return varchar2;

    /**
     * Indica si una cita activa coincide con la plantilla o excepcion OVERRIDE del dia.
     * Retorna 1 alineada, 0 desalineada (incluye dias BLOCKED).
     */
    function fn_is_appointment_schedule_aligned (
        pi_pro_id      in number,
        pi_start_time  in timestamp,
        pi_end_time    in timestamp,
        pi_loc_id      in number
    ) return number;

    /**
     * Cuenta citas futuras PENDIENTE/CONFIRMADO que quedarian desalineadas
     * si se aplicara la plantilla semanal enviada en pi_new_schedules.
     */
    function fn_count_template_impact_appointments (
        pi_pro_id        in number,
        pi_org_id        in number,
        pi_new_schedules in json_array_t
    ) return number;

    /** Minutos entre slots publicos segun workspace (default 30). */
    function fn_get_org_booking_slot_minutes (
        pi_org_id in number
    ) return number;

    /** Horas antes del turno para enviar recordatorio (default 24). */
    function fn_get_org_reminder_hours (
        pi_org_id in number
    ) return number;

    /** Horas de espera tras recordatorio antes de cancelar (default 3). */
    function fn_get_org_cancel_wait_hours (
        pi_org_id in number
    ) return number;

    /**
     * Genera un hash seguro utilizando el algoritmo SHA-256.
     * @param pi_password Contraseña en texto plano.
     * @return varchar2   Representación hexadecimal del hash.
     */
    function fn_hash_password (
        pi_password in varchar2
    ) return varchar2;

    FUNCTION fn_get_org_id_from_jwt(
      pi_auth_header IN VARCHAR2
    ) RETURN NUMBER;

    FUNCTION fn_get_role_id_from_jwt(
      pi_auth_header IN VARCHAR2
    ) RETURN NUMBER;

    FUNCTION fn_get_user_id_from_jwt(
      pi_auth_header IN VARCHAR2
    ) RETURN NUMBER;

    -- Encripta un texto usando AES-256
    FUNCTION fn_encrypt_data(
        pi_text IN VARCHAR2
    ) RETURN VARCHAR2;

    -- Desencripta un texto hexadecimal usando AES-256
    FUNCTION fn_decrypt_data(
        pi_encrypted_hex IN VARCHAR2
    ) RETURN VARCHAR2;

    FUNCTION fn_rol(
        pi_name IN ROLE.name%type
    ) RETURN ROLE.id_role%TYPE;

    FUNCTION fn_app_timezone RETURN VARCHAR2;

    FUNCTION fn_param_number(
        pi_param_key IN VARCHAR2,
        pi_default   IN NUMBER DEFAULT NULL
    ) RETURN NUMBER;

    PROCEDURE pr_log_whatsapp_template(
        pi_process_name    IN VARCHAR2,
        pi_appointment_id  IN NUMBER DEFAULT NULL,
        pi_template_name   IN VARCHAR2 DEFAULT NULL,
        pi_phone_number    IN VARCHAR2 DEFAULT NULL,
        pi_status          IN VARCHAR2 DEFAULT NULL,
        pi_status_code     IN NUMBER DEFAULT NULL,
        pi_error_code      IN NUMBER DEFAULT NULL,
        pi_error_message   IN VARCHAR2 DEFAULT NULL,
        pi_error_stack     IN CLOB DEFAULT NULL,
        pi_error_backtrace IN CLOB DEFAULT NULL,
        pi_request_payload IN CLOB DEFAULT NULL,
        pi_response_body   IN CLOB DEFAULT NULL,
        pi_parameters      IN CLOB DEFAULT NULL
    );

    PROCEDURE pr_log_push_fcm(
        pi_process_name    IN VARCHAR2,
        pi_fcm_token       IN VARCHAR2 DEFAULT NULL,
        pi_title           IN VARCHAR2 DEFAULT NULL,
        pi_body            IN VARCHAR2 DEFAULT NULL,
        pi_status          IN VARCHAR2 DEFAULT NULL,
        pi_status_code     IN NUMBER DEFAULT NULL,
        pi_error_code      IN NUMBER DEFAULT NULL,
        pi_error_message   IN VARCHAR2 DEFAULT NULL,
        pi_error_stack     IN CLOB DEFAULT NULL,
        pi_error_backtrace IN CLOB DEFAULT NULL,
        pi_request_payload IN CLOB DEFAULT NULL,
        pi_response_body   IN CLOB DEFAULT NULL,
        pi_parameters      IN CLOB DEFAULT NULL
    );

    PROCEDURE pr_log_api(
        pi_api_name        IN VARCHAR2,
        pi_process_name    IN VARCHAR2,
        pi_http_method     IN VARCHAR2 DEFAULT NULL,
        pi_endpoint        IN VARCHAR2 DEFAULT NULL,
        pi_org_id          IN NUMBER DEFAULT NULL,
        pi_user_id         IN NUMBER DEFAULT NULL,
        pi_status          IN VARCHAR2 DEFAULT NULL,
        pi_status_code     IN NUMBER DEFAULT NULL,
        pi_error_code      IN NUMBER DEFAULT NULL,
        pi_error_message   IN VARCHAR2 DEFAULT NULL,
        pi_error_stack     IN CLOB DEFAULT NULL,
        pi_error_backtrace IN CLOB DEFAULT NULL,
        pi_request_body    IN CLOB DEFAULT NULL,
        pi_request_params  IN CLOB DEFAULT NULL,
        pi_response_body   IN CLOB DEFAULT NULL
    );

    PROCEDURE pr_log_ai(
        pi_process_name    IN VARCHAR2,
        pi_session_id      IN NUMBER DEFAULT NULL,
        pi_org_id          IN NUMBER DEFAULT NULL,
        pi_user_id         IN NUMBER DEFAULT NULL,
        pi_role_id         IN NUMBER DEFAULT NULL,
        pi_pro_id          IN NUMBER DEFAULT NULL,
        pi_status          IN VARCHAR2 DEFAULT NULL,
        pi_status_code     IN NUMBER DEFAULT NULL,
        pi_error_code      IN NUMBER DEFAULT NULL,
        pi_error_message   IN VARCHAR2 DEFAULT NULL,
        pi_error_stack     IN CLOB DEFAULT NULL,
        pi_error_backtrace IN CLOB DEFAULT NULL,
        pi_prompt          IN CLOB DEFAULT NULL,
        pi_request_payload IN CLOB DEFAULT NULL,
        pi_response_body   IN CLOB DEFAULT NULL,
        pi_parameters      IN CLOB DEFAULT NULL
    );

end pkg_aox_util;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_util
CREATE OR REPLACE package body pkg_aox_util as

    FUNCTION fn_app_timezone RETURN VARCHAR2 IS
    BEGIN
        RETURN NVL(fn_get_parameter('APP_TIMEZONE'), 'America/Asuncion');
    END fn_app_timezone;

    FUNCTION fn_param_number(
        pi_param_key IN VARCHAR2,
        pi_default   IN NUMBER DEFAULT NULL
    ) RETURN NUMBER IS
    BEGIN
        RETURN NVL(TO_NUMBER(fn_get_parameter(pi_param_key)), pi_default);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN pi_default;
    END fn_param_number;

    function fn_generate_slug (
        pi_string in varchar2
    ) return varchar2 is
        v_slug varchar2(200);
    begin
        -- Normalización: Minúsculas y limpieza de tildes
        v_slug := lower(pi_string);
        v_slug := translate(v_slug, 'áéíóúäëïöüñ', 'aeiouaeioun');
        -- Reemplazo de caracteres no alfanuméricos por guion
        v_slug := regexp_replace(v_slug, '[^a-z0-9]+', '-');
        -- Eliminación de guiones sobrantes en los extremos
        v_slug := trim(both '-' from v_slug);
        return v_slug;
    end fn_generate_slug;

    function fn_is_reserved_org_slug (
        pi_slug in varchar2
    ) return number is
        v_slug varchar2(200) := lower(trim(pi_slug));
    begin
        if v_slug is null then
            return 0;
        end if;

        return case
            when v_slug in (
                'panel',
                'auth',
                'api',
                'u',
                'r',
                'p',
                'pagopar',
                'reserva-exitosa',
                'politicas-y-privacidad',
                'politicas-de-cancelacion-y-reembolso',
                'icons',
                'assets',
                'static',
                'admin',
                'login',
                'register',
                'hasel',
                'bookmate',
                'www',
                'app',
                'support',
                'help',
                'pricing',
                'blog',
                'docs',
                'sitemap',
                'robots',
                'favicon',
                '_astro'
            ) then 1
            else 0
        end;
    end fn_is_reserved_org_slug;

    function fn_allocate_org_profile_slug (
        pi_source         in varchar2,
        pi_exclude_org_id in number default null
    ) return varchar2 is
        v_base      varchar2(200);
        v_candidate varchar2(200);
        v_n         pls_integer := 0;
        v_exists    pls_integer := 0;
    begin
        v_base := fn_generate_slug(pi_source);
        if v_base is null or length(v_base) = 0 then
            v_base := 'negocio';
        end if;

        -- Dejar margen para sufijo -NNNN
        if length(v_base) > 90 then
            v_base := substr(v_base, 1, 90);
            v_base := trim(both '-' from v_base);
            if v_base is null or length(v_base) = 0 then
                v_base := 'negocio';
            end if;
        end if;

        loop
            if v_n = 0 then
                v_candidate := v_base;
            else
                v_candidate := v_base || '-' || to_char(v_n);
            end if;

            if fn_is_reserved_org_slug(v_candidate) = 0 then
                select count(*)
                  into v_exists
                  from workspace_setting ws
                 where lower(trim(ws.profile_slug)) = lower(v_candidate)
                   and (pi_exclude_org_id is null
                        or ws.org_id_organization <> pi_exclude_org_id);

                if v_exists = 0 then
                    return v_candidate;
                end if;
            end if;

            v_n := v_n + 1;
            if v_n > 9999 then
                raise_application_error(
                    -20005,
                    'No fue posible generar un enlace publico unico para el negocio.'
                );
            end if;
        end loop;
    end fn_allocate_org_profile_slug;

    function fn_build_platform_user_public_slug (
        pi_first_name         in varchar2,
        pi_last_name          in varchar2,
        pi_id_platform_user   in number default null
    ) return varchar2 is
        v_base   varchar2(200);
        v_final  varchar2(200);
        v_count  number;
        v_pu_id  number := nvl(pi_id_platform_user, 0);
        v_source varchar2(400);
    begin
        v_source := trim(pi_first_name);
        if pi_last_name is not null and trim(pi_last_name) is not null then
            v_source := trim(v_source || ' ' || trim(pi_last_name));
        end if;

        v_base := fn_generate_slug(v_source);

        if v_base is null then
            if v_pu_id > 0 then
                return 'usuario-' || v_pu_id;
            end if;
            return 'usuario';
        end if;

        v_final := v_base;

        if v_pu_id > 0 then
            select count(*)
              into v_count
              from platform_user pu
             where lower(trim(pu.public_slug)) = lower(trim(v_final))
               and pu.id_platform_user <> v_pu_id;

            if v_count > 0 then
                v_final := v_base || '-' || v_pu_id;
            end if;
        end if;

        return v_final;
    end fn_build_platform_user_public_slug;

    function fn_tenant_security_policy (
        pi_schema in varchar2,
        pi_table  in varchar2
    ) return varchar2
    is
        v_tenant_id number;
        v_predicate varchar2(400);
    begin
        -- Obtención del Tenant ID desde la sesión de APEX (Application Item)
        v_tenant_id := to_number(v('APP_ORG_ID'));

        -- Si no hay sesión activa, bloqueamos el acceso por seguridad (1=2)
        if v_tenant_id is not null then
            v_predicate := 'org_id_organization = ' || v_tenant_id;
        else
            v_predicate := '1=2';
        end if;

        return v_predicate;
    end fn_tenant_security_policy;

    function fn_get_schedule_exception_type (
        pi_pro_id      in number,
        pi_target_date in date
    ) return varchar2 is
        v_type professional_schedule_exception.exception_type%type;
    begin
        select e.exception_type
        into v_type
        from professional_schedule_exception e
        where e.pro_id_professional = pi_pro_id
          and e.exception_date = trunc(pi_target_date);

        return v_type;
    exception
        when no_data_found then
            return null;
    end fn_get_schedule_exception_type;

    function fn_get_appointment_schedule_misaligned_reason (
        pi_pro_id      in number,
        pi_start_time  in timestamp,
        pi_end_time    in timestamp,
        pi_loc_id      in number
    ) return varchar2 is
        v_target_date     date;
        v_exception_type  varchar2(20);
        v_day_of_week     number;
        v_app_start       varchar2(5);
        v_app_end         varchar2(5);
        v_match_count     number;
        v_other_loc_count number;
    begin
        v_target_date := trunc(pi_start_time);
        v_app_start := to_char(pi_start_time, 'HH24:MI');
        v_app_end := to_char(pi_end_time, 'HH24:MI');

        v_exception_type := fn_get_schedule_exception_type(pi_pro_id, v_target_date);

        if v_exception_type = 'BLOCKED' then
            return 'DAY_BLOCKED';
        end if;

        if v_exception_type = 'OVERRIDE' then
            select count(*)
              into v_match_count
              from professional_schedule_exception_slot s
              join professional_schedule_exception e
                on e.id_schedule_exception = s.exc_id_schedule_exception
             where e.pro_id_professional = pi_pro_id
               and e.exception_date = v_target_date
               and e.exception_type = 'OVERRIDE'
               and s.loc_id_location = pi_loc_id
               and v_app_start < s.end_time
               and v_app_end > s.start_time;

            if v_match_count > 0 then
                return null;
            end if;

            select count(*)
              into v_other_loc_count
              from professional_schedule_exception_slot s
              join professional_schedule_exception e
                on e.id_schedule_exception = s.exc_id_schedule_exception
             where e.pro_id_professional = pi_pro_id
               and e.exception_date = v_target_date
               and e.exception_type = 'OVERRIDE'
               and s.loc_id_location <> pi_loc_id
               and v_app_start < s.end_time
               and v_app_end > s.start_time;

            if v_other_loc_count > 0 then
                return 'WRONG_LOCATION';
            end if;

            return 'TIME_OUTSIDE_SCHEDULE';
        end if;

        v_day_of_week := v_target_date - trunc(v_target_date, 'IW') + 1;

        select count(*)
          into v_match_count
          from professional_schedule ps
         where ps.pro_id_professional = pi_pro_id
           and ps.loc_id_location = pi_loc_id
           and ps.day_of_week = v_day_of_week
           and v_app_start < ps.end_time
           and v_app_end > ps.start_time;

        if v_match_count > 0 then
            return null;
        end if;

        select count(*)
          into v_other_loc_count
          from professional_schedule ps
         where ps.pro_id_professional = pi_pro_id
           and ps.loc_id_location <> pi_loc_id
           and ps.day_of_week = v_day_of_week
           and v_app_start < ps.end_time
           and v_app_end > ps.start_time;

        if v_other_loc_count > 0 then
            return 'WRONG_LOCATION';
        end if;

        return 'TIME_OUTSIDE_SCHEDULE';
    end fn_get_appointment_schedule_misaligned_reason;

    function fn_is_appointment_schedule_aligned (
        pi_pro_id      in number,
        pi_start_time  in timestamp,
        pi_end_time    in timestamp,
        pi_loc_id      in number
    ) return number is
    begin
        return case
            when fn_get_appointment_schedule_misaligned_reason(
                pi_pro_id, pi_start_time, pi_end_time, pi_loc_id
            ) is null then 1
            else 0
        end;
    end fn_is_appointment_schedule_aligned;

    function fn_appt_fits_new_template_json (
        pi_pro_id        in number,
        pi_start_time    in timestamp,
        pi_end_time      in timestamp,
        pi_loc_id        in number,
        pi_new_schedules in json_array_t
    ) return number is
        v_target_date     date;
        v_exception_type  varchar2(20);
        v_day_of_week     number;
        v_app_start       varchar2(5);
        v_app_end         varchar2(5);
        v_match_count     number;
        v_slot_item       json_object_t;
        v_slot_loc        number;
        v_slot_day        number;
        v_slot_start      varchar2(5);
        v_slot_end        varchar2(5);
        v_idx             number;
    begin
        v_target_date := trunc(pi_start_time);
        v_app_start := to_char(pi_start_time, 'HH24:MI');
        v_app_end := to_char(pi_end_time, 'HH24:MI');

        v_exception_type := fn_get_schedule_exception_type(pi_pro_id, v_target_date);

        if v_exception_type = 'BLOCKED' then
            return 0;
        end if;

        if v_exception_type = 'OVERRIDE' then
            select count(*)
              into v_match_count
              from professional_schedule_exception_slot s
              join professional_schedule_exception e
                on e.id_schedule_exception = s.exc_id_schedule_exception
             where e.pro_id_professional = pi_pro_id
               and e.exception_date = v_target_date
               and e.exception_type = 'OVERRIDE'
               and s.loc_id_location = pi_loc_id
               and v_app_start < s.end_time
               and v_app_end > s.start_time;

            return case when v_match_count > 0 then 1 else 0 end;
        end if;

        if pi_new_schedules is null or pi_new_schedules.get_size() = 0 then
            return 0;
        end if;

        v_day_of_week := v_target_date - trunc(v_target_date, 'IW') + 1;

        for v_idx in 0 .. pi_new_schedules.get_size() - 1 loop
            v_slot_item := json_object_t(pi_new_schedules.get(v_idx));
            v_slot_loc := v_slot_item.get_number('loc_id_location');
            v_slot_day := v_slot_item.get_number('day_of_week');
            v_slot_start := v_slot_item.get_string('start_time');
            v_slot_end := v_slot_item.get_string('end_time');

            if v_slot_day = v_day_of_week
               and v_slot_loc = pi_loc_id
               and v_app_start < v_slot_end
               and v_app_end > v_slot_start then
                return 1;
            end if;
        end loop;

        return 0;
    end fn_appt_fits_new_template_json;

    function fn_count_template_impact_appointments (
        pi_pro_id        in number,
        pi_org_id        in number,
        pi_new_schedules in json_array_t
    ) return number is
        v_impact_count number := 0;
    begin
        for rec in (
            select a.start_time, a.end_time, a.loc_id_location
              from appointment a
             where a.pro_id_professional = pi_pro_id
               and a.org_id_organization = pi_org_id
               and a.status in ('PENDIENTE', 'CONFIRMADO')
               and trunc(a.start_time) >= trunc(sysdate)
        ) loop
            if fn_appt_fits_new_template_json(
                pi_pro_id,
                rec.start_time,
                rec.end_time,
                rec.loc_id_location,
                pi_new_schedules
            ) = 0 then
                v_impact_count := v_impact_count + 1;
            end if;
        end loop;

        return v_impact_count;
    end fn_count_template_impact_appointments;

    function fn_get_available_slots (
        pi_pro_id       in number,
        pi_loc_id       in number,
        pi_ser_id       in number,
        pi_target_date  in date
    ) return t_slot_tab pipelined
    is
        v_day_of_week       number;
        v_service_duration  number;
        v_work_start        timestamp;
        v_work_end          timestamp;
        v_current_slot      timestamp;
        v_slot_end          timestamp;
        v_overlap_count     number;
        v_step_minutes      number;
        v_org_id            number;
        v_exception_type    varchar2(20);
        v_target_trunc      date := trunc(pi_target_date);
    begin
        begin
            select p.org_id_organization
              into v_org_id
              from professional p
             where p.id_professional = pi_pro_id;
        exception
            when no_data_found then
                v_org_id := null;
        end;

        v_step_minutes := fn_get_org_booking_slot_minutes(v_org_id);

        -- 1. Obtención de duración del servicio y validación de competencia profesional
        begin
            select s.duration_minutes
            into v_service_duration
            from service s
            join professional_service ps on s.id_service = ps.ser_id_service
            where ps.pro_id_professional = pi_pro_id
              and s.id_service           = pi_ser_id;
        exception
            when no_data_found then return; -- El profesional no realiza este servicio
        end;

        v_exception_type := fn_get_schedule_exception_type(pi_pro_id, v_target_trunc);

        if v_exception_type = 'BLOCKED' then
            return;
        end if;

        -- ISO Day: 1 (Lunes) a 7 (Domingo)
        v_day_of_week := v_target_trunc - trunc(v_target_trunc, 'IW') + 1;

        -- 2. Bloques laborales: excepcion OVERRIDE o plantilla semanal
        for rec in (
            select s.start_time, s.end_time
            from professional_schedule_exception_slot s
            join professional_schedule_exception e
              on e.id_schedule_exception = s.exc_id_schedule_exception
            where e.pro_id_professional = pi_pro_id
              and e.exception_date = v_target_trunc
              and e.exception_type = 'OVERRIDE'
              and s.loc_id_location = pi_loc_id
            union all
            select ps.start_time, ps.end_time
            from professional_schedule ps
            where ps.pro_id_professional = pi_pro_id
              and ps.loc_id_location = pi_loc_id
              and ps.day_of_week = v_day_of_week
              and v_exception_type is null
        ) loop
            v_work_start := to_timestamp(to_char(pi_target_date, 'YYYY-MM-DD') || ' ' || rec.start_time, 'YYYY-MM-DD HH24:MI');
            v_work_end   := to_timestamp(to_char(pi_target_date, 'YYYY-MM-DD') || ' ' || rec.end_time, 'YYYY-MM-DD HH24:MI');
            v_current_slot := v_work_start;

            -- 3. Generación iterativa de bloques según duración del servicio
            while v_current_slot + numtodsinterval(v_service_duration, 'MINUTE') <= v_work_end loop
                v_slot_end := v_current_slot + numtodsinterval(v_service_duration, 'MINUTE');

                -- 4. Validación de colisiones contra la tabla de citas existentes
                select count(*)
                into v_overlap_count
                from appointment
                where pro_id_professional = pi_pro_id
                  and trunc(start_time)   = trunc(pi_target_date)
                  and status != 'CANCELADO'
                  and (
                        (v_current_slot >= start_time and v_current_slot < end_time)  or
                        (v_slot_end     >  start_time and v_slot_end     <= end_time) or
                        (v_current_slot <= start_time and v_slot_end     >= end_time)
                  );

                -- Si no hay cruce de horarios, el bloque está disponible
                if v_overlap_count = 0 then
                    pipe row(t_slot_rec(to_char(v_current_slot, 'HH24:MI')));
                end if;

                v_current_slot := v_current_slot + numtodsinterval(v_step_minutes, 'MINUTE');
            end loop;
        end loop;

        return;
    end fn_get_available_slots;

    function fn_hash_password (
        pi_password in varchar2
    ) return varchar2 is
        v_hash raw(256);
    begin
        -- Uso de DBMS_CRYPTO para generación de Hash SHA-2 (SHA-256)
        -- El valor '4' corresponde a la constante DBMS_CRYPTO.HASH_SH256
        v_hash := dbms_crypto.hash(utl_i18n.string_to_raw(pi_password, 'AL32UTF8'), 4);

        return lower(rawtohex(v_hash));
    end fn_hash_password;

    FUNCTION fn_get_org_id_from_jwt(pi_auth_header IN VARCHAR2) RETURN NUMBER IS
        v_token         VARCHAR2(32767);
        v_org_id        NUMBER;
        v_jwt_secret    RAW(256) := UTL_RAW.CAST_TO_RAW(fn_get_parameter('JWT_TOKEN'));

        -- Variables para manejar la función apex_jwt.decode
        v_decoded_token apex_jwt.t_token;
        v_payload_json  json_object_t;
    BEGIN
        -- 1. Limpiar la palabra "Bearer " de la cabecera
        v_token := regexp_replace(pi_auth_header, '^Bearer ', '', 1, 1, 'i');

        IF v_token IS NULL OR TRIM(v_token) = '' THEN
            RAISE_APPLICATION_ERROR(c_sqlcode_session, 'Token no proporcionado.');
        END IF;

        BEGIN
            -- 2. Decodificar el token (esto valida la firma con p_signature_key)
            v_decoded_token := apex_jwt.decode(
                p_value         => v_token,
                p_signature_key => v_jwt_secret
            );

            -- 3. Parsear el payload (que es un string de JSON) a un objeto manipulable
            v_payload_json := json_object_t.parse(v_decoded_token.payload);

            -- 4. Extraer el claim de la organización
            v_org_id := v_payload_json.get_number('organization_id');

            IF v_org_id IS NULL THEN
                RAISE_APPLICATION_ERROR(c_sqlcode_session, 'Falta identificador de organización en el token.');
            END IF;

        EXCEPTION
            WHEN OTHERS THEN
                -- Si el token fue alterado, la firma es inválida, o falló el parseo
                RAISE_APPLICATION_ERROR(c_sqlcode_session, 'Token inválido o alterado1.');
        END;

        RETURN v_org_id;
    END fn_get_org_id_from_jwt;

    FUNCTION fn_get_role_id_from_jwt(pi_auth_header IN VARCHAR2) RETURN NUMBER IS
        v_token         VARCHAR2(32767);
        v_jwt_secret    RAW(256) := UTL_RAW.CAST_TO_RAW(fn_get_parameter('JWT_TOKEN'));
        v_decoded_token apex_jwt.t_token;
        v_payload_json  json_object_t;
        v_role_id       NUMBER;
    BEGIN
        v_token := REGEXP_REPLACE(pi_auth_header, '^Bearer ', '', 1, 1, 'i');
        v_decoded_token := apex_jwt.decode(p_value => v_token, p_signature_key => v_jwt_secret);
        v_payload_json  := json_object_t.parse(v_decoded_token.payload);
        v_role_id       := v_payload_json.get_number('role_id');

        IF v_role_id IS NULL THEN RAISE_APPLICATION_ERROR(c_sqlcode_session, 'Falta rol en el token.'); END IF;
        RETURN v_role_id;
    EXCEPTION
        WHEN OTHERS THEN RAISE_APPLICATION_ERROR(c_sqlcode_session, 'Token inválido o expirado2.');
    END fn_get_role_id_from_jwt;

    FUNCTION fn_get_user_id_from_jwt(pi_auth_header IN VARCHAR2) RETURN NUMBER IS
        v_token         VARCHAR2(32767);
        v_jwt_secret    RAW(256) := UTL_RAW.CAST_TO_RAW(fn_get_parameter('JWT_TOKEN'));
        v_decoded_token apex_jwt.t_token;
        v_payload_json  json_object_t;
        v_user_id       NUMBER;
    BEGIN
        v_token := REGEXP_REPLACE(pi_auth_header, '^Bearer ', '', 1, 1, 'i');
        v_decoded_token := apex_jwt.decode(p_value => v_token, p_signature_key => v_jwt_secret);
        v_payload_json  := json_object_t.parse(v_decoded_token.payload);
        v_user_id       := v_payload_json.get_number('user_id');

        IF v_user_id IS NULL THEN RAISE_APPLICATION_ERROR(c_sqlcode_session, 'Falta identificador de usuario en el token.'); END IF;
        RETURN v_user_id;
    EXCEPTION
        WHEN OTHERS THEN RAISE_APPLICATION_ERROR(c_sqlcode_session, 'Token inválido o expirado.');
    END fn_get_user_id_from_jwt;

    FUNCTION fn_encrypt_data(pi_text IN VARCHAR2) RETURN VARCHAR2 IS
        -- Obtenemos una clave secreta de 32 caracteres de tu tabla de parámetros
        v_key RAW(32) := UTL_RAW.CAST_TO_RAW(fn_get_parameter('HASEL_SECRET_KEY'));
        v_encrypted RAW(4000);
    BEGIN
        IF pi_text IS NULL THEN RETURN NULL; END IF;

        -- Encriptamos usando AES256 con encadenamiento CBC y padding PKCS5
        v_encrypted := DBMS_CRYPTO.ENCRYPT(
            src => UTL_I18N.STRING_TO_RAW(pi_text, 'AL32UTF8'),
            typ => DBMS_CRYPTO.ENCRYPT_AES256 + DBMS_CRYPTO.CHAIN_CBC + DBMS_CRYPTO.PAD_PKCS5,
            key => v_key
        );

        -- Retornamos el valor en Hexadecimal para poder guardarlo en tu VARCHAR2(4000)
        RETURN RAWTOHEX(v_encrypted);
    END fn_encrypt_data;

    FUNCTION fn_decrypt_data(pi_encrypted_hex IN VARCHAR2) RETURN VARCHAR2 IS
        v_key RAW(32) := UTL_RAW.CAST_TO_RAW(fn_get_parameter('HASEL_SECRET_KEY'));
        v_decrypted RAW(4000);
    BEGIN
        IF pi_encrypted_hex IS NULL THEN RETURN NULL; END IF;

        v_decrypted := DBMS_CRYPTO.DECRYPT(
            src => HEXTORAW(pi_encrypted_hex),
            typ => DBMS_CRYPTO.ENCRYPT_AES256 + DBMS_CRYPTO.CHAIN_CBC + DBMS_CRYPTO.PAD_PKCS5,
            key => v_key
        );

        -- Convertimos el RAW desencriptado de vuelta a texto legible
        RETURN UTL_I18N.RAW_TO_CHAR(v_decrypted, 'AL32UTF8');
    END fn_decrypt_data;

    FUNCTION fn_rol(
        pi_name IN ROLE.name%type
    ) RETURN ROLE.id_role%TYPE IS
        v_id_role ROLE.id_role%TYPE;
    BEGIN
        SELECT
            id_role
        INTO
            v_id_role
        FROM ROLE
        WHERE name = pi_name;

        RETURN v_id_role;
    EXCEPTION
        WHEN No_Data_Found THEN
            Raise_Application_Error(-20999,'No se encontró el rol especificado.');
    END;

    PROCEDURE pr_log_whatsapp_template(
        pi_process_name    IN VARCHAR2,
        pi_appointment_id  IN NUMBER,
        pi_template_name   IN VARCHAR2,
        pi_phone_number    IN VARCHAR2,
        pi_status          IN VARCHAR2,
        pi_status_code     IN NUMBER,
        pi_error_code      IN NUMBER,
        pi_error_message   IN VARCHAR2,
        pi_error_stack     IN CLOB,
        pi_error_backtrace IN CLOB,
        pi_request_payload IN CLOB,
        pi_response_body   IN CLOB,
        pi_parameters      IN CLOB
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO aox_whatsapp_template_log (
            process_name,
            appointment_id,
            template_name,
            phone_number,
            status,
            status_code,
            error_code,
            error_message,
            error_stack,
            error_backtrace,
            request_payload,
            response_body,
            parameters
        ) VALUES (
            SUBSTR(pi_process_name, 1, 200),
            pi_appointment_id,
            SUBSTR(pi_template_name, 1, 120),
            SUBSTR(pi_phone_number, 1, 50),
            SUBSTR(pi_status, 1, 30),
            pi_status_code,
            pi_error_code,
            SUBSTR(pi_error_message, 1, 4000),
            pi_error_stack,
            pi_error_backtrace,
            pi_request_payload,
            pi_response_body,
            pi_parameters
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
    END pr_log_whatsapp_template;

    PROCEDURE pr_log_push_fcm(
        pi_process_name    IN VARCHAR2,
        pi_fcm_token       IN VARCHAR2,
        pi_title           IN VARCHAR2,
        pi_body            IN VARCHAR2,
        pi_status          IN VARCHAR2,
        pi_status_code     IN NUMBER,
        pi_error_code      IN NUMBER,
        pi_error_message   IN VARCHAR2,
        pi_error_stack     IN CLOB,
        pi_error_backtrace IN CLOB,
        pi_request_payload IN CLOB,
        pi_response_body   IN CLOB,
        pi_parameters      IN CLOB
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO aox_push_fcm_log (
            process_name,
            fcm_token,
            title,
            message_body,
            status,
            status_code,
            error_code,
            error_message,
            error_stack,
            error_backtrace,
            request_payload,
            response_body,
            parameters
        ) VALUES (
            SUBSTR(pi_process_name, 1, 200),
            pi_fcm_token,
            SUBSTR(pi_title, 1, 500),
            SUBSTR(pi_body, 1, 4000),
            SUBSTR(pi_status, 1, 30),
            pi_status_code,
            pi_error_code,
            SUBSTR(pi_error_message, 1, 4000),
            pi_error_stack,
            pi_error_backtrace,
            pi_request_payload,
            pi_response_body,
            pi_parameters
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
    END pr_log_push_fcm;

    PROCEDURE pr_log_api(
        pi_api_name        IN VARCHAR2,
        pi_process_name    IN VARCHAR2,
        pi_http_method     IN VARCHAR2,
        pi_endpoint        IN VARCHAR2,
        pi_org_id          IN NUMBER,
        pi_user_id         IN NUMBER,
        pi_status          IN VARCHAR2,
        pi_status_code     IN NUMBER,
        pi_error_code      IN NUMBER,
        pi_error_message   IN VARCHAR2,
        pi_error_stack     IN CLOB,
        pi_error_backtrace IN CLOB,
        pi_request_body    IN CLOB,
        pi_request_params  IN CLOB,
        pi_response_body   IN CLOB
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO aox_api_log (
            api_name,
            process_name,
            http_method,
            endpoint,
            org_id,
            user_id,
            status,
            status_code,
            error_code,
            error_message,
            error_stack,
            error_backtrace,
            request_body,
            request_params,
            response_body
        ) VALUES (
            SUBSTR(pi_api_name, 1, 200),
            SUBSTR(pi_process_name, 1, 200),
            SUBSTR(pi_http_method, 1, 20),
            SUBSTR(pi_endpoint, 1, 500),
            pi_org_id,
            pi_user_id,
            SUBSTR(pi_status, 1, 30),
            pi_status_code,
            pi_error_code,
            SUBSTR(pi_error_message, 1, 4000),
            pi_error_stack,
            pi_error_backtrace,
            pi_request_body,
            pi_request_params,
            pi_response_body
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
    END pr_log_api;

    PROCEDURE pr_log_ai(
        pi_process_name    IN VARCHAR2,
        pi_session_id      IN NUMBER,
        pi_org_id          IN NUMBER,
        pi_user_id         IN NUMBER,
        pi_role_id         IN NUMBER,
        pi_pro_id          IN NUMBER,
        pi_status          IN VARCHAR2,
        pi_status_code     IN NUMBER,
        pi_error_code      IN NUMBER,
        pi_error_message   IN VARCHAR2,
        pi_error_stack     IN CLOB,
        pi_error_backtrace IN CLOB,
        pi_prompt          IN CLOB,
        pi_request_payload IN CLOB,
        pi_response_body   IN CLOB,
        pi_parameters      IN CLOB
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO aox_ai_log (
            process_name,
            session_id,
            org_id,
            user_id,
            role_id,
            pro_id,
            status,
            status_code,
            error_code,
            error_message,
            error_stack,
            error_backtrace,
            prompt,
            request_payload,
            response_body,
            parameters
        ) VALUES (
            SUBSTR(pi_process_name, 1, 200),
            pi_session_id,
            pi_org_id,
            pi_user_id,
            pi_role_id,
            pi_pro_id,
            SUBSTR(pi_status, 1, 30),
            pi_status_code,
            pi_error_code,
            SUBSTR(pi_error_message, 1, 4000),
            pi_error_stack,
            pi_error_backtrace,
            pi_prompt,
            pi_request_payload,
            pi_response_body,
            pi_parameters
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
    END pr_log_ai;

    function fn_get_org_booking_slot_minutes (
        pi_org_id in number
    ) return number is
        v_minutes number;
    begin
        if nvl(pi_org_id, 0) <= 0 then
            return fn_param_number('SLOT_SEARCH_STEP_MINUTES', 30);
        end if;

        select rsi.minutes_value
          into v_minutes
          from workspace_setting ws
          join ref_booking_slot_interval rsi
            on rsi.id_slot_interval = ws.rsi_id_slot_interval
         where ws.org_id_organization = pi_org_id
           and rsi.is_active = 1;

        return nvl(v_minutes, fn_param_number('SLOT_SEARCH_STEP_MINUTES', 30));
    exception
        when no_data_found then
            return fn_param_number('SLOT_SEARCH_STEP_MINUTES', 30);
    end fn_get_org_booking_slot_minutes;

    function fn_get_org_reminder_hours (
        pi_org_id in number
    ) return number is
        v_hours number;
    begin
        if nvl(pi_org_id, 0) <= 0 then
            return 24;
        end if;

        select rh.hours_value
          into v_hours
          from workspace_setting ws
          join ref_reminder_hours rh
            on rh.id_reminder_hours = ws.rh_id_reminder_hours
         where ws.org_id_organization = pi_org_id
           and rh.is_active = 1;

        return nvl(v_hours, 24);
    exception
        when no_data_found then
            return 24;
    end fn_get_org_reminder_hours;

    function fn_get_org_cancel_wait_hours (
        pi_org_id in number
    ) return number is
        v_hours number;
    begin
        if nvl(pi_org_id, 0) <= 0 then
            return fn_param_number('META_ATTENDANCE_REPLY_HOURS', 3);
        end if;

        select cwh.hours_value
          into v_hours
          from workspace_setting ws
          join ref_cancel_wait_hours cwh
            on cwh.id_cancel_wait_hours = ws.cwh_id_cancel_wait_hours
         where ws.org_id_organization = pi_org_id
           and cwh.is_active = 1
           and nvl(ws.unanswered_alert_action, 'KEEP') = 'CANCEL';

        return nvl(v_hours, fn_param_number('META_ATTENDANCE_REPLY_HOURS', 3));
    exception
        when no_data_found then
            return fn_param_number('META_ATTENDANCE_REPLY_HOURS', 3);
    end fn_get_org_cancel_wait_hours;

    function fn_clean_sqlerrm(
        pi_sqlerrm in varchar2 default sqlerrm
    ) return varchar2 is
    begin
        return trim(regexp_replace(pi_sqlerrm, '^ORA-[0-9]+: ', ''));
    end fn_clean_sqlerrm;

    function fn_message_is_permission_denied(
        pi_message in varchar2
    ) return boolean is
        v_msg varchar2(4000);
    begin
        v_msg := lower(fn_clean_sqlerrm(pi_message));
        if v_msg is null then
            return false;
        end if;
        if v_msg in ('no autorizado.', 'no autorizado') then
            return true;
        end if;
        if instr(v_msg, 'solo el administrador') > 0
           or instr(v_msg, 'solo el admin') > 0 then
            return true;
        end if;
        if instr(v_msg, 'acceso denegado') > 0
           and instr(v_msg, 'token') = 0 then
            return true;
        end if;
        if instr(v_msg, 'no tienes permisos') > 0
           or instr(v_msg, 'no tiene permisos') > 0 then
            return true;
        end if;
        if instr(v_msg, 'no tienes permiso') > 0 then
            return true;
        end if;
        return false;
    end fn_message_is_permission_denied;

    function fn_message_is_invalid_credentials(
        pi_message in varchar2
    ) return boolean is
        v_msg varchar2(4000);
    begin
        v_msg := lower(fn_clean_sqlerrm(pi_message));
        return instr(v_msg, 'credenciales') > 0
            or instr(v_msg, 'contraseña incorrect') > 0
            or instr(v_msg, 'contrasena incorrect') > 0
            or instr(v_msg, 'usuario o contrase') > 0;
    end fn_message_is_invalid_credentials;

    function fn_resolve_api_code(
        pi_status_code in number,
        pi_sqlcode     in number default sqlcode,
        pi_sqlerrm     in varchar2 default sqlerrm
    ) return varchar2 is
        v_msg varchar2(4000) := fn_clean_sqlerrm(pi_sqlerrm);
    begin
        if pi_status_code = c_unauthorized_code then
            if fn_message_is_invalid_credentials(v_msg) then
                return c_api_code_invalid_credentials;
            end if;
            if fn_message_is_permission_denied(v_msg) then
                return c_api_code_forbidden;
            end if;
            return c_api_code_session_expired;
        elsif pi_status_code = c_forbidden_code then
            return c_api_code_forbidden;
        elsif pi_status_code = c_not_found_code then
            return c_api_code_not_found;
        elsif pi_status_code = c_conflict_code then
            return c_api_code_conflict;
        elsif pi_status_code = c_bad_request_code
           or pi_status_code = c_invalid_account_type_code then
            return c_api_code_validation_error;
        elsif pi_status_code = c_internal_error_code then
            return c_api_code_internal_error;
        end if;

        if pi_sqlcode = c_sqlcode_forbidden then
            return c_api_code_forbidden;
        elsif pi_sqlcode = c_sqlcode_session then
            if fn_message_is_invalid_credentials(v_msg) then
                return c_api_code_invalid_credentials;
            end if;
            if fn_message_is_permission_denied(v_msg) then
                return c_api_code_forbidden;
            end if;
            return c_api_code_session_expired;
        elsif pi_sqlcode = c_sqlcode_validation then
            return c_api_code_validation_error;
        end if;

        return c_api_code_internal_error;
    end fn_resolve_api_code;

    procedure pr_build_api_error_response(
        pi_status_code   in  number,
        pi_api_code      in  varchar2,
        pi_message       in  varchar2,
        po_response_body out clob
    ) is
        v_json json_object_t := json_object_t();
    begin
        v_json.put('status', 'error');
        v_json.put('code', nvl(trim(pi_api_code), c_api_code_internal_error));
        v_json.put('message', nvl(trim(pi_message), 'Error interno del servidor.'));
        po_response_body := v_json.to_clob();
    end pr_build_api_error_response;

    procedure pr_resolve_api_error(
        pi_sqlcode       in  number,
        pi_sqlerrm       in  varchar2,
        po_status_code   out number,
        po_api_code      out varchar2,
        po_message       out varchar2
    ) is
        v_msg varchar2(4000) := fn_clean_sqlerrm(pi_sqlerrm);
    begin
        po_message := v_msg;

        if pi_sqlcode = c_sqlcode_forbidden then
            po_status_code := c_forbidden_code;
            po_api_code    := c_api_code_forbidden;
            return;
        end if;

        if pi_sqlcode = c_sqlcode_session then
            if fn_message_is_invalid_credentials(v_msg) then
                po_status_code := c_unauthorized_code;
                po_api_code    := c_api_code_invalid_credentials;
                return;
            end if;
            if fn_message_is_permission_denied(v_msg) then
                po_status_code := c_forbidden_code;
                po_api_code    := c_api_code_forbidden;
                return;
            end if;
            po_status_code := c_unauthorized_code;
            po_api_code    := c_api_code_session_expired;
            return;
        end if;

        if pi_sqlcode = c_sqlcode_validation then
            po_status_code := c_bad_request_code;
            po_api_code    := c_api_code_validation_error;
            return;
        end if;

        if pi_sqlcode = -20004 then
            po_status_code := c_not_found_code;
            po_api_code    := c_api_code_not_found;
            return;
        end if;

        if pi_sqlcode = -20005 then
            po_status_code := c_forbidden_code;
            po_api_code    := c_api_code_forbidden;
            return;
        end if;

        if pi_sqlcode = -2292 then
            po_status_code := c_conflict_code;
            po_api_code    := c_api_code_conflict;
            return;
        end if;

        po_status_code := c_internal_error_code;
        po_api_code    := c_api_code_internal_error;
        if po_message is null or po_message = '' then
            po_message := 'Error interno del servidor.';
        end if;
    end pr_resolve_api_error;

    procedure pr_handle_api_exception(
        po_status_code   out number,
        po_response_body out clob,
        pi_sqlcode       in  number default sqlcode,
        pi_sqlerrm       in  varchar2 default sqlerrm
    ) is
        v_api_code varchar2(30);
        v_message  varchar2(4000);
    begin
        pr_resolve_api_error(pi_sqlcode, pi_sqlerrm, po_status_code, v_api_code, v_message);
        v_api_code := fn_resolve_api_code(po_status_code, pi_sqlcode, pi_sqlerrm);
        pr_build_api_error_response(po_status_code, v_api_code, v_message, po_response_body);
    end pr_handle_api_exception;

end pkg_aox_util;
/

