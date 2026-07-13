PROMPT CREATE OR REPLACE PACKAGE pkg_aox_user_api
CREATE OR REPLACE PACKAGE pkg_aox_user_api IS

    -- Obtener la información del usuario logueado (Mi Perfil)
    PROCEDURE pr_get_me(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_update_me(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_suggest_public_slug(
        pi_auth_header   IN  VARCHAR2,
        pi_full_name     IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_change_password(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );
END pkg_aox_user_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_user_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_user_api IS

    -- 1) GET /me
    PROCEDURE pr_get_me(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id         NUMBER;
        v_org_id          NUMBER;
        v_role_id         NUMBER;

        v_response_json json_object_t := json_object_t();
        v_user_obj      json_object_t := json_object_t();
        v_public_obj    json_object_t := json_object_t();
        v_prof_obj      json_object_t;
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF NVL(v_user_id, 0) <= 0 OR NVL(v_org_id, 0) <= 0 OR NVL(v_role_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Token inválido o sesión no autorizada.');
        END IF;

        FOR rec IN (
            SELECT
                u.id_user,
                pu.first_name,
                pu.last_name,
                pu.email,
                u.rol_id_role,
                pu.public_slug,
                pu.profile_image_url,
                p.id_professional,
                p.display_name,
                p.profile_slug,
                p.phone_number,
                s.name AS specialty_name
            FROM app_user u
            JOIN org_member m
              ON m.id_org_member = u.id_user
            JOIN platform_user pu
              ON pu.id_platform_user = m.platform_user_id
            LEFT JOIN professional p
                   ON p.usr_id_user         = u.id_user
                  AND p.org_id_organization = v_org_id
            LEFT JOIN specialty s
                   ON s.id_specialty        = p.spe_id_specialty
            WHERE u.id_user = v_user_id
        ) LOOP
            v_user_obj.put('id_user'    , rec.id_user);
            v_user_obj.put('first_name' , rec.first_name);
            v_user_obj.put('last_name'  , rec.last_name);
            v_user_obj.put('email'      , rec.email);
            v_user_obj.put('role_id'    , rec.rol_id_role);
            v_user_obj.put('org_id'     , v_org_id);

            v_public_obj.put('public_slug', NVL(rec.public_slug, ''));
            v_public_obj.put('image_url'  , NVL(rec.profile_image_url, ''));
            v_user_obj.put('public_profile', v_public_obj);

            IF rec.id_professional IS NOT NULL THEN
                v_prof_obj := json_object_t();
                v_prof_obj.put('id_professional', rec.id_professional);
                v_prof_obj.put('display_name'   , NVL(rec.display_name, ''));
                v_prof_obj.put('profile_slug'   , NVL(rec.profile_slug, ''));
                v_prof_obj.put('phone_number'   , rec.phone_number);
                v_prof_obj.put('specialty'      , NVL(rec.specialty_name, 'Sin especialidad'));
                v_user_obj.put('professional_profile', v_prof_obj);
            END IF;

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('data', v_user_obj);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END LOOP;

        po_status_code := pkg_aox_util.c_not_found_code;
        v_response_json := json_object_t();
        v_response_json.put('status', 'error');
        v_response_json.put('message', 'Usuario no encontrado en la base de datos.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_me;

    PROCEDURE pr_update_me(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id            NUMBER;
        v_org_id             NUMBER;
        v_platform_user_id   NUMBER;
        v_prof_id            NUMBER := NULL;

        v_json_req      json_object_t;
        v_response_json json_object_t := json_object_t();

        v_validation_errors json_array_t := json_array_t();
        v_error             json_object_t;
        v_user_count        NUMBER;

        v_first_name    VARCHAR2(100);
        v_last_name     VARCHAR2(100);
        v_phone         VARCHAR2(50);
        v_display_name  VARCHAR2(150);
        v_profile_slug  VARCHAR2(100);
        v_public_slug   VARCHAR2(100);

        v_img_base64    CLOB;
        v_img_name      VARCHAR2(255);
        v_img_mime      VARCHAR2(100);
        v_img_blob      BLOB;
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        IF NVL(v_user_id, 0) <= 0 OR NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Token inválido o sesión no autorizada.');
        END IF;

        BEGIN
            SELECT m.platform_user_id
              INTO v_platform_user_id
              FROM org_member m
             WHERE m.id_org_member = v_user_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20004, 'Usuario no encontrado.');
        END;

        BEGIN
            v_json_req := json_object_t.parse(pi_body);

            IF v_json_req.has('first_name') THEN
                v_first_name := TRIM(v_json_req.get_string('first_name'));
            END IF;

            IF v_json_req.has('last_name') THEN
                v_last_name := TRIM(v_json_req.get_string('last_name'));
            END IF;

            IF v_json_req.has('phone_number') THEN
                v_phone := TRIM(v_json_req.get_string('phone_number'));
            END IF;

            IF v_json_req.has('display_name') THEN
                v_display_name := TRIM(v_json_req.get_string('display_name'));
            END IF;

            IF v_json_req.has('profile_slug') THEN
                v_profile_slug := TRIM(LOWER(v_json_req.get_string('profile_slug')));
            END IF;

            IF v_json_req.has('public_slug') THEN
                v_public_slug := TRIM(LOWER(v_json_req.get_string('public_slug')));
            END IF;

            IF v_json_req.has('image_base64') THEN
                v_img_base64 := v_json_req.get_clob('image_base64');
            END IF;

            IF v_json_req.has('image_name') THEN
                v_img_name := TRIM(v_json_req.get_string('image_name'));
            END IF;

            IF v_json_req.has('image_mime') THEN
                v_img_mime := TRIM(LOWER(v_json_req.get_string('image_mime')));
            END IF;

        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20003, 'JSON inválido o malformado.');
        END;

        SELECT MAX(id_professional)
          INTO v_prof_id
          FROM professional
         WHERE usr_id_user         = v_user_id
           AND org_id_organization = v_org_id;

        IF v_public_slug IS NOT NULL THEN
            v_public_slug := pkg_aox_util.fn_generate_slug(v_public_slug);

            IF v_public_slug IS NULL OR LENGTH(v_public_slug) < 2 THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_error := json_object_t();
                v_error.put('field', 'public_slug');
                v_error.put('message', 'El enlace personal debe tener al menos 2 caracteres válidos.');
                v_validation_errors.append(v_error);
                v_response_json.put('message', 'Errores de validación.');
                v_response_json.put('errors', v_validation_errors);
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            SELECT COUNT(*)
              INTO v_user_count
              FROM platform_user
             WHERE lower(trim(public_slug)) = lower(trim(v_public_slug))
               AND id_platform_user <> v_platform_user_id;

            IF v_user_count > 0 THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                v_response_json.put('status', 'error');
                v_error := json_object_t();
                v_error.put('field', 'public_slug');
                v_error.put('message', 'Este enlace ya está en uso. Elegí otro.');
                v_validation_errors.append(v_error);
                v_response_json.put('message', 'Errores de validación.');
                v_response_json.put('errors', v_validation_errors);
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;
        END IF;

        UPDATE platform_user pu
           SET first_name = CASE WHEN v_first_name IS NOT NULL THEN v_first_name ELSE pu.first_name END,
               last_name  = CASE WHEN v_last_name  IS NOT NULL THEN v_last_name  ELSE pu.last_name  END,
               public_slug = CASE WHEN v_public_slug IS NOT NULL THEN v_public_slug ELSE pu.public_slug END
         WHERE pu.id_platform_user = v_platform_user_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Usuario no encontrado.');
        END IF;

        IF v_prof_id IS NOT NULL THEN
            UPDATE professional
               SET phone_number = CASE WHEN v_phone IS NOT NULL THEN v_phone ELSE phone_number END,
                   display_name = CASE
                       WHEN v_display_name IS NOT NULL AND TRIM(v_display_name) IS NOT NULL
                       THEN v_display_name
                       ELSE display_name
                   END,
                   profile_slug = CASE
                       WHEN v_profile_slug IS NOT NULL AND TRIM(v_profile_slug) IS NOT NULL
                       THEN pkg_aox_util.fn_generate_slug(v_profile_slug)
                       ELSE profile_slug
                   END
             WHERE id_professional = v_prof_id;
        END IF;

        IF v_img_base64 IS NOT NULL AND DBMS_LOB.getlength(v_img_base64) > 0 THEN
            v_img_base64 := REGEXP_REPLACE(v_img_base64, '^\s*data:[^,]+,', '');
            v_img_blob := apex_web_service.clobbase642blob(v_img_base64);

            pkg_aox_bucket.pr_upload_platform_user_avatar(
                pi_blob             => v_img_blob,
                pi_filename         => NVL(v_img_name, 'avatar.jpg'),
                pi_mime_type        => NVL(v_img_mime, 'image/jpeg'),
                pi_id_platform_user => v_platform_user_id
            );
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json := json_object_t();
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Perfil actualizado correctamente.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;

            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE = -20003 THEN pkg_aox_util.c_bad_request_code
                WHEN SQLCODE = -20004 THEN pkg_aox_util.c_not_found_code
                WHEN SQLCODE = -1 THEN pkg_aox_util.c_conflict_code
                ELSE pkg_aox_util.c_internal_error_code
            END;

            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => CASE
                    WHEN SQLCODE = -1 THEN 'El enlace personal ya está en uso. Por favor, elige otro.'
                    WHEN SQLCODE = -20003 THEN 'JSON inválido o malformado.'
                    WHEN SQLCODE = -20004 THEN 'Usuario no encontrado.'
                    WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN 'No autorizado.'
                    ELSE pkg_aox_util.fn_clean_sqlerrm(SQLERRM)
                END,
                po_response_body => po_response_body
            );
    END pr_update_me;

    PROCEDURE pr_suggest_public_slug(
        pi_auth_header   IN  VARCHAR2,
        pi_full_name     IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id            NUMBER;
        v_platform_user_id   NUMBER;
        v_response_json      json_object_t := json_object_t();
        v_final_slug         VARCHAR2(100);
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        IF NVL(v_user_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Token inválido o sesión no autorizada.');
        END IF;

        IF pi_full_name IS NULL OR TRIM(pi_full_name) = '' THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Debe proporcionar un nombre para generar el slug.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        SELECT m.platform_user_id
          INTO v_platform_user_id
          FROM org_member m
         WHERE m.id_org_member = v_user_id;

        v_final_slug := pkg_aox_util.fn_build_platform_user_public_slug(
            pi_first_name       => pi_full_name,
            pi_last_name        => NULL,
            pi_id_platform_user => v_platform_user_id
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('slug'  , v_final_slug);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_suggest_public_slug;

    -- 3. Cambiar Contraseña (PUT /me/change-password)
    PROCEDURE pr_change_password(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id       NUMBER;
        v_json_req      json_object_t;
        v_response_json json_object_t := json_object_t();

        v_current_pass  VARCHAR2(100);
        v_new_pass      VARCHAR2(100);

        v_stored_hash   VARCHAR2(255);
        v_current_hash  VARCHAR2(255);
        v_new_hash      VARCHAR2(255);
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req     := json_object_t.parse(pi_body);
            v_current_pass := v_json_req.get_string('current_password');
            v_new_pass     := v_json_req.get_string('new_password');
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20003, 'JSON inválido o malformado.');
        END;

        IF v_current_pass IS NULL OR v_new_pass IS NULL THEN
            RAISE_APPLICATION_ERROR(-20004, 'Debe proveer la contraseña actual y la nueva.');
        END IF;

        BEGIN
            SELECT password_hash
              INTO v_stored_hash
              FROM platform_user pu
             INNER JOIN org_member m ON m.platform_user_id = pu.id_platform_user
             WHERE m.id_org_member = v_user_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20001, 'Usuario no encontrado.');
        END;

        v_current_hash := pkg_aox_util.fn_hash_password(v_current_pass);

        IF v_current_hash != v_stored_hash THEN
            RAISE_APPLICATION_ERROR(-20005, 'La contraseña actual es incorrecta.');
        END IF;

        v_new_hash := pkg_aox_util.fn_hash_password(v_new_pass);

        UPDATE platform_user pu
           SET password_hash = v_new_hash
         WHERE pu.id_platform_user = (
            SELECT m.platform_user_id FROM org_member m WHERE m.id_org_member = v_user_id
        );

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Contraseña actualizada correctamente.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_change_password;

END pkg_aox_user_api;
/
