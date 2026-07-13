PROMPT CREATE OR REPLACE PACKAGE pkg_aox_bucket
CREATE OR REPLACE package pkg_aox_bucket AS
    -- NUEVA VERSIÓN: Para consumir desde ORDS (API REST)
    procedure pr_upload_profile_image(
        pi_blob            in blob,
        pi_filename        in varchar2,
        pi_mime_type       in varchar2,
        pi_id_professional in professional_image.pro_id_professional%type,
        pi_id_organization in organization.id_organization%type default null
    );

    procedure pr_upload_profile_image(
        pi_profile_file     in varchar2,
        pi_id_professional  in professional_image.pro_id_professional%type,
        pi_id_organization  in organization.id_organization%type default null
    );

    procedure pr_delete_profile_image(
        pi_id_professional in professional_image.pro_id_professional%type
    );

    -- NUEVA FUNCIÓN: Para el logo del Workspace (Organización)
    procedure pr_upload_org_logo(
        pi_blob            in blob,
        pi_filename        in varchar2,
        pi_mime_type       in varchar2,
        pi_id_organization in organization.id_organization%type
    );

    procedure pr_delete_org_logo(
        pi_id_organization in organization.id_organization%type
    );

    procedure pr_upload_platform_user_avatar(
        pi_blob              in blob,
        pi_filename          in varchar2,
        pi_mime_type         in varchar2,
        pi_id_platform_user  in platform_user.id_platform_user%type
    );

    procedure pr_delete_platform_user_avatar(
        pi_id_platform_user in platform_user.id_platform_user%type
    );

    -- Historial de cita (Fase 4): adjuntos con paywall de storage.
    -- Gatea feature APPOINTMENT_HISTORY, valida escritura y limite de bytes de la org.
    procedure pr_upload_appointment_attachment(
        pi_blob             in blob,
        pi_filename         in varchar2,
        pi_mime_type        in varchar2,
        pi_org_id           in organization.id_organization%type,
        pi_app_id           in appointment.id_appointment%type,
        pi_user_id          in number default null,
        po_attachment_id    out number,
        po_url              out varchar2
    );

    procedure pr_delete_appointment_attachment(
        pi_org_id        in organization.id_organization%type,
        pi_attachment_id in appointment_attachment.id_attachment%type
    );

    -- Fase B2: comprobante SIPAP. Path ordenado para auditoria / RGPD.
    -- organizations/{org_id}/payments/{yyyy}/{mm}/{customer_id}/{receipt_id}.{ext}
    procedure pr_upload_payment_receipt(
        pi_blob          in blob,
        pi_filename      in varchar2,
        pi_mime_type     in varchar2,
        pi_org_id        in organization.id_organization%type,
        pi_customer_id   in customer.id_customer%type,
        pi_receipt_id    in number,
        po_url           out varchar2,
        po_object_key    out varchar2
    );

    -- KB global ATC (sin org): platform/atc-kb/{document_id}/{filename}
    procedure pr_upload_atc_kb_document(
        pi_blob         in blob,
        pi_filename     in varchar2,
        pi_mime_type    in varchar2,
        pi_document_id  in number,
        po_url          out varchar2,
        po_object_key   out varchar2
    );

    procedure pr_delete_atc_kb_document(
        pi_object_key in varchar2
    );

    function fn_download_atc_kb_document(
        pi_storage_url in varchar2
    ) return blob;
