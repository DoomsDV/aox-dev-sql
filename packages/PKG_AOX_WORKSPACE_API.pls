PROMPT CREATE OR REPLACE PACKAGE pkg_aox_workspace_api
CREATE OR REPLACE PACKAGE pkg_aox_workspace_api IS

    -- Obtener la información del negocio (Workspace)
    PROCEDURE pr_get_workspace(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Actualizar la información del negocio (Solo Admin)
    PROCEDURE pr_update_workspace(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Validar disponibilidad de profile_slug del negocio (Solo Admin)
    PROCEDURE pr_check_profile_slug(
        pi_auth_header   IN  VARCHAR2,
        pi_slug          IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_workspace_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_workspace_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_workspace_api IS

    c_max_logo_base64_chars CONSTANT PLS_INTEGER := 10000000; -- aprox 7.5 MB binario

    function fn_get_optional_string(
        pi_json in json_object_t,
        pi_key  in varchar2
    ) return varchar2 is
        v_value varchar2(32767);
    begin
        if not pi_json.has(pi_key) then
            return null;
        end if;

        begin
            v_value := trim(pi_json.get_string(pi_key));
        exception
            when others then
                raise_application_error(-20004, 'El campo "' || pi_key || '" debe ser texto.');
        end;

        return v_value;
    end fn_get_optional_string;

    function fn_get_optional_number(
        pi_json in json_object_t,
        pi_key  in varchar2
    ) return number is
    begin
        if not pi_json.has(pi_key) then
            return null;
        end if;

        begin
            return pi_json.get_number(pi_key);
        exception
            when others then
                raise_application_error(-20004, 'El campo "' || pi_key || '" debe ser numérico.');
        end;
    end fn_get_optional_number;

    procedure pr_put_ref_catalogs(
        po_org_obj in out json_object_t
    ) is
        v_catalogs      json_object_t := json_object_t();
        v_slot_arr      json_array_t  := json_array_t();
        v_reminder_arr  json_array_t  := json_array_t();
        v_cancel_arr    json_array_t  := json_array_t();
        v_item          json_object_t;
    begin
        for rec in (
            select id_slot_interval, minutes_value, label
              from ref_booking_slot_interval
             where is_active = 1
             order by sort_order, minutes_value
        ) loop
            v_item := json_object_t();
            v_item.put('id', rec.id_slot_interval);
            v_item.put('minutes', rec.minutes_value);
            v_item.put('label', rec.label);
            v_slot_arr.append(v_item);
        end loop;

        for rec in (
            select id_reminder_hours, hours_value, label
              from ref_reminder_hours
             where is_active = 1
             order by sort_order, hours_value
        ) loop
            v_item := json_object_t();
            v_item.put('id', rec.id_reminder_hours);
            v_item.put('hours', rec.hours_value);
            v_item.put('label', rec.label);
            v_reminder_arr.append(v_item);
        end loop;

        for rec in (
            select id_cancel_wait_hours, hours_value, label
              from ref_cancel_wait_hours
             where is_active = 1
             order by sort_order, hours_value
        ) loop
            v_item := json_object_t();
            v_item.put('id', rec.id_cancel_wait_hours);
            v_item.put('hours', rec.hours_value);
            v_item.put('label', rec.label);
            v_cancel_arr.append(v_item);
        end loop;

        v_catalogs.put('slot_intervals', v_slot_arr);
        v_catalogs.put('reminder_hours', v_reminder_arr);
        v_catalogs.put('cancel_wait_hours', v_cancel_arr);
        po_org_obj.put('catalogs', v_catalogs);
    end pr_put_ref_catalogs;

    procedure pr_validate_system_timing(
        pi_reminder_hours_id     in number,
        pi_cancel_wait_hours_id  in number,
        pi_unanswered_alert_action in varchar2
    ) is
        v_reminder_h number;
        v_cancel_h   number;
        v_action     varchar2(20) := upper(nvl(pi_unanswered_alert_action, 'KEEP'));
    begin
        if pi_reminder_hours_id is null then
            raise_application_error(-20005, 'Debe seleccionar el tiempo de recordatorio.');
        end if;

        begin
            select hours_value
              into v_reminder_h
              from ref_reminder_hours
             where id_reminder_hours = pi_reminder_hours_id
               and is_active = 1;
        exception
            when no_data_found then
                raise_application_error(-20005, 'Tiempo de recordatorio no válido.');
        end;

        if v_action = 'CANCEL' then
            if pi_cancel_wait_hours_id is null then
                raise_application_error(-20005, 'Debe seleccionar el tiempo de espera para cancelar.');
            end if;

            begin
                select hours_value
                  into v_cancel_h
                  from ref_cancel_wait_hours
                 where id_cancel_wait_hours = pi_cancel_wait_hours_id
                   and is_active = 1;
            exception
                when no_data_found then
                    raise_application_error(-20005, 'Tiempo de espera para cancelar no válido.');
            end;

            if v_cancel_h >= v_reminder_h then
                raise_application_error(
                    -20005,
                    'El tiempo de espera para cancelar debe ser menor que el tiempo de recordatorio.'
                );
            end if;
        end if;
    end pr_validate_system_timing;

    function fn_resolve_slot_interval_id(
        pi_org_id in number
    ) return number is
        v_id number;
    begin
        select ws.rsi_id_slot_interval
          into v_id
          from workspace_setting ws
         where ws.org_id_organization = pi_org_id;

        return v_id;
    exception
        when no_data_found then
            select id_slot_interval
              into v_id
              from ref_booking_slot_interval
             where minutes_value = 30
               and is_active = 1
             fetch first 1 row only;
            return v_id;
    end fn_resolve_slot_interval_id;

    function fn_get_optional_clob(
        pi_json in json_object_t,
        pi_key  in varchar2
    ) return clob is
        v_value clob;
    begin
        if not pi_json.has(pi_key) then
            return null;
        end if;

        begin
            v_value := pi_json.get_clob(pi_key);
        exception
            when others then
                raise_application_error(-20004, 'El campo "' || pi_key || '" debe ser texto.');
        end;

        return v_value;
    end fn_get_optional_clob;

    -- 1) GET /workspace
    procedure pr_get_workspace(
        pi_auth_header   in  varchar2,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_org_id                  number;
        v_id_organization         organization.id_organization%type;
        v_name                    organization.name%type;

        -- variables de settings
        v_profile_slug            workspace_setting.profile_slug%type;
        v_description             workspace_setting.description%type;
        v_public_whatsapp         workspace_setting.public_whatsapp%type;
        v_logo_url                workspace_setting.logo_url%type;
        v_time_format             workspace_setting.time_format%type;
        v_theme_pref              workspace_setting.theme_pref%type;
        v_hidden_public_price_label workspace_setting.hidden_public_price_label%type;
        v_unanswered_alert_action workspace_setting.unanswered_alert_action%TYPE;
        v_rsi_id_slot_interval    workspace_setting.rsi_id_slot_interval%type;
        v_rh_id_reminder_hours    workspace_setting.rh_id_reminder_hours%type;
        v_cwh_id_cancel_wait      workspace_setting.cwh_id_cancel_wait_hours%type;
        v_slot_minutes            ref_booking_slot_interval.minutes_value%type;
        v_reminder_hours          ref_reminder_hours.hours_value%type;
        v_cancel_wait_hours       ref_cancel_wait_hours.hours_value%type;
        v_user_id                 number;
        v_notify_all_professionals org_member.notify_all_professionals%type;

        v_response_json           json_object_t := json_object_t();
        v_org_obj                 json_object_t := json_object_t();
    begin
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        if nvl(v_org_id, 0) <= 0 then
            raise_application_error(-20001, 'Token inválido o sin organización asociada.');
        end if;

        select
            o.id_organization,
            o.name,
            ws.profile_slug,
            ws.description,
            ws.public_whatsapp,
            ws.logo_url,
            nvl(ws.time_format, '24H'),
            nvl(ws.theme_pref, 'light'),
            nvl(nullif(trim(ws.hidden_public_price_label), ''), 'A evaluar'),
            nvl(ws.unanswered_alert_action, 'KEEP'),
            ws.rsi_id_slot_interval,
            ws.rh_id_reminder_hours,
            ws.cwh_id_cancel_wait_hours,
            rsi.minutes_value,
            rh.hours_value,
            cwh.hours_value
        into
            v_id_organization,
            v_name,
            v_profile_slug,
            v_description,
            v_public_whatsapp,
            v_logo_url,
            v_time_format,
            v_theme_pref,
            v_hidden_public_price_label,
            v_unanswered_alert_action,
            v_rsi_id_slot_interval,
            v_rh_id_reminder_hours,
            v_cwh_id_cancel_wait,
            v_slot_minutes,
            v_reminder_hours,
            v_cancel_wait_hours
        from organization o
        left join workspace_setting ws
            on o.id_organization = ws.org_id_organization
        left join ref_booking_slot_interval rsi
            on rsi.id_slot_interval = ws.rsi_id_slot_interval
        left join ref_reminder_hours rh
            on rh.id_reminder_hours = ws.rh_id_reminder_hours
        left join ref_cancel_wait_hours cwh
            on cwh.id_cancel_wait_hours = ws.cwh_id_cancel_wait_hours
        where o.id_organization = v_org_id;

        begin
            select nvl(m.notify_all_professionals, 'N')
              into v_notify_all_professionals
              from org_member m
             where m.id_org_member = v_user_id
               and m.org_id_organization = v_org_id;
        exception
            when no_data_found then
                v_notify_all_professionals := 'N';
        end;

        v_org_obj.put('id_organization'         , v_id_organization);
        v_org_obj.put('name'                    , v_name);
        v_org_obj.put('profile_slug'            , v_profile_slug);
        v_org_obj.put('description'             , v_description);
        v_org_obj.put('public_whatsapp'         , v_public_whatsapp);
        v_org_obj.put('logo_url'                , NVL(v_logo_url, ''));
        v_org_obj.put('time_format'             , v_time_format);
        v_org_obj.put('theme_pref'              , v_theme_pref);
        v_org_obj.put('hidden_public_price_label', v_hidden_public_price_label);
        v_org_obj.put('unanswered_alert_action' , v_unanswered_alert_action);
        v_org_obj.put('rsi_id_slot_interval'    , v_rsi_id_slot_interval);
        v_org_obj.put('rh_id_reminder_hours'    , v_rh_id_reminder_hours);
        v_org_obj.put('cwh_id_cancel_wait_hours', v_cwh_id_cancel_wait);
        v_org_obj.put('booking_slot_interval_minutes', nvl(v_slot_minutes, 30));
        v_org_obj.put('reminder_hours_before'   , nvl(v_reminder_hours, 24));
        v_org_obj.put('cancel_wait_hours'       , v_cancel_wait_hours);
        v_org_obj.put('notify_all_professionals', v_notify_all_professionals);

        pr_put_ref_catalogs(v_org_obj);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_org_obj);
        po_response_body := v_response_json.to_clob();

    exception
        when no_data_found then
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'Organización no encontrada.',
                po_response_body => po_response_body
            );

        when others then
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    end pr_get_workspace;

    -- 2) PUT /workspace
    procedure pr_update_workspace(
        pi_auth_header   in  varchar2,
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_org_id                        number;
        v_role_id                       number;
        v_user_id                       number;
        v_json_req                      json_object_t;
        v_response_json                 json_object_t := json_object_t();

        v_name                          organization.name%type;
        v_profile_slug                  workspace_setting.profile_slug%type;
        v_description                   workspace_setting.description%type;
        v_public_whatsapp               workspace_setting.public_whatsapp%type;
        v_time_format                   workspace_setting.time_format%type;
        v_theme_pref                    workspace_setting.theme_pref%type;
        v_hidden_public_price_label     workspace_setting.hidden_public_price_label%type;
        v_unanswered_alert_action       workspace_setting.unanswered_alert_action%type;
        v_rsi_id_slot_interval          workspace_setting.rsi_id_slot_interval%type;
        v_rh_id_reminder_hours          workspace_setting.rh_id_reminder_hours%type;
        v_cwh_id_cancel_wait_hours      workspace_setting.cwh_id_cancel_wait_hours%type;
        v_notify_all_professionals      org_member.notify_all_professionals%type;
        v_current_rsi_id                workspace_setting.rsi_id_slot_interval%type;
        v_current_rh_id                 workspace_setting.rh_id_reminder_hours%type;
        v_current_cwh_id                workspace_setting.cwh_id_cancel_wait_hours%type;
        v_current_alert_action          workspace_setting.unanswered_alert_action%type;
        v_effective_rsi_id              workspace_setting.rsi_id_slot_interval%type;
        v_effective_rh_id               workspace_setting.rh_id_reminder_hours%type;
        v_effective_cwh_id              workspace_setting.cwh_id_cancel_wait_hours%type;
        v_effective_alert_action        workspace_setting.unanswered_alert_action%type;

        v_has_unanswered_alert_action   pls_integer := 0;
        v_has_name                      pls_integer := 0;
        v_has_profile_slug              pls_integer := 0;
        v_has_description               pls_integer := 0;
        v_has_public_whatsapp           pls_integer := 0;
        v_has_timezone                  pls_integer := 0;
        v_has_time_format               pls_integer := 0;
        v_has_theme_pref                pls_integer := 0;
        v_has_hidden_public_price_label pls_integer := 0;
        v_has_rsi_id_slot_interval      pls_integer := 0;
        v_has_rh_id_reminder_hours      pls_integer := 0;
        v_has_cwh_id_cancel_wait        pls_integer := 0;
        v_has_notify_all_professionals  pls_integer := 0;

        v_logo_base64                   clob;
        v_logo_name                     varchar2(255);
        v_logo_mime                     varchar2(100);
        v_logo_blob                     blob;
    begin
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        if nvl(v_role_id, 0) <> 1 then
            raise_application_error(pkg_aox_util.c_sqlcode_forbidden, 'Acceso denegado. Solo el administrador puede modificar el perfil del negocio.');
        end if;

        if pi_body is null or dbms_lob.getlength(pi_body) = 0 then
            raise_application_error(-20003, 'JSON inválido o vacío.');
        end if;

        begin
            v_json_req := json_object_t.parse(pi_body);
        exception
            when others then
                raise_application_error(-20003, 'JSON inválido o malformado.');
        end;

        if v_json_req.has('name') THEN
            v_has_name := 1;
        end if;
        if v_json_req.has('profile_slug') THEN
            v_has_profile_slug := 1;
        end if;
        if v_json_req.has('description') THEN
            v_has_description := 1;
        end if;
        if v_json_req.has('public_whatsapp') then
            v_has_public_whatsapp := 1;
        end if;
        if v_json_req.has('time_format') then
            v_has_time_format := 1;
        end if;
        if v_json_req.has('theme_pref') then
            v_has_theme_pref := 1;
        end if;
        if v_json_req.has('hidden_public_price_label') then
            v_has_hidden_public_price_label := 1;
        end if;
        if v_json_req.has('unanswered_alert_action') then
            v_has_unanswered_alert_action := 1;
        end if;
        if v_json_req.has('rsi_id_slot_interval') then
            v_has_rsi_id_slot_interval := 1;
        end if;
        if v_json_req.has('rh_id_reminder_hours') then
            v_has_rh_id_reminder_hours := 1;
        end if;
        if v_json_req.has('cwh_id_cancel_wait_hours') then
            v_has_cwh_id_cancel_wait := 1;
        end if;
        if v_json_req.has('notify_all_professionals') then
            v_has_notify_all_professionals := 1;
        end if;

        v_name                    := fn_get_optional_string(v_json_req      , 'name');
        v_profile_slug            := fn_get_optional_string(v_json_req      , 'profile_slug');
        v_description             := fn_get_optional_string(v_json_req      , 'description');
        v_public_whatsapp         := fn_get_optional_string(v_json_req      , 'public_whatsapp');
        v_time_format             := fn_get_optional_string(v_json_req      , 'time_format');
        v_theme_pref              := fn_get_optional_string(v_json_req      , 'theme_pref');
        v_hidden_public_price_label := fn_get_optional_string(v_json_req, 'hidden_public_price_label');
        v_unanswered_alert_action := fn_get_optional_string(v_json_req      , 'unanswered_alert_action');
        v_rsi_id_slot_interval    := fn_get_optional_number(v_json_req      , 'rsi_id_slot_interval');
        v_rh_id_reminder_hours    := fn_get_optional_number(v_json_req      , 'rh_id_reminder_hours');
        v_cwh_id_cancel_wait_hours := fn_get_optional_number(v_json_req     , 'cwh_id_cancel_wait_hours');
        v_notify_all_professionals := upper(fn_get_optional_string(v_json_req, 'notify_all_professionals'));

        v_logo_base64             := fn_get_optional_clob(v_json_req        , 'logo_base64');
        v_logo_name               := fn_get_optional_string(v_json_req      , 'logo_name');
        v_logo_mime               := lower(fn_get_optional_string(v_json_req, 'logo_mime'));

        if v_has_name = 1 and v_name is null then
            raise_application_error(-20005, 'El nombre del negocio es obligatorio.');
        end if;

        if v_has_profile_slug = 1 then
            if v_profile_slug is null then
                raise_application_error(-20005, 'El slug público es obligatorio.');
            end if;

            v_profile_slug := lower(trim(v_profile_slug));
            v_profile_slug := pkg_aox_util.fn_generate_slug(v_profile_slug);

            if v_profile_slug is null then
                raise_application_error(-20005, 'El slug público es obligatorio.');
            end if;

            if pkg_aox_util.fn_is_reserved_org_slug(v_profile_slug) = 1 then
                raise_application_error(
                    -20005,
                    'Ese enlace publico esta reservado por el sistema. Elegi otro (por ejemplo, el nombre de tu negocio).'
                );
            end if;

            declare
                v_slug_taken pls_integer := 0;
            begin
                select count(*)
                  into v_slug_taken
                  from workspace_setting ws
                 where lower(trim(ws.profile_slug)) = v_profile_slug
                   and ws.org_id_organization <> v_org_id;

                if v_slug_taken > 0 then
                    raise_application_error(
                        -20005,
                        'Ese enlace publico ya esta en uso. Elegi otro.'
                    );
                end if;
            end;
        end if;

        if v_has_time_format = 1 then
            if v_time_format is null then
                raise_application_error(-20005, 'El formato de hora es obligatorio.');
            elsif v_time_format not in ('12H', '24H') then
                raise_application_error(-20005, 'time_format debe ser 12H o 24H.');
            end if;
        end if;

        if v_has_theme_pref = 1 then
            if v_theme_pref is null then
                raise_application_error(-20005, 'La preferencia de tema es obligatoria.');
            elsif lower(v_theme_pref) not in ('light', 'dark', 'system') THEN
                raise_application_error(-20005, 'theme_pref debe ser light, dark o system.');
            end if;
        end if;

        if v_has_hidden_public_price_label = 1 then
            if v_hidden_public_price_label is null then
                v_hidden_public_price_label := 'A evaluar';
            elsif length(v_hidden_public_price_label) > 80 then
                raise_application_error(-20005, 'El texto para precios ocultos no puede superar 80 caracteres.');
            end if;
        end if;

        if v_has_unanswered_alert_action = 1 then
            if v_unanswered_alert_action is null then
                raise_application_error(-20005, 'La acción para alertas no contestadas es obligatoria.');
            elsif upper(v_unanswered_alert_action) not in ('KEEP', 'CANCEL') then
                raise_application_error(-20005, 'unanswered_alert_action debe ser KEEP o CANCEL.');
            end if;
            v_unanswered_alert_action := upper(v_unanswered_alert_action);
        end if;

        if v_has_rsi_id_slot_interval = 1 and (v_rsi_id_slot_interval is null or v_rsi_id_slot_interval <= 0) then
            raise_application_error(-20005, 'Intervalo de reserva no válido.');
        end if;

        if v_has_rh_id_reminder_hours = 1 and (v_rh_id_reminder_hours is null or v_rh_id_reminder_hours <= 0) then
            raise_application_error(-20005, 'Tiempo de recordatorio no válido.');
        end if;

        if v_has_cwh_id_cancel_wait = 1 and v_cwh_id_cancel_wait_hours is not null and v_cwh_id_cancel_wait_hours <= 0 then
            raise_application_error(-20005, 'Tiempo de espera para cancelar no válido.');
        end if;

        if v_has_notify_all_professionals = 1 then
            if v_notify_all_professionals is null then
                raise_application_error(-20005, 'notify_all_professionals es obligatorio.');
            elsif v_notify_all_professionals not in ('Y', 'N') then
                raise_application_error(-20005, 'notify_all_professionals debe ser Y o N.');
            end if;
        end if;

        if (v_has_name + v_has_profile_slug + v_has_description + v_has_public_whatsapp +
           v_has_time_format + v_has_theme_pref + v_has_hidden_public_price_label +
           v_has_unanswered_alert_action +
           v_has_rsi_id_slot_interval + v_has_rh_id_reminder_hours + v_has_cwh_id_cancel_wait +
           v_has_notify_all_professionals) = 0
           and v_logo_base64 is null then
            raise_application_error(-20006, 'No se recibieron campos para actualizar.');
        end if;

        begin
            select ws.rsi_id_slot_interval,
                   ws.rh_id_reminder_hours,
                   ws.cwh_id_cancel_wait_hours,
                   nvl(ws.unanswered_alert_action, 'KEEP')
              into v_current_rsi_id,
                   v_current_rh_id,
                   v_current_cwh_id,
                   v_current_alert_action
              from workspace_setting ws
             where ws.org_id_organization = v_org_id;
        exception
            when no_data_found then
                v_current_rsi_id := null;
                v_current_rh_id := null;
                v_current_cwh_id := null;
                v_current_alert_action := 'KEEP';
        end;

        v_effective_rsi_id := case when v_has_rsi_id_slot_interval = 1 then v_rsi_id_slot_interval else v_current_rsi_id end;
        v_effective_rh_id := case when v_has_rh_id_reminder_hours = 1 then v_rh_id_reminder_hours else v_current_rh_id end;
        v_effective_alert_action := case when v_has_unanswered_alert_action = 1 then v_unanswered_alert_action else v_current_alert_action end;

        if v_effective_alert_action = 'CANCEL' then
            v_effective_cwh_id := case
                when v_has_cwh_id_cancel_wait = 1 then v_cwh_id_cancel_wait_hours
                else v_current_cwh_id
            end;
        else
            v_effective_cwh_id := null;
        end if;

        if v_has_rsi_id_slot_interval = 1
           or v_has_rh_id_reminder_hours = 1
           or v_has_cwh_id_cancel_wait = 1
           or v_has_unanswered_alert_action = 1 then
            if v_effective_rsi_id is null then
                select id_slot_interval
                  into v_effective_rsi_id
                  from ref_booking_slot_interval
                 where minutes_value = 30
                   and is_active = 1
                 fetch first 1 row only;
            else
                declare
                    v_dummy number;
                begin
                    select 1
                      into v_dummy
                      from ref_booking_slot_interval
                     where id_slot_interval = v_effective_rsi_id
                       and is_active = 1;
                exception
                    when no_data_found then
                        raise_application_error(-20005, 'Intervalo de reserva no válido.');
                end;
            end if;

            if v_effective_rh_id is null then
                select id_reminder_hours
                  into v_effective_rh_id
                  from ref_reminder_hours
                 where hours_value = 24
                   and is_active = 1
                 fetch first 1 row only;
            end if;

            pr_validate_system_timing(
                pi_reminder_hours_id       => v_effective_rh_id,
                pi_cancel_wait_hours_id    => v_effective_cwh_id,
                pi_unanswered_alert_action => v_effective_alert_action
            );
        end if;

        if v_has_unanswered_alert_action = 1 and v_effective_alert_action = 'KEEP' then
            v_cwh_id_cancel_wait_hours := null;
            v_has_cwh_id_cancel_wait := 1;
        end if;

        -- 1. Actualizar Nombre de la Organización (Datos Core)
        if v_has_name = 1 then
            update organization
               set name             = v_name
             where id_organization  = v_org_id;

            if sql%rowcount = 0 then
                raise_application_error(-20009, 'Organización no encontrada.');
            end if;
        end if;

        -- 2. Upsert (MERGE) en workspace_setting
        merge into workspace_setting ws
        using (select v_org_id as id_org from dual) src
        on (ws.org_id_organization = src.id_org)
        when matched then
            update set
                profile_slug    = case when v_has_profile_slug    = 1 then v_profile_slug else ws.profile_slug end,
                description     = case when v_has_description     = 1 then v_description else ws.description end,
                public_whatsapp = case when v_has_public_whatsapp = 1 then v_public_whatsapp else ws.public_whatsapp end,
                time_format     = case when v_has_time_format     = 1 then v_time_format else ws.time_format end,
                theme_pref      = case when v_has_theme_pref      = 1 then v_theme_pref else ws.theme_pref end,
                hidden_public_price_label = case
                    when v_has_hidden_public_price_label = 1 then v_hidden_public_price_label
                    else ws.hidden_public_price_label
                end,
                unanswered_alert_action = case when v_has_unanswered_alert_action = 1 then v_unanswered_alert_action else ws.unanswered_alert_action end,
                rsi_id_slot_interval = case when v_has_rsi_id_slot_interval = 1 then v_rsi_id_slot_interval else ws.rsi_id_slot_interval end,
                rh_id_reminder_hours = case when v_has_rh_id_reminder_hours = 1 then v_rh_id_reminder_hours else ws.rh_id_reminder_hours end,
                cwh_id_cancel_wait_hours = case when v_has_cwh_id_cancel_wait = 1 then v_cwh_id_cancel_wait_hours else ws.cwh_id_cancel_wait_hours end,
                updated_at      = current_timestamp
        when not matched then
            insert (
                org_id_organization,
                profile_slug,
                description,
                public_whatsapp,
                time_format,
                theme_pref,
                hidden_public_price_label,
                unanswered_alert_action,
                rsi_id_slot_interval,
                rh_id_reminder_hours,
                cwh_id_cancel_wait_hours
            )
            values (
                src.id_org,
                v_profile_slug,
                v_description,
                v_public_whatsapp,
                NVL(v_time_format, '24H'),
                NVL(v_theme_pref, 'light'),
                NVL(v_hidden_public_price_label, 'A evaluar'),
                NVL(v_unanswered_alert_action, 'KEEP'),
                NVL(v_rsi_id_slot_interval, (
                    SELECT id_slot_interval FROM ref_booking_slot_interval WHERE minutes_value = 30 AND is_active = 1 FETCH FIRST 1 ROW ONLY
                )),
                NVL(v_rh_id_reminder_hours, (
                    SELECT id_reminder_hours FROM ref_reminder_hours WHERE hours_value = 24 AND is_active = 1 FETCH FIRST 1 ROW ONLY
                )),
                CASE
                    WHEN NVL(v_unanswered_alert_action, 'KEEP') = 'CANCEL' THEN v_cwh_id_cancel_wait_hours
                    ELSE NULL
                END
            );

        -- Preferencia personal del admin: fan-out de pushes de otros profesionales
        if v_has_notify_all_professionals = 1 then
            update org_member m
               set m.notify_all_professionals = v_notify_all_professionals
             where m.id_org_member = v_user_id
               and m.org_id_organization = v_org_id
               and m.rol_id_role = 1;

            if sql%rowcount = 0 then
                raise_application_error(-20009, 'No se encontró el miembro administrador para actualizar la preferencia.');
            end if;
        end if;

        -- 3. Manejo del Logo
        if v_logo_base64 is not null then
            v_logo_base64 := REGEXP_REPLACE(v_logo_base64, '^\s*data:[^,]+,', '');

            if dbms_lob.getlength(v_logo_base64) = 0 then
                raise_application_error(-20007, 'El logo enviado está vacío.');
            end if;

            if dbms_lob.getlength(v_logo_base64) > c_max_logo_base64_chars then
                raise_application_error(-20007, 'El logo supera el tamaño máximo permitido.');
            end if;

            if v_logo_mime is null then
                v_logo_mime := 'image/png';
            end if;

            if v_logo_mime not in ('image/png', 'image/jpeg', 'image/jpg', 'image/webp', 'image/svg+xml') then
                raise_application_error(-20007, 'Tipo MIME de logo no permitido.');
            end if;

            begin
                v_logo_blob := apex_web_service.clobbase642blob(v_logo_base64);

                pkg_aox_bucket.pr_upload_org_logo(
                    pi_blob            => v_logo_blob,
                    pi_filename        => nvl(v_logo_name, 'logo_empresa.png'),
                    pi_mime_type       => v_logo_mime,
                    pi_id_organization => v_org_id
                );

                -- Actualizamos los metadatos del archivo en la configuración de la organización
                update workspace_setting
                   set logo_filename        = nvl(v_logo_name, 'logo_empresa.png'),
                       logo_mime_type       = v_logo_mime
                 where org_id_organization  = v_org_id;

                if v_logo_blob is not null and dbms_lob.istemporary(v_logo_blob) = 1 then
                    dbms_lob.freetemporary(v_logo_blob);
                end if;
            exception
                when others then
                    if v_logo_blob is not null and dbms_lob.istemporary(v_logo_blob) = 1 then
                        dbms_lob.freetemporary(v_logo_blob);
                    end if;
                    raise_application_error(-20008, 'No fue posible procesar o subir el logo.');
            end;
        end if;

        commit;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json := json_object_t();
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Configuración del negocio guardada correctamente.');
        po_response_body := v_response_json.to_clob();

    exception
        when others then
            rollback;

            po_status_code := case
                when sqlcode = pkg_aox_util.c_sqlcode_session then pkg_aox_util.c_unauthorized_code
                when sqlcode = pkg_aox_util.c_sqlcode_forbidden then pkg_aox_util.c_forbidden_code
                when sqlcode = -20009 then pkg_aox_util.c_not_found_code
                when sqlcode = -1 then pkg_aox_util.c_conflict_code
                when sqlcode in (-20003, -20004, -20005, -20006, -20007, -20008) then pkg_aox_util.c_bad_request_code
                else pkg_aox_util.c_internal_error_code
            end;

            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, sqlcode, sqlerrm),
                pi_message       => case
                    when sqlcode = pkg_aox_util.c_sqlcode_forbidden then 'No autorizado.'
                    when sqlcode = -1 then 'Ese enlace (slug) ya está siendo usado por otra clínica. Por favor, elige otro.'
                    when sqlcode = -20003 then 'JSON inválido o malformado.'
                    when sqlcode = -20006 then 'No se recibieron campos para actualizar.'
                    when sqlcode = -20008 then 'No fue posible procesar o subir el logo.'
                    when sqlcode = -20009 then 'Organización no encontrada.'
                    else pkg_aox_util.fn_clean_sqlerrm(sqlerrm)
                end,
                po_response_body => po_response_body
            );
    end pr_update_workspace;

    PROCEDURE pr_check_profile_slug(
        pi_auth_header   IN  VARCHAR2,
        pi_slug          IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_role_id       NUMBER;
        v_slug          VARCHAR2(100);
        v_taken         PLS_INTEGER := 0;
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();
    BEGIN
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF NVL(v_role_id, 0) <> 1 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'Acceso denegado. Solo el administrador puede validar el enlace del negocio.'
            );
        END IF;

        v_slug := LOWER(TRIM(pi_slug));
        IF v_slug IS NULL THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'El slug es obligatorio.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        v_slug := pkg_aox_util.fn_generate_slug(v_slug);
        IF v_slug IS NULL THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'El slug no es válido.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        IF pkg_aox_util.fn_is_reserved_org_slug(v_slug) = 1 THEN
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_data_obj.put('slug', v_slug);
            v_data_obj.put('available', FALSE);
            v_data_obj.put('reason', 'reserved');
            v_response_json.put('status', 'success');
            v_response_json.put('data', v_data_obj);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        SELECT COUNT(*)
          INTO v_taken
          FROM workspace_setting ws
         WHERE LOWER(TRIM(ws.profile_slug)) = v_slug
           AND ws.org_id_organization <> v_org_id;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_data_obj.put('slug', v_slug);
        IF v_taken > 0 THEN
            v_data_obj.put('available', FALSE);
            v_data_obj.put('reason', 'taken');
        ELSE
            v_data_obj.put('available', TRUE);
            v_data_obj.put('reason', 'ok');
        END IF;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_check_profile_slug;

END pkg_aox_workspace_api;
/

