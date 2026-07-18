PROMPT CREATE OR REPLACE PACKAGE pkg_aox_professional_api
CREATE OR REPLACE PACKAGE pkg_aox_professional_api IS

    -- Crear Profesional y Usuario en una sola transacción
    PROCEDURE pr_create_prof_and_user(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Listar profesionales con paginación
    PROCEDURE pr_list_professionals(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_search        IN  VARCHAR2 DEFAULT NULL,
        pi_is_active     IN  NUMBER DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Actualizar Profesional y Usuario
    PROCEDURE pr_update_prof_and_user(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Obtener Profesional por ID
    PROCEDURE pr_get_prof_and_user(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Cancelar invitación pendiente (DELETE físico solo si usr_id_user IS NULL)
    PROCEDURE pr_delete_prof_and_user(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Sugerir un slug único para el perfil
    PROCEDURE pr_suggest_profile_slug(
        pi_auth_header   IN  VARCHAR2,
        pi_full_name     IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Listar profesionales activos (LOV)
    PROCEDURE pr_list_professionals_lov(
        pi_auth_header   IN  VARCHAR2,
        pi_only_me       IN  NUMBER DEFAULT 0, -- Nueva bandera
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_professional_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_professional_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_professional_api IS

    -- Procedimiento: Crear Profesional + Usuario (POST)
    PROCEDURE pr_create_prof_and_user(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        -- (Tus variables declaradas anteriormente: v_org_id, v_json_req, etc...)
        v_org_id            NUMBER;
        v_json_req          json_object_t;
        v_response_json     json_object_t := json_object_t();
        v_validation_errors json_array_t  := json_array_t();
        v_error             json_object_t;

        v_new_prof_id       NUMBER;
        v_user_count        NUMBER;
        v_member_in_org     NUMBER;
        v_pending_invite    NUMBER;
        v_existing_platform platform_user.id_platform_user%TYPE;

        v_invite_token      org_invitation.invite_token%TYPE;
        v_invited_by        org_member.id_org_member%TYPE;
        v_org_name          organization.name%TYPE;
        v_invite_url        VARCHAR2(2000);
        v_email_sent        NUMBER := 0;
        v_expires_label     VARCHAR2(100);
        v_public_base_url   VARCHAR2(500);

        v_role_id           org_member.rol_id_role%TYPE;
        v_username          platform_user.apex_user_name%TYPE;
        v_display_name      professional.display_name%TYPE;
        v_email             platform_user.email%TYPE;
        v_password          VARCHAR2(255);
        v_user_active       org_member.is_active%TYPE;

        v_specialty_id      professional.spe_id_specialty%TYPE;
        v_phone             professional.phone_number%TYPE;
        v_slug              professional.profile_slug%TYPE;
        v_prof_active       professional.is_active%TYPE;

        -- ¡NUEVAS VARIABLES PARA LA IMAGEN!
        v_img_base64        CLOB;
        v_img_name          VARCHAR2(255);
        v_img_mime          VARCHAR2(100);
        v_img_blob          BLOB;

        -- Variables para servicios múltiples
        v_services_arr      json_array_t;
        v_ser_id            NUMBER;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- 1. Parsear el JSON
        BEGIN
            v_json_req   := json_object_t.parse(pi_body);

            v_role_id      := v_json_req.get_number('rol_id_role');
            v_username     := v_json_req.get_string('apex_user_name');
            v_display_name := v_json_req.get_string('display_name');
            v_email        := v_json_req.get_string('email');
            v_password     := v_json_req.get_string('password');
            IF v_json_req.has('user_is_active') THEN v_user_active := v_json_req.get_number('user_is_active'); ELSE v_user_active := 1; END IF;

            v_phone      := v_json_req.get_string('phone_number');
            IF v_json_req.has('spe_id_specialty') THEN v_specialty_id := v_json_req.get_number('spe_id_specialty'); END IF;
            IF v_json_req.has('profile_slug') THEN v_slug := v_json_req.get_string('profile_slug'); END IF;
            IF v_json_req.has('prof_is_active') THEN v_prof_active := v_json_req.get_number('prof_is_active'); ELSE v_prof_active := 1; END IF;

            -- Extraemos la info de la imagen (Opcional)
            IF v_json_req.has('image_base64') THEN
                v_img_base64 := v_json_req.get_clob('image_base64');
                v_img_name   := v_json_req.get_string('image_name');
                v_img_mime   := v_json_req.get_string('image_mime');
            END IF;

            IF v_json_req.has('services') THEN
                v_services_arr := v_json_req.get_array('services');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        IF v_display_name IS NULL OR TRIM(v_display_name) = '' THEN
          v_error := json_object_t();
          v_error.put('field', 'display_name');
          v_error.put('message', 'El nombre en este negocio es obligatorio.');
          v_validation_errors.append(v_error);
        END IF;

        IF v_role_id IS NULL THEN
          v_error := json_object_t();
          v_error.put('field', 'rol_id_role');
          v_error.put('message', 'El rol es obligatorio.');
          v_validation_errors.append(v_error);
        END IF;

        IF v_phone IS NULL THEN
          v_error := json_object_t();
          v_error.put('field', 'phone_number');
          v_error.put('message', 'El teléfono es obligatorio.');
          v_validation_errors.append(v_error);
        END IF;

        IF v_validation_errors.get_size() > 0 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Errores de validación.');
            v_response_json.put('errors'  , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        -- 3. Normalizar correo / usuario sugerido y validar membresía en esta org
        IF v_email IS NULL THEN
            v_error := json_object_t();
            v_error.put('field', 'email');
            v_error.put('message', 'El correo electrónico es obligatorio.');
            v_validation_errors.append(v_error);
        END IF;

        IF v_validation_errors.get_size() > 0 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Errores de validación.');
            v_response_json.put('errors'  , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        v_email := lower(trim(v_email));

        IF v_username IS NULL OR trim(v_username) = '' THEN
            v_username := upper(substr(replace(substr(v_email, 1, instr(v_email, '@') - 1), '.', '_'), 1, 100));
        END IF;

        v_existing_platform := NULL;
        BEGIN
            SELECT id_platform_user
              INTO v_existing_platform
              FROM platform_user
             WHERE lower(email) = v_email;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_existing_platform := NULL;
        END;

        IF v_existing_platform IS NOT NULL THEN
            -- Solo bloqueamos si la membresía está ACTIVA.
            -- Si is_active = 0 (desactivada), el admin puede reactivarla
            -- desde el panel de personal sin necesidad de re-invitar.
            SELECT COUNT(*)
              INTO v_member_in_org
              FROM org_member
             WHERE platform_user_id   = v_existing_platform
               AND org_id_organization = v_org_id
               AND is_active           = 1;

            IF v_member_in_org > 0 THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Esta persona ya pertenece a tu organización.');
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            -- Verificar si existe pero desactivada: guiar a reactivar (misma fila, sin re-invitar).
            DECLARE
                v_inactive_prof_id professional.id_professional%TYPE;
            BEGIN
                BEGIN
                    SELECT p.id_professional
                      INTO v_inactive_prof_id
                      FROM org_member m
                      JOIN professional p
                        ON p.usr_id_user = m.id_org_member
                       AND p.org_id_organization = m.org_id_organization
                     WHERE m.platform_user_id    = v_existing_platform
                       AND m.org_id_organization = v_org_id
                       AND m.is_active           = 0
                     ORDER BY p.id_professional DESC
                     FETCH FIRST 1 ROW ONLY;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        v_inactive_prof_id := NULL;
                END;

                IF v_inactive_prof_id IS NOT NULL THEN
                    po_status_code := pkg_aox_util.c_conflict_code;
                    v_response_json.put('status'                  , 'error');
                    v_response_json.put('can_reactivate'          , 1);
                    v_response_json.put('reactivate_professional_id', v_inactive_prof_id);
                    v_response_json.put(
                        'message',
                        'Esta persona ya estuvo en tu organización y fue desactivada. Abrí su ficha y activá el estado de la cuenta para reactivarla.'
                    );
                    po_response_body := v_response_json.to_clob();
                    RETURN;
                END IF;
            END;
        END IF;

        SELECT COUNT(*)
          INTO v_pending_invite
          FROM org_invitation i
         WHERE i.org_id_organization = v_org_id
           AND lower(i.invite_email) = v_email
           AND i.status = 'PENDING'
           AND i.expires_at > current_timestamp;

        IF v_pending_invite > 0 THEN
            po_status_code := pkg_aox_util.c_conflict_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Ya existe una invitación pendiente para este correo.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        -- Slug único entre perfiles visibles o invitaciones pendientes (inactivos archivados no bloquean).
        IF v_slug IS NOT NULL THEN
            SELECT COUNT(*) INTO v_user_count
            FROM professional
            WHERE profile_slug = TRIM(v_slug)
              AND org_id_organization = v_org_id
              AND (is_active = 1 OR usr_id_user IS NULL);

            IF v_user_count > 0 THEN
                po_status_code := pkg_aox_util.c_conflict_code; -- 409 Conflict
                v_response_json.put('status', 'error');

                -- Lo metemos en el array de errores para que Astro lo asocie al campo visualmente
                v_error := json_object_t();
                v_error.put('field'   , 'profile_slug');
                v_error.put('message' , 'Este enlace ya está en uso en tu organización. Elegí otro.');
                v_validation_errors.append(v_error);

                v_response_json.put('message' , 'Errores de validación.');
                v_response_json.put('errors'  , v_validation_errors);
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;
        END IF;

        v_invited_by := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        SELECT name INTO v_org_name
          FROM organization
         WHERE id_organization = v_org_id;

        -- 4. Profesional pendiente (sin org_member hasta aceptar invitación)
        INSERT INTO professional (
            org_id_organization,
            usr_id_user,
            profile_slug,
            display_name,
            is_active,
            spe_id_specialty,
            phone_number
        ) VALUES (
            v_org_id,
            NULL,
            TRIM(v_slug),
            TRIM(v_display_name),
            0,
            v_specialty_id,
            TRIM(v_phone)
        ) RETURNING id_professional INTO v_new_prof_id;

        v_invite_token := lower(rawtohex(sys_guid()));

        INSERT INTO org_invitation (
            org_id_organization,
            pro_id_professional,
            platform_user_id,
            invite_email,
            display_name,
            apex_user_name,
            rol_id_role,
            invite_token,
            status,
            invited_by,
            expires_at
        ) VALUES (
            v_org_id,
            v_new_prof_id,
            v_existing_platform,
            v_email,
            TRIM(v_display_name),
            upper(trim(v_username)),
            v_role_id,
            v_invite_token,
            'PENDING',
            v_invited_by,
            current_timestamp + numtodsinterval(7, 'DAY')
        );

        IF v_services_arr IS NOT NULL THEN
            FOR i IN 0 .. v_services_arr.get_size() - 1 LOOP
                v_ser_id := v_services_arr.get_number(i);

                INSERT INTO professional_service (org_id_organization, pro_id_professional, ser_id_service)
                VALUES (v_org_id, v_new_prof_id, v_ser_id);
            END LOOP;
        END IF;

        -- 6. PROCESAMIENTO DE LA IMAGEN
        IF v_img_base64 IS NOT NULL THEN
            -- Convertimos el texto Base64 a BLOB binario
            v_img_blob := apex_web_service.clobbase642blob(v_img_base64);

            -- Llamamos al nuevo procedimiento de tu Bucket, pasándole el ID recién creado
            pkg_aox_bucket.pr_upload_profile_image(
                pi_blob            => v_img_blob,
                pi_filename        => v_img_name,
                pi_mime_type       => v_img_mime,
                pi_id_professional => v_new_prof_id,
                pi_id_organization => v_org_id
            );
        END IF;

        v_public_base_url := rtrim(nvl(fn_get_parameter('APP_PUBLIC_BASE_URL'), 'https://staging.hasel.app'), '/');
        v_invite_url := v_public_base_url || '/auth/accept-invite?token=' || v_invite_token;
        v_expires_label := to_char(
            current_timestamp + numtodsinterval(7, 'DAY'),
            'DD/MM/YYYY HH24:MI',
            'NLS_DATE_LANGUAGE=SPANISH'
        );

        pkg_aox_auth_api.pr_send_invitation_email(
            pi_email      => v_email,
            pi_org_name   => v_org_name,
            pi_invite_url => v_invite_url,
            pi_expires_at => v_expires_label,
            po_sent       => v_email_sent
        );

        COMMIT;

        -- 7. Respuesta Exitosa
        po_status_code := pkg_aox_util.c_success_create_code;
        v_response_json.put('status'           , 'success');
        v_response_json.put('message'          , 'Invitación enviada. La persona recibirá un correo para activar su acceso.');
        v_response_json.put('id_professional'  , v_new_prof_id);
        v_response_json.put('invitation_sent'  , 1);
        v_response_json.put('email_sent'       , v_email_sent);
        v_response_json.put('invite_email'     , v_email);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_create_prof_and_user;

    -- Procedimiento: Listar Profesionales (GET)
    PROCEDURE pr_list_professionals(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_search        IN  VARCHAR2 DEFAULT NULL,
        pi_is_active     IN  NUMBER DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_profs_arr     json_array_t  := json_array_t();

        -- Objetos JSON anidados
        v_prof_obj      json_object_t;
        v_user_obj      json_object_t;
        v_spec_obj      json_object_t;
        v_meta_obj      json_object_t;

        -- Paginación
        v_page          NUMBER := NVL(pi_page, 1);
        v_limit         NUMBER := NVL(pi_limit, 9);
        v_offset        NUMBER;
        v_total_records NUMBER := 0;
        v_total_pages   NUMBER := 0;
        v_search        VARCHAR2(200) := TRANSLATE(
            UPPER(TRIM(pi_search)),
            'ÁÉÍÓÚÜÑÀÈÌÒÙÄËÏÖÜ',
            'AEIOUUNAEIOUAAEIOU'
        );
    BEGIN
        -- 1. Validar JWT y Organización
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        IF v_page < 1 THEN v_page := 1; END IF;
        v_offset := (v_page - 1) * v_limit;

        IF v_search IS NOT NULL AND LENGTH(v_search) = 0 THEN
            v_search := NULL;
        END IF;

        -- 2. Conteo total para la metadata
        -- pi_is_active: 1 = cuenta activa (tiene usuario y user/prof activo);
        --               0 = cuenta inactiva (tiene usuario y ambos inactivos); excluye invitaciones pendientes
        SELECT COUNT(*)
        INTO v_total_records
        FROM professional p
        LEFT JOIN app_user u ON p.usr_id_user = u.id_user
        LEFT JOIN org_invitation i
               ON i.pro_id_professional = p.id_professional
              AND i.status = 'PENDING'
        WHERE p.org_id_organization = v_org_id
          AND (
                v_search IS NULL
                OR TRANSLATE(
                       UPPER(NVL(p.display_name, i.display_name)),
                       'ÁÉÍÓÚÜÑÀÈÌÒÙÄËÏÖÜ',
                       'AEIOUUNAEIOUAAEIOU'
                   ) LIKE '%' || v_search || '%'
                OR UPPER(NVL(u.email, i.invite_email)) LIKE '%' || v_search || '%'
                OR UPPER(NVL(p.phone_number, '')) LIKE '%' || v_search || '%'
              )
          AND (
                pi_is_active IS NULL
                OR (
                    pi_is_active = 1
                    AND p.usr_id_user IS NOT NULL
                    AND (NVL(u.is_active, 0) = 1 OR p.is_active = 1)
                )
                OR (
                    pi_is_active = 0
                    AND p.usr_id_user IS NOT NULL
                    AND NVL(u.is_active, 0) = 0
                    AND p.is_active = 0
                )
              );

        v_total_pages := CEIL(v_total_records / v_limit);

        -- 3. Cursor con los JOINs necesarios
        FOR rec IN (
            SELECT
                p.id_professional,
                p.profile_slug,
                p.profile_image_url,
                p.phone_number,
                p.is_active AS prof_is_active,
                p.created_at AS prof_created_at,
                p.usr_id_user,
                NVL(u.id_user, 0) AS id_user,
                NVL(u.apex_user_name, i.apex_user_name) AS apex_user_name,
                NVL(p.display_name, i.display_name) AS display_name,
                NVL(u.email, i.invite_email) AS email,
                NVL(u.rol_id_role, i.rol_id_role) AS rol_id_role,
                NVL(u.is_active, 0) AS user_is_active,
                CASE WHEN p.usr_id_user IS NULL THEN 'pending_invite' ELSE 'active' END AS membership_status,
                i.status AS invitation_status,
                s.id_specialty,
                s.name AS specialty_name
            FROM professional p
            LEFT JOIN app_user u ON p.usr_id_user = u.id_user
            LEFT JOIN org_invitation i
                   ON i.pro_id_professional = p.id_professional
                  AND i.status = 'PENDING'
            LEFT JOIN specialty s ON p.spe_id_specialty = s.id_specialty
            WHERE p.org_id_organization = v_org_id
              AND (
                    v_search IS NULL
                    OR TRANSLATE(
                           UPPER(NVL(p.display_name, i.display_name)),
                           'ÁÉÍÓÚÜÑÀÈÌÒÙÄËÏÖÜ',
                           'AEIOUUNAEIOUAAEIOU'
                       ) LIKE '%' || v_search || '%'
                    OR UPPER(NVL(u.email, i.invite_email)) LIKE '%' || v_search || '%'
                    OR UPPER(NVL(p.phone_number, '')) LIKE '%' || v_search || '%'
                  )
              AND (
                    pi_is_active IS NULL
                    OR (
                        pi_is_active = 1
                        AND p.usr_id_user IS NOT NULL
                        AND (NVL(u.is_active, 0) = 1 OR p.is_active = 1)
                    )
                    OR (
                        pi_is_active = 0
                        AND p.usr_id_user IS NOT NULL
                        AND NVL(u.is_active, 0) = 0
                        AND p.is_active = 0
                    )
                  )
            ORDER BY
                CASE
                    WHEN p.usr_id_user IS NOT NULL
                     AND (NVL(u.is_active, 0) = 1 OR p.is_active = 1) THEN 0
                    WHEN p.usr_id_user IS NULL THEN 1
                    ELSE 2
                END,
                p.id_professional DESC
            OFFSET v_offset ROWS FETCH NEXT v_limit ROWS ONLY
        ) LOOP
            v_prof_obj := json_object_t();
            v_prof_obj.put('id_professional'  , rec.id_professional);
            v_prof_obj.put('display_name'     , rec.display_name);
            v_prof_obj.put('profile_slug'     , rec.profile_slug);
            v_prof_obj.put('profile_image_url', rec.profile_image_url);
            v_prof_obj.put('phone_number'     , rec.phone_number);
            v_prof_obj.put('is_active'        , rec.prof_is_active);
            v_prof_obj.put('created_at'       , TO_CHAR(rec.prof_created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            v_prof_obj.put('membership_status', rec.membership_status);
            IF rec.invitation_status IS NOT NULL THEN
                v_prof_obj.put('invitation_status', rec.invitation_status);
            END IF;

            -- Construir objeto User anidado
            v_user_obj := json_object_t();
            v_user_obj.put('id_user'        , CASE WHEN rec.id_user = 0 THEN NULL ELSE rec.id_user END);
            v_user_obj.put('apex_user_name' , rec.apex_user_name);
            v_user_obj.put('email'          , rec.email);
            v_user_obj.put('rol_id_role'    , rec.rol_id_role);
            v_user_obj.put('is_active'      , rec.user_is_active);
            v_prof_obj.put('user'           , v_user_obj);

            -- Construir objeto Specialty anidado (Solo si tiene especialidad asignada)
            IF rec.id_specialty IS NOT NULL THEN
                v_spec_obj := json_object_t();
                v_spec_obj.put('id_specialty' , rec.id_specialty);
                v_spec_obj.put('name'         , rec.specialty_name);
                v_prof_obj.put('specialty'    , v_spec_obj);
            ELSE
                v_prof_obj.put('specialty', ''); -- Retornamos vacío o null si no tiene
            END IF;

            v_profs_arr.append(v_prof_obj);
        END LOOP;

        -- 4. Construir Metadata
        v_meta_obj := json_object_t();
        v_meta_obj.put('current_page' , v_page);
        v_meta_obj.put('per_page'     , v_limit);
        v_meta_obj.put('total_records', v_total_records);
        v_meta_obj.put('total_pages'  , v_total_pages);

        -- 5. Respuesta
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('meta'  , v_meta_obj);
        v_response_json.put('data'  , v_profs_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_professionals;

    -- Procedimiento: Actualizar Profesional + Usuario (PUT)
    PROCEDURE pr_update_prof_and_user(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id            NUMBER;
        v_usr_id            NUMBER; -- El ID del app_user vinculado

        v_json_req          json_object_t;
        v_response_json     json_object_t := json_object_t();
        v_validation_errors json_array_t  := json_array_t();
        v_error             json_object_t;
        v_user_count        NUMBER;
        v_user_email_count  NUMBER;

        -- Datos de Usuario (app_user)
        v_role_id           app_user.rol_id_role%TYPE;
        v_username          app_user.apex_user_name%TYPE;
        v_display_name      professional.display_name%TYPE;
        v_email             app_user.email%TYPE;
        v_password          VARCHAR2(255);
        v_user_active       app_user.is_active%TYPE;

        -- Datos de Profesional (professional)
        v_specialty_id      professional.spe_id_specialty%TYPE;
        v_phone             professional.phone_number%TYPE;
        v_slug              professional.profile_slug%TYPE;
        v_prof_active       professional.is_active%TYPE;

        -- Variables para la imagen
        v_img_base64        CLOB;
        v_img_name          VARCHAR2(255);
        v_img_mime          VARCHAR2(100);
        v_img_blob          BLOB;
        -- Variables para servicios múltiples
        v_services_arr      json_array_t;
        v_ser_id            NUMBER;

        -- Protección auto-edición admin
        v_caller_user_id      NUMBER;
        v_current_role_id     app_user.rol_id_role%TYPE;
        v_current_user_active app_user.is_active%TYPE;
        v_current_prof_active professional.is_active%TYPE;
        v_admin_role_id       app_user.rol_id_role%TYPE := pkg_aox_util.fn_rol('ADMIN');

        v_current_email       platform_user.email%TYPE;
        v_current_username    platform_user.apex_user_name%TYPE;
    BEGIN
        -- 1. Validar JWT y Organización
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- 2. Recuperar el ID del usuario asociado a este profesional
        BEGIN
            SELECT
              usr_id_user
            INTO
              v_usr_id
            FROM professional
            WHERE id_professional = pi_prof_id AND org_id_organization = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := pkg_aox_util.c_not_found_code;
                v_response_json.put('status'  , 'error');
                v_response_json.put('message' , 'Profesional no encontrado o no pertenece a su organización.');
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        -- 3. Parsear el JSON
        BEGIN
            v_json_req   := json_object_t.parse(pi_body);

            -- User data
            v_role_id      := v_json_req.get_number('rol_id_role');
            v_username     := v_json_req.get_string('apex_user_name');
            v_display_name := v_json_req.get_string('display_name');
            v_email        := v_json_req.get_string('email');

            -- La contraseña es opcional en la actualización
            IF v_json_req.has('password') THEN
              v_password := v_json_req.get_string('password');
            END IF;

            IF v_json_req.has('user_is_active') THEN
              v_user_active := v_json_req.get_number('user_is_active');
            END IF;

            -- Professional data
            v_phone      := v_json_req.get_string('phone_number');
            IF v_json_req.has('spe_id_specialty') THEN
              v_specialty_id := v_json_req.get_number('spe_id_specialty');
            END IF;

            IF v_json_req.has('profile_slug') THEN
              v_slug := v_json_req.get_string('profile_slug');
            END IF;

            IF v_json_req.has('prof_is_active') THEN
              v_prof_active := v_json_req.get_number('prof_is_active');
            END IF;

            -- Extraemos la info de la imagen (Opcional)
            IF v_json_req.has('image_base64') THEN
                v_img_base64 := v_json_req.get_clob('image_base64');
                v_img_name   := v_json_req.get_string('image_name');
                v_img_mime   := v_json_req.get_string('image_mime');
            END IF;

            -- Extraemos el array de servicios (Opcional)
            IF v_json_req.has('services') THEN
                v_services_arr := v_json_req.get_array('services');
            END IF;

        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        -- 4. Validaciones
        IF v_display_name IS NULL OR TRIM(v_display_name) = '' THEN
          v_error := json_object_t();
          v_error.put('field'   , 'display_name');
          v_error.put('message' , 'El nombre en este negocio es obligatorio.');
          v_validation_errors.append(v_error);
        END IF;

        IF v_phone IS NULL THEN
          v_error := json_object_t();
          v_error.put('field', 'phone_number');
          v_error.put('message', 'El teléfono es obligatorio.');
          v_validation_errors.append(v_error);
        END IF;

        IF v_validation_errors.get_size() > 0 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Errores de validación.');
            v_response_json.put('errors'  , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        IF v_usr_id IS NULL THEN
            IF v_email IS NULL OR trim(v_email) = '' THEN
              v_error := json_object_t();
              v_error.put('field'   , 'email');
              v_error.put('message' , 'El correo electrónico es obligatorio.');
              v_validation_errors.append(v_error);
            END IF;

            IF v_validation_errors.get_size() > 0 THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status'  , 'error');
                v_response_json.put('message' , 'Errores de validación.');
                v_response_json.put('errors'  , v_validation_errors);
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            IF v_username IS NULL OR trim(v_username) = '' THEN
                v_username := upper(substr(replace(substr(lower(trim(v_email)), 1, instr(lower(trim(v_email)), '@') - 1), '.', '_'), 1, 100));
            END IF;

            UPDATE org_invitation
               SET display_name   = TRIM(v_display_name),
                   invite_email   = lower(trim(v_email)),
                   apex_user_name = upper(trim(v_username)),
                   rol_id_role    = NVL(v_role_id, rol_id_role)
             WHERE pro_id_professional = pi_prof_id
               AND org_id_organization = v_org_id
               AND status = 'PENDING';

            UPDATE professional
               SET display_name     = TRIM(v_display_name),
                   phone_number     = TRIM(v_phone),
                   spe_id_specialty = v_specialty_id,
                   profile_slug     = NVL(TRIM(v_slug), profile_slug)
             WHERE id_professional = pi_prof_id;

            IF v_services_arr IS NOT NULL THEN
                DELETE FROM professional_service
                 WHERE pro_id_professional = pi_prof_id
                   AND org_id_organization = v_org_id;

                FOR i IN 0 .. v_services_arr.get_size() - 1 LOOP
                    v_ser_id := v_services_arr.get_number(i);
                    INSERT INTO professional_service (org_id_organization, pro_id_professional, ser_id_service)
                    VALUES (v_org_id, pi_prof_id, v_ser_id);
                END LOOP;
            END IF;

            IF v_img_base64 IS NOT NULL THEN
                v_img_blob := apex_web_service.clobbase642blob(v_img_base64);
                pkg_aox_bucket.pr_upload_profile_image(
                    pi_blob            => v_img_blob,
                    pi_filename        => v_img_name,
                    pi_mime_type       => v_img_mime,
                    pi_id_professional => pi_prof_id,
                    pi_id_organization => v_org_id
                );
            END IF;

            COMMIT;
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('message', 'Invitación pendiente actualizada correctamente.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        -- Miembro activo: credenciales globales solo las gestiona el propio usuario
        BEGIN
            SELECT pu.email, pu.apex_user_name
              INTO v_current_email, v_current_username
              FROM org_member m
              JOIN platform_user pu ON pu.id_platform_user = m.platform_user_id
             WHERE m.id_org_member = v_usr_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := pkg_aox_util.c_not_found_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'No se encontró la cuenta vinculada al profesional.');
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        IF v_password IS NOT NULL AND trim(v_password) IS NOT NULL THEN
            po_status_code := pkg_aox_util.c_forbidden_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'No puedes cambiar la contraseña de otro usuario. Debe usar recuperación de contraseña desde su cuenta.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        IF v_email IS NOT NULL
           AND trim(v_email) IS NOT NULL
           AND lower(trim(v_email)) <> lower(trim(v_current_email)) THEN
            po_status_code := pkg_aox_util.c_forbidden_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'No puedes cambiar el correo de acceso de otro usuario. Es una credencial global de la plataforma.');
            v_error := json_object_t();
            v_error.put('field', 'email');
            v_error.put('message', 'El correo de acceso no puede modificarse desde la organización.');
            v_validation_errors := json_array_t();
            v_validation_errors.append(v_error);
            v_response_json.put('errors', v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        IF v_username IS NOT NULL
           AND trim(v_username) IS NOT NULL
           AND upper(trim(v_username)) <> upper(trim(v_current_username)) THEN
            po_status_code := pkg_aox_util.c_forbidden_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'No puedes cambiar el nombre de usuario de otro usuario.');
            v_error := json_object_t();
            v_error.put('field', 'apex_user_name');
            v_error.put('message', 'El nombre de usuario no puede modificarse desde la organización.');
            v_validation_errors := json_array_t();
            v_validation_errors.append(v_error);
            v_response_json.put('errors', v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        -- Slug único (excluye otros inactivos; el propio registro inactivo puede conservarlo al reactivar).
        IF v_slug IS NOT NULL THEN
            SELECT COUNT(*) INTO v_user_count
            FROM professional
            WHERE profile_slug = TRIM(v_slug)
              AND org_id_organization = v_org_id
              AND id_professional != pi_prof_id
              AND (is_active = 1 OR usr_id_user IS NULL);

            IF v_user_count > 0 THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                v_response_json.put('status', 'error');

                v_error := json_object_t();
                v_error.put('field', 'profile_slug');
                v_error.put('message', 'Este enlace ya está en uso por otro profesional de tu organización.');
                v_validation_errors.append(v_error);

                v_response_json.put('message', 'Errores de validación.');
                v_response_json.put('errors', v_validation_errors);
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;
        END IF;

        v_caller_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        SELECT m.rol_id_role, m.is_active, p.is_active
          INTO v_current_role_id, v_current_user_active, v_current_prof_active
          FROM org_member m
          JOIN professional p ON p.usr_id_user = m.id_org_member
         WHERE m.id_org_member = v_usr_id;

        IF v_usr_id = v_caller_user_id AND v_current_role_id = v_admin_role_id THEN
            IF v_role_id IS NOT NULL AND v_role_id > 0 AND v_role_id <> v_current_role_id THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                v_response_json.put('status'  , 'error');
                v_response_json.put('message' , 'No puedes modificar tu propio rol de administrador.');

                v_error := json_object_t();
                v_error.put('field'   , 'rol_id_role');
                v_error.put('message' , 'No puedes modificar tu propio rol de administrador.');
                v_validation_errors := json_array_t();
                v_validation_errors.append(v_error);
                v_response_json.put('errors'  , v_validation_errors);
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            IF v_user_active IS NOT NULL AND v_user_active <> v_current_user_active THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                v_response_json.put('status'  , 'error');
                v_response_json.put('message' , 'No puedes modificar tu propio estado de acceso como administrador.');

                v_error := json_object_t();
                v_error.put('field'   , 'user_is_active');
                v_error.put('message' , 'No puedes modificar tu propio estado de acceso como administrador.');
                v_validation_errors := json_array_t();
                v_validation_errors.append(v_error);
                v_response_json.put('errors'  , v_validation_errors);
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            IF v_prof_active IS NOT NULL AND v_prof_active <> v_current_prof_active THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                v_response_json.put('status'  , 'error');
                v_response_json.put('message' , 'No puedes modificar tu propia visibilidad como administrador.');

                v_error := json_object_t();
                v_error.put('field'   , 'prof_is_active');
                v_error.put('message' , 'No puedes modificar tu propia visibilidad como administrador.');
                v_validation_errors := json_array_t();
                v_validation_errors.append(v_error);
                v_response_json.put('errors'  , v_validation_errors);
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;
        END IF;

        -- INICIO DE TRANSACCIÓN DML

        UPDATE org_member
        SET is_active   = NVL(v_user_active, is_active),
            rol_id_role = NVL(v_role_id, rol_id_role)
        WHERE id_org_member = v_usr_id;

        -- 6. Actualizar Profesional
        UPDATE professional
        SET display_name      = TRIM(v_display_name),
            phone_number      = TRIM(v_phone),
            spe_id_specialty  = v_specialty_id,
            profile_slug      = NVL(TRIM(v_slug), profile_slug),
            is_active         = NVL(v_prof_active, is_active)
        WHERE id_professional = pi_prof_id;

        -- 7. Actualizar Servicios Asociados (Estrategia: Borrar y Reemplazar)
        IF v_services_arr IS NOT NULL THEN
            -- Primero limpiamos los servicios anteriores de este profesional
            DELETE FROM professional_service
            WHERE pro_id_professional = pi_prof_id AND org_id_organization = v_org_id;

            -- Luego insertamos la nueva lista enviada desde el Tom Select
            FOR i IN 0 .. v_services_arr.get_size() - 1 LOOP
                v_ser_id := v_services_arr.get_number(i);

                INSERT INTO professional_service (org_id_organization, pro_id_professional, ser_id_service)
                VALUES (v_org_id, pi_prof_id, v_ser_id);
            END LOOP;
        END IF;

        -- 8. PROCESAMIENTO DE LA IMAGEN (Bucket OCI)
        -- Si enviaron una imagen nueva en Base64, la procesamos.
        IF v_img_base64 IS NOT NULL THEN
            v_img_blob := apex_web_service.clobbase642blob(v_img_base64);

            pkg_aox_bucket.pr_upload_profile_image(
                pi_blob            => v_img_blob,
                pi_filename        => v_img_name,
                pi_mime_type       => v_img_mime,
                pi_id_professional => pi_prof_id,
                pi_id_organization => v_org_id
            );
        END IF;

        -- Consolidar la transacción si todo salió bien
        COMMIT;

        -- 8. Respuesta Exitosa
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Profesional y usuario actualizados correctamente.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_update_prof_and_user;

    -- Procedimiento: Obtener Profesional por ID (GET)
    PROCEDURE pr_get_prof_and_user(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();

        v_prof_obj      json_object_t;
        v_user_obj      json_object_t;
        v_spec_obj      json_object_t;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- Utilizamos el mismo JOIN robusto del listado
        FOR rec IN (
            SELECT
                p.id_professional,
                p.profile_slug,
                p.profile_image_url,
                p.phone_number,
                p.is_active AS prof_is_active,
                p.created_at AS prof_created_at,
                p.usr_id_user,
                NVL(u.id_user, 0) AS id_user,
                NVL(u.apex_user_name, i.apex_user_name) AS apex_user_name,
                NVL(p.display_name, i.display_name) AS display_name,
                NVL(u.email, i.invite_email) AS email,
                NVL(u.rol_id_role, i.rol_id_role) AS rol_id_role,
                NVL(u.is_active, 0) AS user_is_active,
                CASE WHEN p.usr_id_user IS NULL THEN 'pending_invite' ELSE 'active' END AS membership_status,
                i.status AS invitation_status,
                s.id_specialty,
                s.name AS specialty_name
            FROM professional p
            LEFT JOIN app_user u ON p.usr_id_user = u.id_user
            LEFT JOIN org_invitation i
                   ON i.pro_id_professional = p.id_professional
                  AND i.status = 'PENDING'
            LEFT JOIN specialty s ON p.spe_id_specialty = s.id_specialty
            WHERE p.id_professional     = pi_prof_id
              AND p.org_id_organization = v_org_id
        ) LOOP
            v_prof_obj := json_object_t();
            v_prof_obj.put('id_professional'  , rec.id_professional);
            v_prof_obj.put('display_name'     , rec.display_name);
            v_prof_obj.put('profile_slug'     , rec.profile_slug);
            v_prof_obj.put('profile_image_url', rec.profile_image_url);
            v_prof_obj.put('phone_number'     , rec.phone_number);
            v_prof_obj.put('is_active'        , rec.prof_is_active);
            v_prof_obj.put('created_at'       , TO_CHAR(rec.prof_created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            v_prof_obj.put('membership_status', rec.membership_status);
            IF rec.invitation_status IS NOT NULL THEN
                v_prof_obj.put('invitation_status', rec.invitation_status);
            END IF;

            v_user_obj := json_object_t();
            v_user_obj.put('id_user'        , CASE WHEN rec.id_user = 0 THEN NULL ELSE rec.id_user END);
            v_user_obj.put('apex_user_name' , rec.apex_user_name);
            v_user_obj.put('email'          , rec.email);
            v_user_obj.put('rol_id_role'    , rec.rol_id_role);
            v_user_obj.put('is_active'      , rec.user_is_active);
            v_prof_obj.put('user'           , v_user_obj);

            IF rec.id_specialty IS NOT NULL THEN
                v_spec_obj := json_object_t();
                v_spec_obj.put('id_specialty' , rec.id_specialty);
                v_spec_obj.put('name'         , rec.specialty_name);
                v_prof_obj.put('specialty'    , v_spec_obj);
            ELSE
                v_prof_obj.put('specialty'    , '');
            END IF;

            -- ?? AQUI ESTÁ LA MAGIA: Buscamos los servicios ANTES de devolver la respuesta
            DECLARE
                v_assigned_services json_array_t := json_array_t();
            BEGIN
                FOR serv_rec IN (
                    SELECT ser_id_service
                    FROM professional_service
                    WHERE pro_id_professional = pi_prof_id
                ) LOOP
                    v_assigned_services.append(serv_rec.ser_id_service);
                END LOOP;

                -- Se lo añadimos al JSON del profesional
                v_prof_obj.put('services', v_assigned_services);
            END;
            -- ?? FIN DEL BLOQUE DE SERVICIOS

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('data'  , v_prof_obj);
            po_response_body := v_response_json.to_clob();

            RETURN; -- Ahora sí, salimos con el JSON completo y los servicios integrados.
        END LOOP;

        -- Si el cursor no encontró nada (solo llega aquí si no hizo el RETURN de arriba)
        po_status_code := pkg_aox_util.c_not_found_code;
        v_response_json.put('status'  , 'error');
        v_response_json.put('message' , 'Profesional no encontrado.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_prof_and_user;

    -- Procedimiento: Cancelar invitación pendiente (DELETE)
    --
    -- Estrategia:
    --   - Solo aplica a profesionales con invitación aún no aceptada (usr_id_user IS NULL).
    --   - Miembros activos o inactivos se gestionan con "Desactivar / Reactivar"
    --     a través de pr_update_prof_and_user (campos is_active en professional y org_member).
    --   - platform_user es identidad global y NUNCA se toca desde aquí.
    PROCEDURE pr_delete_prof_and_user(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_usr_id        NUMBER;
        v_response_json json_object_t := json_object_t();
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- 1. Verificar que el profesional existe y pertenece a esta organización
        BEGIN
            SELECT usr_id_user
              INTO v_usr_id
              FROM professional
             WHERE id_professional   = pi_prof_id
               AND org_id_organization = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := pkg_aox_util.c_not_found_code;
                v_response_json.put('status'  , 'error');
                v_response_json.put('message' , 'Profesional no encontrado o no pertenece a su organización.');
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        -- 2. Solo se puede cancelar si la invitación aún no fue aceptada (sin membresía real).
        --    Los miembros activos o inactivos se gestionan con Desactivar / Reactivar.
        IF v_usr_id IS NOT NULL THEN
            po_status_code := pkg_aox_util.c_conflict_code;
            v_response_json.put('status'     , 'error');
            v_response_json.put('deactivate' , 1);
            v_response_json.put('message'    , 'Este profesional ya tiene una cuenta activa. Usá "Desactivar" para quitarle el acceso y visibilidad, o "Reactivar" para restaurarlo.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        -- 3. Invitación pendiente: cancelar y limpiar el registro provisional
        UPDATE org_invitation
           SET status = 'CANCELLED'
         WHERE pro_id_professional = pi_prof_id
           AND status = 'PENDING';

        DELETE FROM professional_service
         WHERE pro_id_professional = pi_prof_id
           AND org_id_organization = v_org_id;

        pkg_aox_bucket.pr_delete_profile_image(pi_prof_id);

        DELETE FROM professional
         WHERE id_professional = pi_prof_id;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Invitación cancelada y registro provisional eliminado correctamente.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_delete_prof_and_user;

    -- Procedimiento: Sugerir Slug Único (GET)
    PROCEDURE pr_suggest_profile_slug(
        pi_auth_header   IN  VARCHAR2,
        pi_full_name     IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();

        v_base_slug     VARCHAR2(200);
        v_final_slug    VARCHAR2(200);
        v_count         NUMBER;
    BEGIN
        -- 1. Validar el token
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        IF pi_full_name IS NULL OR TRIM(pi_full_name) = '' THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Debe proporcionar un nombre para generar el slug.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        -- 2. Generar el slug base usando tu función de utilidad
        v_base_slug   := pkg_aox_util.fn_generate_slug(pi_full_name);
        v_final_slug  := v_base_slug;

        -- 3. Verificar si ya existe en esta organización (activos o invitaciones pendientes)
        SELECT
          COUNT(*)
        INTO
          v_count
        FROM professional
        WHERE profile_slug = v_final_slug
          AND org_id_organization = v_org_id
          AND (is_active = 1 OR usr_id_user IS NULL);

        -- 4. Si existe, le agregamos el sufijo aleatorio (igual que en tu trigger)
        IF v_count > 0 THEN
            v_final_slug := v_final_slug || '-' || TO_CHAR(TRUNC(DBMS_RANDOM.VALUE(10, 99)));
        END IF;

        -- 5. Devolver el slug sugerido
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('slug'  , v_final_slug);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_suggest_profile_slug;

    PROCEDURE pr_list_professionals_lov(
        pi_auth_header   IN  VARCHAR2,
        pi_only_me       IN  NUMBER DEFAULT 0,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_user_id       NUMBER;
        v_my_prof_id    NUMBER := NULL;

        v_response_json json_object_t := json_object_t();
        v_data_arr      json_array_t  := json_array_t();
        v_prof_obj      json_object_t;
    BEGIN
        -- 1. Obtenemos la Organización del Token
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- 2. Lógica de la Bandera "Only Me"
        IF pi_only_me = 1 THEN
            v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

            BEGIN
                -- Buscamos el ID del profesional ligado a este usuario logueado
                SELECT id_professional INTO v_my_prof_id
                FROM professional
                WHERE usr_id_user = v_user_id AND org_id_organization = v_org_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    -- Si no tiene perfil de profesional, forzamos un ID irreal para que devuelva vacío
                    v_my_prof_id := -1;
            END;
        END IF;

        -- 3. Consulta Base
        FOR rec IN (
            SELECT
                p.id_professional,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS display_name,
                s.name as specialty_name
            FROM professional p
            JOIN app_user u ON p.usr_id_user            = u.id_user
            LEFT JOIN specialty s ON p.spe_id_specialty = s.id_specialty
            WHERE p.org_id_organization                 = v_org_id
              AND p.is_active = 1
              AND u.is_active = 1
              -- Filtro mágico: Si bandera es 0 ignora esto, si es 1 filtra por el ID encontrado
              AND ((pi_only_me = 0 OR pi_only_me IS NULL) OR p.id_professional = v_my_prof_id)
              AND u.rol_id_role in (pkg_aox_util.fn_rol('ADMIN'),pkg_aox_util.fn_rol('PROFESIONAL'))
            ORDER BY display_name ASC
        ) LOOP
            v_prof_obj := json_object_t();
            v_prof_obj.put('id_professional'  , rec.id_professional);
            v_prof_obj.put('display_name'     , rec.display_name);
            v_prof_obj.put('full_name'        , rec.display_name);
            v_prof_obj.put('specialty'        , NVL(rec.specialty_name, 'Sin especialidad'));

            DECLARE
                v_assigned_services json_array_t := json_array_t();
            BEGIN
                FOR serv_rec IN (
                    SELECT ps.ser_id_service
                      FROM professional_service ps
                     WHERE ps.pro_id_professional = rec.id_professional
                       AND ps.org_id_organization = v_org_id
                     ORDER BY ps.ser_id_service
                ) LOOP
                    v_assigned_services.append(serv_rec.ser_id_service);
                END LOOP;
                v_prof_obj.put('services', v_assigned_services);
            END;

            v_data_arr.append(v_prof_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_professionals_lov;

END pkg_aox_professional_api;
/