end;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_bucket
CREATE OR REPLACE package body pkg_aox_bucket as

    g_base_url          app_parameter.param_value%type := fn_get_parameter('OCI_BUCKET_BASE_URL');
    g_credential        app_parameter.param_value%type := fn_get_parameter('OCI_CREDENTIAL_NAME');
    g_url               varchar2(3000);

    c_organizations_dir constant varchar2(30) := 'organizations/';
    c_users_dir         constant varchar2(30) := 'users/';
    c_logos_dir         constant varchar2(30) := 'logos/';
    c_platform_users_dir constant varchar2(30) := 'platform_users/';
    c_appointments_dir  constant varchar2(30) := 'appointments/';
    c_payments_dir      constant varchar2(30) := 'payments/';
    c_atc_kb_dir        constant varchar2(30) := 'platform/atc-kb/';

    function fn_build_platform_user_asset_url(
        pi_id_platform_user in platform_user.id_platform_user%type,
        pi_file_name        in varchar2
    ) return varchar2 is
    begin
        return rtrim(g_base_url, '/')
            || '/'
            || c_platform_users_dir
            || pi_id_platform_user
            || '/'
            || pi_file_name;
    end fn_build_platform_user_asset_url;

    function fn_safe_file_name(pi_filename in varchar2) return varchar2 is
        v_file_name varchar2(255);
    begin
        v_file_name := substr(nvl(trim(pi_filename), 'archivo'), 1, 180);
        v_file_name := replace(replace(v_file_name, '/', '_'), '\', '_');
        v_file_name := regexp_replace(v_file_name, '[^[:alnum:]_.-]', '_');

        return v_file_name;
    end fn_safe_file_name;

    function fn_get_professional_org_id(
        pi_id_professional in professional_image.pro_id_professional%type,
        pi_id_organization in organization.id_organization%type
    ) return organization.id_organization%type is
        v_id_organization organization.id_organization%type;
    begin
        if nvl(pi_id_organization, 0) > 0 then
            return pi_id_organization;
        end if;

        select org_id_organization
        into v_id_organization
        from professional
        where id_professional = pi_id_professional;

        return v_id_organization;
    end fn_get_professional_org_id;

    function fn_build_org_asset_url(
        pi_id_organization in organization.id_organization%type,
        pi_folder          in varchar2,
        pi_file_name       in varchar2
    ) return varchar2 is
    begin
        return rtrim(g_base_url, '/')
            || '/'
            || c_organizations_dir
            || pi_id_organization
            || '/'
            || pi_folder
            || pi_file_name;
    end fn_build_org_asset_url;

    -- NUEVA VERSIÓN: Implementación directa con BLOB
    procedure pr_upload_profile_image(
        pi_blob            in blob,
        pi_filename        in varchar2,
        pi_mime_type       in varchar2,
        pi_id_professional in professional_image.pro_id_professional%type,
        pi_id_organization in organization.id_organization%type
    ) is
        v_file_name        varchar2(255);
        v_id_organization  organization.id_organization%type;
        v_response         clob;
        v_status_code      number;
    begin
        v_id_organization := fn_get_professional_org_id(pi_id_professional, pi_id_organization);
        pr_delete_profile_image(pi_id_professional);

        -- Limpiamos fotos anteriores en la BD
        delete from professional_image
        where pro_id_professional = pi_id_professional;

        -- Modificamos el nombre para que sea único
        v_file_name := TO_CHAR(CURRENT_DATE, 'YYYYMMDD_HH24MISS') || '_' || fn_safe_file_name(pi_filename);

        -- Guardamos el registro en la tabla
        insert into professional_image (
            pro_id_professional, file_name, mime_type
        ) values (
            pi_id_professional, v_file_name, pi_mime_type
        );

        -- Estructura bucket: organizations/{org_id}/users/{archivo}
        g_url := fn_build_org_asset_url(v_id_organization, c_users_dir, v_file_name);

        -- Llamada REST a OCI
        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name := 'Content-Type';
        apex_web_service.g_request_headers(1).value := pi_mime_type;

        v_response := apex_web_service.make_rest_request(
            p_url                  => g_url,
            p_http_method          => 'PUT',
            p_credential_static_id => g_credential,
            p_body_blob            => pi_blob
        );

        v_status_code := apex_web_service.g_status_code;

        if v_status_code not between 200 and 299 then
            raise_application_error(-20001, 'Error al subir imagen al servidor OCI. Código HTTP: ' || v_status_code);
        end if;

        -- Actualizamos la tabla principal
        UPDATE professional
        SET profile_image_url = g_url
        WHERE id_professional = pi_id_professional;
    end;

    procedure pr_upload_profile_image(
        pi_profile_file     in varchar2,
        pi_id_professional  in professional_image.pro_id_professional%type,
        pi_id_organization  in organization.id_organization%type
    ) is
        v_file_name        varchar2(255);
        v_mime_type        varchar2(100);
        v_blob             blob;
        v_id_organization  organization.id_organization%type;
        v_response         clob;
        v_status_code      number; -- Variable para el código HTTP
    begin
        v_id_organization := fn_get_professional_org_id(pi_id_professional, pi_id_organization);
        pr_delete_profile_image(pi_id_professional);

        -- 2. Extraemos los metadatos y el archivo de la memoria temporal
        select
            filename,
            mime_type,
            blob_content
        into
            v_file_name,
            v_mime_type,
            v_blob
        from apex_application_temp_files
        where name = pi_profile_file;

        -- 3. Limpiamos fotos anteriores
        delete from professional_image
        where pro_id_professional = pi_id_professional;

        -- Modificamos el nombre para que sea único
        v_file_name := TO_CHAR(CURRENT_DATE, 'YYYYMMDD_HH24MISS') || '_' || fn_safe_file_name(v_file_name);

        -- 4. Guardamos el registro en la tabla
        insert into professional_image (
            pro_id_professional,
            file_name,
            mime_type
        ) values (
            pi_id_professional,
            v_file_name,
            v_mime_type
        );

        -- Estructura bucket: organizations/{org_id}/users/{archivo}
        g_url := fn_build_org_asset_url(v_id_organization, c_users_dir, v_file_name);

        -- 5. Limpiamos headers anteriores y seteamos el nuevo
        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name := 'Content-Type';
        apex_web_service.g_request_headers(1).value := v_mime_type;

        -- 6. Hacemos la llamada REST
        v_response := apex_web_service.make_rest_request(
            p_url                  => g_url,
            p_http_method          => 'PUT',
            p_credential_static_id => g_credential,
            p_body_blob            => v_blob
        );

        -- CAPTURAMOS Y EVALUAMOS EL CÓDIGO DE ERROR HTTP
        v_status_code := apex_web_service.g_status_code;

        if v_status_code not between 200 and 299 then
            -- Si falla, abortamos todo y le mostramos el error al usuario
            raise_application_error(-20001, 'Error al subir imagen al servidor OCI. Código HTTP: ' || v_status_code);
        end if;

        -- 7. Actualizamos la tabla principal (solo si la subida fue exitosa)
        UPDATE professional
        SET profile_image_url = g_url
        WHERE id_professional = pi_id_professional;

    end;

    procedure pr_delete_profile_image(
        pi_id_professional in professional_image.pro_id_professional%type
    ) is
        v_saved_url     varchar2(4000);
        v_response      clob;
        v_status_code   number;
    begin
        -- 1. Buscamos la URL completa que ya está guardada en la tabla principal
        begin
            select profile_image_url
            into v_saved_url
            from professional
            where id_professional = pi_id_professional;
        exception
            when no_data_found then
                return; -- Si no existe el profesional, abortamos silenciosamente
        end;

        -- 2. Si tiene una URL asignada, disparamos el DELETE directo a OCI
        if v_saved_url is not null then
            -- Limpiamos headers por las dudas
            apex_web_service.g_request_headers.delete;

            -- Llamada REST para borrar, usando la URL limpiecita
            v_response := apex_web_service.make_rest_request(
                p_url                  => v_saved_url,
                p_http_method          => 'DELETE',
                p_credential_static_id => g_credential
            );

            -- CAPTURAMOS Y EVALUAMOS EL CÓDIGO DE ERROR HTTP
            v_status_code := apex_web_service.g_status_code;

            -- 200 = OK, 204 = Borrado Exitoso, 404 = No existía (ya estaba borrado)
            if v_status_code not in (200, 204, 404) then
                raise_application_error(-20998, 'Código HTTP al eliminar en OCI: ' || v_status_code);
            end if;
        end if;

        -- 3. Limpiamos las tablas locales
        -- (Mantenemos el delete por si aún usas la tabla de historial de imágenes)
        delete from professional_image
        where pro_id_professional = pi_id_professional;

        update professional
        set profile_image_url = null
        where id_professional = pi_id_professional;

        commit;
    end pr_delete_profile_image;

    procedure pr_upload_org_logo(
        pi_blob            in blob,
        pi_filename        in varchar2,
        pi_mime_type       in varchar2,
        pi_id_organization in organization.id_organization%type
    ) is
        v_file_name     varchar2(255);
        v_response      clob;
        v_status_code   number;
        v_org_url       varchar2(3000);
    begin
        -- 1. Borramos el logo anterior si es que existe en OCI
        pr_delete_org_logo(pi_id_organization);

        -- 2. Armamos nombre único
        v_file_name := TO_CHAR(CURRENT_DATE, 'YYYYMMDD_HH24MISS') || '_logo_' || fn_safe_file_name(pi_filename);

        -- 3. Estructura bucket: organizations/{org_id}/logos/{archivo}
        v_org_url := fn_build_org_asset_url(pi_id_organization, c_logos_dir, v_file_name);

        -- 4. Headers para OCI
        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name := 'Content-Type';
        apex_web_service.g_request_headers(1).value := pi_mime_type;

        -- 5. Subida REST
        v_response := apex_web_service.make_rest_request(
            p_url                  => v_org_url,
            p_http_method          => 'PUT',
            p_credential_static_id => g_credential,
            p_body_blob            => pi_blob
        );

        v_status_code := apex_web_service.g_status_code;

        if v_status_code not between 200 and 299 then
            raise_application_error(-20001, 'Error al subir logo de la empresa a OCI. HTTP: ' || v_status_code);
        end if;

        -- 6. Actualizamos directamente el logo en la tabla organization
        UPDATE workspace_setting
        SET logo_url          = v_org_url
        WHERE org_id_organization = pi_id_organization;

    end pr_upload_org_logo;

    -- 2. PROCEDIMIENTO PARA BORRAR LOGO
    procedure pr_delete_org_logo(
        pi_id_organization in organization.id_organization%type
    ) is
        v_saved_url     varchar2(4000);
        v_response      clob;
        v_status_code   number;
    begin
        -- 1. Buscamos la URL directa en la base de datos
        begin
            select logo_url
            into v_saved_url
            from workspace_setting
            where org_id_organization = pi_id_organization;
        exception
            when no_data_found then return;
        end;

        -- 2. Si la clínica ya tenía un logo, lo borramos del bucket
        if v_saved_url is not null then
            apex_web_service.g_request_headers.delete;

            v_response := apex_web_service.make_rest_request(
                p_url                  => v_saved_url,
                p_http_method          => 'DELETE',
                p_credential_static_id => g_credential
            );

            v_status_code := apex_web_service.g_status_code;

            -- Si da error y no es 404 (Not Found), alertamos
            if v_status_code not in (200, 204, 404) then
                raise_application_error(-20998, 'Código HTTP al eliminar logo en OCI: ' || v_status_code);
            end if;
        end if;

        -- 3. Limpiamos la URL de la base de datos local
        update workspace_setting
        set logo_url              = null
        where org_id_organization = pi_id_organization;

    end pr_delete_org_logo;

    procedure pr_upload_platform_user_avatar(
        pi_blob             in blob,
        pi_filename         in varchar2,
        pi_mime_type        in varchar2,
        pi_id_platform_user in platform_user.id_platform_user%type
    ) is
        v_file_name   varchar2(255);
        v_response    clob;
        v_status_code number;
    begin
        if nvl(pi_id_platform_user, 0) <= 0 then
            raise_application_error(-20003, 'id_platform_user es obligatorio.');
        end if;

        pr_delete_platform_user_avatar(pi_id_platform_user);

        v_file_name := TO_CHAR(CURRENT_DATE, 'YYYYMMDD_HH24MISS') || '_'
            || fn_safe_file_name(nvl(pi_filename, 'avatar.jpg'));

        g_url := fn_build_platform_user_asset_url(pi_id_platform_user, v_file_name);

        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name := 'Content-Type';
        apex_web_service.g_request_headers(1).value := pi_mime_type;

        v_response := apex_web_service.make_rest_request(
            p_url                  => g_url,
            p_http_method          => 'PUT',
            p_credential_static_id => g_credential,
            p_body_blob            => pi_blob
        );

        v_status_code := apex_web_service.g_status_code;

        if v_status_code not between 200 and 299 then
            raise_application_error(-20001, 'Error al subir avatar global a OCI. Código HTTP: ' || v_status_code);
        end if;

        update platform_user
           set profile_image_url       = g_url,
               profile_image_mime      = pi_mime_type,
               profile_image_file_name = v_file_name
         where id_platform_user = pi_id_platform_user;

        if sql%rowcount = 0 then
            raise_application_error(-20004, 'Usuario de plataforma no encontrado.');
        end if;
    end pr_upload_platform_user_avatar;

    procedure pr_delete_platform_user_avatar(
        pi_id_platform_user in platform_user.id_platform_user%type
    ) is
        v_saved_url   varchar2(4000);
        v_response    clob;
        v_status_code number;
    begin
        if nvl(pi_id_platform_user, 0) <= 0 then
            return;
        end if;

        begin
            select profile_image_url
              into v_saved_url
              from platform_user
             where id_platform_user = pi_id_platform_user;
        exception
            when no_data_found then
                return;
        end;

        if v_saved_url is not null then
            apex_web_service.g_request_headers.delete;

            v_response := apex_web_service.make_rest_request(
                p_url                  => v_saved_url,
                p_http_method          => 'DELETE',
                p_credential_static_id => g_credential
            );

            v_status_code := apex_web_service.g_status_code;

            if v_status_code not in (200, 204, 404) then
                raise_application_error(-20998, 'Código HTTP al eliminar avatar global en OCI: ' || v_status_code);
            end if;
        end if;

        update platform_user
           set profile_image_url       = null,
               profile_image_mime      = null,
               profile_image_file_name = null
         where id_platform_user = pi_id_platform_user;
    end pr_delete_platform_user_avatar;

    procedure pr_upload_appointment_attachment(
        pi_blob             in blob,
        pi_filename         in varchar2,
        pi_mime_type        in varchar2,
        pi_org_id           in organization.id_organization%type,
        pi_app_id           in appointment.id_appointment%type,
        pi_user_id          in number,
        po_attachment_id    out number,
        po_url              out varchar2
    ) is
        v_file_name    varchar2(255);
        v_size_bytes   number;
        v_used_bytes   number;
        v_limit_bytes  number;
        v_app_count    number;
        v_response     clob;
        v_status_code  number;
        v_url          varchar2(1000);
    begin
        -- Gates de suscripcion: feature del plan + estado con escritura.
        pkg_aox_subscription_api.pr_assert_org_has_feature(pi_org_id, 'APPOINTMENT_HISTORY');
        pkg_aox_subscription_api.fn_assert_org_can_write(pi_org_id);

        if pi_blob is null or dbms_lob.getlength(pi_blob) = 0 then
            raise_application_error(-20002, 'El archivo adjunto esta vacio.');
        end if;

        -- La cita debe existir y pertenecer a la organizacion.
        select count(*)
          into v_app_count
          from appointment
         where id_appointment      = pi_app_id
           and org_id_organization = pi_org_id;

        if v_app_count = 0 then
            raise_application_error(-20004, 'Cita no encontrada.');
        end if;

        v_size_bytes := dbms_lob.getlength(pi_blob);

        -- Paywall de storage: bytes usados + nuevo <= limite del plan (plan + addons).
        v_limit_bytes := pkg_aox_subscription_api.fn_get_storage_limit_bytes(pi_org_id);

        select nvl(storage_used_bytes, 0)
          into v_used_bytes
          from org_subscription
         where org_id_organization = pi_org_id;

        if v_used_bytes + v_size_bytes > v_limit_bytes then
            raise_application_error(
                pkg_aox_util.c_sqlcode_forbidden,
                'Superaste el limite de almacenamiento de tu plan. ' ||
                'Liberá espacio o contratá un paquete de storage adicional.'
            );
        end if;

        v_file_name := to_char(current_date, 'YYYYMMDD_HH24MISS') || '_' || fn_safe_file_name(pi_filename);

        -- Estructura bucket: organizations/{org_id}/appointments/{app_id}/{archivo}
        v_url := rtrim(g_base_url, '/')
            || '/' || c_organizations_dir || pi_org_id
            || '/' || c_appointments_dir  || pi_app_id
            || '/' || v_file_name;

        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name := 'Content-Type';
        apex_web_service.g_request_headers(1).value := nvl(pi_mime_type, 'application/octet-stream');

        v_response := apex_web_service.make_rest_request(
            p_url                  => v_url,
            p_http_method          => 'PUT',
            p_credential_static_id => g_credential,
            p_body_blob            => pi_blob
        );

        v_status_code := apex_web_service.g_status_code;

        if v_status_code not between 200 and 299 then
            raise_application_error(-20001, 'Error al subir el adjunto a OCI. Codigo HTTP: ' || v_status_code);
        end if;

        insert into appointment_attachment (
            app_id_appointment, org_id_organization, file_name, mime_type,
            size_bytes, storage_url, created_by_user
        ) values (
            pi_app_id, pi_org_id, v_file_name, pi_mime_type,
            v_size_bytes, v_url, pi_user_id
        ) returning id_attachment into po_attachment_id;

        -- Acumular el consumo de storage de la org.
        update org_subscription
           set storage_used_bytes = nvl(storage_used_bytes, 0) + v_size_bytes,
               updated_at         = current_timestamp
         where org_id_organization = pi_org_id;

        po_url := v_url;
        commit;
    end pr_upload_appointment_attachment;

    procedure pr_delete_appointment_attachment(
        pi_org_id        in organization.id_organization%type,
        pi_attachment_id in appointment_attachment.id_attachment%type
    ) is
        v_url         varchar2(1000);
        v_size_bytes  number;
        v_response    clob;
        v_status_code number;
    begin
        -- Escritura requerida para modificar el historial.
        pkg_aox_subscription_api.fn_assert_org_can_write(pi_org_id);

        begin
            select storage_url, nvl(size_bytes, 0)
              into v_url, v_size_bytes
              from appointment_attachment
             where id_attachment       = pi_attachment_id
               and org_id_organization = pi_org_id;
        exception
            when no_data_found then
                raise_application_error(-20004, 'Adjunto no encontrado.');
        end;

        if v_url is not null then
            apex_web_service.g_request_headers.delete;
            v_response := apex_web_service.make_rest_request(
                p_url                  => v_url,
                p_http_method          => 'DELETE',
                p_credential_static_id => g_credential
            );
            v_status_code := apex_web_service.g_status_code;
            if v_status_code not in (200, 204, 404) then
                raise_application_error(-20998, 'Codigo HTTP al eliminar adjunto en OCI: ' || v_status_code);
            end if;
        end if;

        delete from appointment_attachment
         where id_attachment       = pi_attachment_id
           and org_id_organization = pi_org_id;

        -- Liberar el consumo de storage (no baja de 0).
        update org_subscription
           set storage_used_bytes = greatest(nvl(storage_used_bytes, 0) - v_size_bytes, 0),
               updated_at         = current_timestamp
         where org_id_organization = pi_org_id;

        commit;
    end pr_delete_appointment_attachment;

    procedure pr_upload_payment_receipt(
        pi_blob          in blob,
        pi_filename      in varchar2,
        pi_mime_type     in varchar2,
        pi_org_id        in organization.id_organization%type,
        pi_customer_id   in customer.id_customer%type,
        pi_receipt_id    in number,
        po_url           out varchar2,
        po_object_key    out varchar2
    ) is
        v_ext          varchar2(20);
        v_safe_name    varchar2(255);
        v_yyyy         varchar2(4);
        v_mm           varchar2(2);
        v_object_key   varchar2(500);
        v_url          varchar2(1000);
        v_response     clob;
        v_status_code  number;
        v_mime         varchar2(150);
    begin
        if nvl(pi_org_id, 0) <= 0 or nvl(pi_customer_id, 0) <= 0 or nvl(pi_receipt_id, 0) <= 0 then
            raise_application_error(-20002, 'Parametros de comprobante invalidos.');
        end if;

        if pi_blob is null or dbms_lob.getlength(pi_blob) = 0 then
            raise_application_error(-20002, 'El comprobante esta vacio.');
        end if;

        v_mime := lower(nvl(trim(pi_mime_type), 'application/octet-stream'));
        v_safe_name := fn_safe_file_name(nvl(pi_filename, 'comprobante'));

        if v_mime in ('image/jpeg', 'image/jpg') or lower(v_safe_name) like '%.jpg' or lower(v_safe_name) like '%.jpeg' then
            v_ext := 'jpg';
            v_mime := 'image/jpeg';
        elsif v_mime = 'image/png' or lower(v_safe_name) like '%.png' then
            v_ext := 'png';
            v_mime := 'image/png';
        elsif v_mime = 'image/webp' or lower(v_safe_name) like '%.webp' then
            v_ext := 'webp';
            v_mime := 'image/webp';
        elsif v_mime = 'image/gif' or lower(v_safe_name) like '%.gif' then
            v_ext := 'gif';
            v_mime := 'image/gif';
        elsif v_mime = 'application/pdf' or lower(v_safe_name) like '%.pdf' then
            v_ext := 'pdf';
            v_mime := 'application/pdf';
        else
            v_ext := 'bin';
        end if;

        v_yyyy := to_char(current_timestamp, 'YYYY');
        v_mm   := to_char(current_timestamp, 'MM');

        -- Path obligatorio: organizations/{org}/payments/{yyyy}/{mm}/{customer_id}/{receipt_id}.{ext}
        v_object_key := c_organizations_dir || pi_org_id
            || '/' || c_payments_dir || v_yyyy
            || '/' || v_mm
            || '/' || pi_customer_id
            || '/' || pi_receipt_id || '.' || v_ext;

        v_url := rtrim(g_base_url, '/') || '/' || v_object_key;

        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name := 'Content-Type';
        apex_web_service.g_request_headers(1).value := v_mime;

        v_response := apex_web_service.make_rest_request(
            p_url                  => v_url,
            p_http_method          => 'PUT',
            p_credential_static_id => g_credential,
            p_body_blob            => pi_blob
        );

        v_status_code := apex_web_service.g_status_code;

        if v_status_code not between 200 and 299 then
            raise_application_error(-20001, 'Error al subir el comprobante a OCI. Codigo HTTP: ' || v_status_code);
        end if;

        po_url := v_url;
        po_object_key := v_object_key;
    end pr_upload_payment_receipt;

    procedure pr_upload_atc_kb_document(
        pi_blob         in blob,
        pi_filename     in varchar2,
        pi_mime_type    in varchar2,
        pi_document_id  in number,
        po_url          out varchar2,
        po_object_key   out varchar2
    ) is
        v_safe_name   varchar2(255);
        v_object_key  varchar2(500);
        v_url         varchar2(1000);
        v_response    clob;
        v_status_code number;
        v_mime        varchar2(150);
    begin
        if nvl(pi_document_id, 0) <= 0 then
            raise_application_error(-20002, 'id_document invalido.');
        end if;

        if pi_blob is null or dbms_lob.getlength(pi_blob) = 0 then
            raise_application_error(-20002, 'El documento ATC esta vacio.');
        end if;

        v_mime := lower(nvl(trim(pi_mime_type), 'application/octet-stream'));
        v_safe_name := fn_safe_file_name(nvl(pi_filename, 'documento'));

        v_object_key := c_atc_kb_dir || pi_document_id || '/' || v_safe_name;
        v_url := rtrim(g_base_url, '/') || '/' || v_object_key;

        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name := 'Content-Type';
        apex_web_service.g_request_headers(1).value := v_mime;

        v_response := apex_web_service.make_rest_request(
            p_url                  => v_url,
            p_http_method          => 'PUT',
            p_credential_static_id => g_credential,
            p_body_blob            => pi_blob
        );

        v_status_code := apex_web_service.g_status_code;

        if v_status_code not between 200 and 299 then
            raise_application_error(-20001, 'Error al subir documento ATC a OCI. Codigo HTTP: ' || v_status_code);
        end if;

        po_url := v_url;
        po_object_key := v_object_key;
    end pr_upload_atc_kb_document;

    procedure pr_delete_atc_kb_document(
        pi_object_key in varchar2
    ) is
        v_url         varchar2(1000);
        v_response    clob;
        v_status_code number;
    begin
        if pi_object_key is null or trim(pi_object_key) is null then
            return;
        end if;

        if lower(pi_object_key) like 'http%' then
            v_url := pi_object_key;
        else
            v_url := rtrim(g_base_url, '/') || '/' || ltrim(pi_object_key, '/');
        end if;

        apex_web_service.g_request_headers.delete;

        v_response := apex_web_service.make_rest_request(
            p_url                  => v_url,
            p_http_method          => 'DELETE',
            p_credential_static_id => g_credential
        );

        v_status_code := apex_web_service.g_status_code;

        if v_status_code not in (200, 204, 404) then
            raise_application_error(-20998, 'Codigo HTTP al eliminar documento ATC en OCI: ' || v_status_code);
        end if;
    end pr_delete_atc_kb_document;

    function fn_download_atc_kb_document(
        pi_storage_url in varchar2
    ) return blob is
        v_blob        blob;
        v_status_code number;
    begin
        if pi_storage_url is null or trim(pi_storage_url) is null then
            return null;
        end if;

        apex_web_service.g_request_headers.delete;

        v_blob := apex_web_service.make_rest_request_b(
            p_url                  => pi_storage_url,
            p_http_method          => 'GET',
            p_credential_static_id => g_credential
        );

        v_status_code := apex_web_service.g_status_code;

        if v_status_code not between 200 and 299 then
            raise_application_error(-20001, 'Error al descargar documento ATC de OCI. Codigo HTTP: ' || v_status_code);
        end if;

        return v_blob;
    end fn_download_atc_kb_document;

end;
/

