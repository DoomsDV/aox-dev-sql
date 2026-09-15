PROMPT CREATE OR REPLACE PACKAGE pkg_aox_permission_api
CREATE OR REPLACE PACKAGE pkg_aox_permission_api IS

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

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_permission_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_permission_api IS

    c_cap_permissions_manage CONSTANT VARCHAR2(40) := 'permissions.manage';

    FUNCTION fn_is_base_role(pi_role_id IN NUMBER) RETURN BOOLEAN IS
        v_name role.name%TYPE;
    BEGIN
        SELECT UPPER(name)
          INTO v_name
          FROM role
         WHERE id_role = pi_role_id
           AND is_active = 1;

        RETURN v_name IN ('ADMIN', 'PROFESIONAL', 'RECEPCIONISTA');
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN FALSE;
    END fn_is_base_role;

    FUNCTION fn_effective_grant(
        pi_org_id  IN NUMBER,
        pi_role_id IN NUMBER,
        pi_cap_id  IN NUMBER
    ) RETURN NUMBER IS
        v_granted NUMBER;
    BEGIN
        BEGIN
            SELECT is_granted
              INTO v_granted
              FROM org_role_capability
             WHERE org_id_organization = pi_org_id
               AND rol_id_role         = pi_role_id
               AND cap_id_capability   = pi_cap_id;
            RETURN CASE WHEN v_granted = 1 THEN 1 ELSE 0 END;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                NULL;
        END;

        BEGIN
            SELECT is_granted
              INTO v_granted
              FROM role_capability_default
             WHERE rol_id_role       = pi_role_id
               AND cap_id_capability = pi_cap_id;
            RETURN CASE WHEN v_granted = 1 THEN 1 ELSE 0 END;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN 0;
        END;
    END fn_effective_grant;

    FUNCTION fn_has_capability(
        pi_org_id  IN NUMBER,
        pi_role_id IN NUMBER,
        pi_code    IN VARCHAR2
    ) RETURN NUMBER IS
        v_cap_id      capability.id_capability%TYPE;
        v_active      capability.is_active%TYPE;
        v_entitlement capability.requires_entitlement%TYPE;
        v_granted     NUMBER;
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 OR NVL(pi_role_id, 0) <= 0 OR TRIM(pi_code) IS NULL THEN
            RETURN 0;
        END IF;

        BEGIN
            SELECT id_capability, is_active, requires_entitlement
              INTO v_cap_id, v_active, v_entitlement
              FROM capability
             WHERE code = LOWER(TRIM(pi_code));
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN 0;
        END;

        IF v_active = 0 THEN
            RETURN 0;
        END IF;

        v_granted := fn_effective_grant(pi_org_id, pi_role_id, v_cap_id);
        IF v_granted = 0 THEN
            RETURN 0;
        END IF;

        IF v_entitlement IS NOT NULL THEN
            IF pkg_aox_subscription_api.fn_org_has_feature(pi_org_id, v_entitlement) = 0 THEN
                RETURN 0;
            END IF;
        END IF;

        RETURN 1;
    END fn_has_capability;

    PROCEDURE pr_assert_capability(
        pi_org_id  IN NUMBER,
        pi_role_id IN NUMBER,
        pi_code    IN VARCHAR2,
        pi_message IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        IF fn_has_capability(pi_org_id, pi_role_id, pi_code) = 0 THEN
            RAISE_APPLICATION_ERROR(
                -20005,
                NVL(NULLIF(TRIM(pi_message), ''), 'No tienes permisos para esta accion.')
            );
        END IF;
    END pr_assert_capability;

    PROCEDURE pr_require_session(
        pi_auth_header IN  VARCHAR2,
        po_org_id      OUT NUMBER,
        po_user_id     OUT NUMBER,
        po_role_id     OUT NUMBER
    ) IS
    BEGIN
        po_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        po_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        po_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF NVL(po_org_id, 0) <= 0 OR NVL(po_user_id, 0) <= 0 OR NVL(po_role_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_session,
                'Token invalido o sin organizacion asociada.'
            );
        END IF;
    END pr_require_session;

    FUNCTION fn_role_name(pi_role_id IN NUMBER) RETURN VARCHAR2 IS
        v_name role.name%TYPE;
    BEGIN
        SELECT name INTO v_name FROM role WHERE id_role = pi_role_id;
        RETURN v_name;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_role_name;

    PROCEDURE pr_get_my_capabilities(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id     NUMBER;
        v_user_id    NUMBER;
        v_role_id    NUMBER;
        v_resp       json_object_t := json_object_t();
        v_data       json_object_t := json_object_t();
        v_caps       json_array_t  := json_array_t();
        v_ents       json_object_t := json_object_t();
    BEGIN
        pr_require_session(pi_auth_header, v_org_id, v_user_id, v_role_id);

        FOR rec IN (
            SELECT c.code, c.requires_entitlement
              FROM capability c
             WHERE c.is_active = 1
             ORDER BY c.sort_order, c.code
        ) LOOP
            IF rec.requires_entitlement IS NOT NULL AND NOT v_ents.has(rec.requires_entitlement) THEN
                v_ents.put(
                    rec.requires_entitlement,
                    pkg_aox_subscription_api.fn_org_has_feature(v_org_id, rec.requires_entitlement) = 1
                );
            END IF;

            IF fn_has_capability(v_org_id, v_role_id, rec.code) = 1 THEN
                v_caps.append(rec.code);
            END IF;
        END LOOP;

        v_data.put('role_id', v_role_id);
        v_data.put('role_name', fn_role_name(v_role_id));
        v_data.put('capabilities', v_caps);
        v_data.put('entitlements', v_ents);

        v_resp.put('status', 'success');
        v_resp.put('data', v_data);
        po_status_code := pkg_aox_util.c_success_ok_code;
        po_response_body := v_resp.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_my_capabilities;

    PROCEDURE pr_get_matrix(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id     NUMBER;
        v_user_id    NUMBER;
        v_role_id    NUMBER;
        v_resp       json_object_t := json_object_t();
        v_data       json_object_t := json_object_t();
        v_roles      json_array_t  := json_array_t();
        v_catalog    json_array_t  := json_array_t();
        v_grants     json_object_t := json_object_t();
        v_ents       json_object_t := json_object_t();
        v_role_obj   json_object_t;
        v_cap_obj    json_object_t;
        v_grant_obj  json_object_t;
        v_role_grants json_object_t;
        v_default    NUMBER;
        v_override   NUMBER;
        v_source     VARCHAR2(20);
        v_granted    NUMBER;
    BEGIN
        pr_require_session(pi_auth_header, v_org_id, v_user_id, v_role_id);
        pr_assert_capability(
            v_org_id,
            v_role_id,
            c_cap_permissions_manage,
            'Solo un administrador puede ver la matriz de permisos.'
        );

        FOR r IN (
            SELECT id_role, name
              FROM role
             WHERE UPPER(name) IN ('ADMIN', 'PROFESIONAL', 'RECEPCIONISTA')
               AND is_active = 1
             ORDER BY CASE UPPER(name)
                          WHEN 'ADMIN' THEN 1
                          WHEN 'RECEPCIONISTA' THEN 2
                          ELSE 3
                      END
        ) LOOP
            v_role_obj := json_object_t();
            v_role_obj.put('role_id', r.id_role);
            v_role_obj.put('name', r.name);
            v_role_obj.put('is_base', TRUE);
            v_role_obj.put('deletable', FALSE);
            v_roles.append(v_role_obj);
        END LOOP;

        FOR c IN (
            SELECT id_capability, code, group_code, group_label, label, description,
                   kind, sort_order, requires_entitlement, is_locked
              FROM capability
             WHERE is_active = 1
             ORDER BY sort_order, code
        ) LOOP
            v_cap_obj := json_object_t();
            v_cap_obj.put('code', c.code);
            v_cap_obj.put('group_code', c.group_code);
            v_cap_obj.put('group_label', c.group_label);
            v_cap_obj.put('label', c.label);
            v_cap_obj.put('description', c.description);
            v_cap_obj.put('kind', c.kind);
            v_cap_obj.put('sort_order', c.sort_order);
            v_cap_obj.put('locked', c.is_locked = 1);
            IF c.requires_entitlement IS NOT NULL THEN
                v_cap_obj.put('requires_entitlement', c.requires_entitlement);
                IF NOT v_ents.has(c.requires_entitlement) THEN
                    v_ents.put(
                        c.requires_entitlement,
                        pkg_aox_subscription_api.fn_org_has_feature(v_org_id, c.requires_entitlement) = 1
                    );
                END IF;
                v_cap_obj.put('entitlement_active', v_ents.get_boolean(c.requires_entitlement));
            END IF;
            v_catalog.append(v_cap_obj);
        END LOOP;

        FOR r IN (
            SELECT id_role
              FROM role
             WHERE UPPER(name) IN ('ADMIN', 'PROFESIONAL', 'RECEPCIONISTA')
               AND is_active = 1
        ) LOOP
            v_role_grants := json_object_t();

            FOR c IN (
                SELECT id_capability, code, is_locked
                  FROM capability
                 WHERE is_active = 1
            ) LOOP
                BEGIN
                    SELECT is_granted
                      INTO v_default
                      FROM role_capability_default
                     WHERE rol_id_role = r.id_role
                       AND cap_id_capability = c.id_capability;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        v_default := 0;
                END;

                BEGIN
                    SELECT is_granted
                      INTO v_override
                      FROM org_role_capability
                     WHERE org_id_organization = v_org_id
                       AND rol_id_role = r.id_role
                       AND cap_id_capability = c.id_capability;
                    v_source := 'override';
                    v_granted := v_override;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        v_source := 'default';
                        v_granted := v_default;
                END;

                v_grant_obj := json_object_t();
                v_grant_obj.put('granted', v_granted = 1);
                v_grant_obj.put('default_granted', v_default = 1);
                v_grant_obj.put('source', v_source);
                v_grant_obj.put('locked', c.is_locked = 1 AND r.id_role = pkg_aox_util.fn_rol('ADMIN'));
                v_role_grants.put(c.code, v_grant_obj);
            END LOOP;

            v_grants.put(TO_CHAR(r.id_role), v_role_grants);
        END LOOP;

        v_data.put('roles', v_roles);
        v_data.put('catalog', v_catalog);
        v_data.put('grants', v_grants);
        v_data.put('entitlements', v_ents);

        v_resp.put('status', 'success');
        v_resp.put('data', v_data);
        po_status_code := pkg_aox_util.c_success_ok_code;
        po_response_body := v_resp.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_matrix;

    PROCEDURE pr_put_matrix(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id       NUMBER;
        v_user_id      NUMBER;
        v_role_id      NUMBER;
        v_json         json_object_t;
        v_grants       json_array_t;
        v_item         json_object_t;
        v_target_role  NUMBER;
        v_code         VARCHAR2(80);
        v_granted      NUMBER;
        v_cap_id       NUMBER;
        v_locked       NUMBER;
        v_default      NUMBER;
        v_admin_role   NUMBER := pkg_aox_util.fn_rol('ADMIN');
        v_resp         json_object_t := json_object_t();
        v_count        PLS_INTEGER := 0;
    BEGIN
        pr_require_session(pi_auth_header, v_org_id, v_user_id, v_role_id);
        pr_assert_capability(
            v_org_id,
            v_role_id,
            c_cap_permissions_manage,
            'Solo un administrador puede guardar la matriz de permisos.'
        );
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        BEGIN
            v_json := json_object_t.parse(NVL(pi_body, TO_CLOB('{}')));
            v_grants := v_json.get_array('grants');
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'JSON invalido.');
        END;

        IF v_grants IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El campo grants es obligatorio.');
        END IF;

        FOR i IN 0 .. v_grants.get_size - 1 LOOP
            v_item := TREAT(v_grants.get(i) AS json_object_t);
            BEGIN
                v_target_role := v_item.get_number('role_id');
            EXCEPTION
                WHEN OTHERS THEN
                    RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'role_id invalido.');
            END;
            v_code := LOWER(TRIM(v_item.get_string('code')));

            IF v_item.get_boolean('granted') THEN
                v_granted := 1;
            ELSE
                v_granted := 0;
            END IF;

            IF NOT fn_is_base_role(v_target_role) THEN
                RAISE_APPLICATION_ERROR(-20005, 'Solo se pueden configurar las 3 roles base.');
            END IF;

            BEGIN
                SELECT id_capability, is_locked
                  INTO v_cap_id, v_locked
                  FROM capability
                 WHERE code = v_code
                   AND is_active = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Capability desconocida: ' || v_code);
            END;

            IF v_locked = 1 AND v_target_role = v_admin_role THEN
                v_granted := 1;
            END IF;

            BEGIN
                SELECT is_granted
                  INTO v_default
                  FROM role_capability_default
                 WHERE rol_id_role = v_target_role
                   AND cap_id_capability = v_cap_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_default := 0;
            END;

            IF v_granted = v_default THEN
                DELETE FROM org_role_capability
                 WHERE org_id_organization = v_org_id
                   AND rol_id_role = v_target_role
                   AND cap_id_capability = v_cap_id;
            ELSE
                MERGE INTO org_role_capability t
                USING (
                    SELECT v_org_id AS org_id,
                           v_target_role AS role_id,
                           v_cap_id AS cap_id
                      FROM dual
                ) s
                ON (t.org_id_organization = s.org_id
                    AND t.rol_id_role = s.role_id
                    AND t.cap_id_capability = s.cap_id)
                WHEN MATCHED THEN
                    UPDATE SET
                        is_granted = v_granted,
                        updated_at = CURRENT_TIMESTAMP,
                        updated_by = v_user_id
                WHEN NOT MATCHED THEN
                    INSERT (
                        org_id_organization,
                        rol_id_role,
                        cap_id_capability,
                        is_granted,
                        updated_at,
                        updated_by
                    ) VALUES (
                        s.org_id,
                        s.role_id,
                        s.cap_id,
                        v_granted,
                        CURRENT_TIMESTAMP,
                        v_user_id
                    );
            END IF;

            v_count := v_count + 1;
        END LOOP;

        COMMIT;

        v_resp.put('status', 'success');
        v_resp.put('message', 'Permisos actualizados.');
        v_resp.put('updated', v_count);
        po_status_code := pkg_aox_util.c_success_ok_code;
        po_response_body := v_resp.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_put_matrix;

    PROCEDURE pr_reset_matrix(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_user_id  NUMBER;
        v_role_id  NUMBER;
        v_resp     json_object_t := json_object_t();
        v_deleted  NUMBER;
    BEGIN
        pr_require_session(pi_auth_header, v_org_id, v_user_id, v_role_id);
        pr_assert_capability(
            v_org_id,
            v_role_id,
            c_cap_permissions_manage,
            'Solo un administrador puede restaurar los permisos por defecto.'
        );
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        DELETE FROM org_role_capability
         WHERE org_id_organization = v_org_id;
        v_deleted := SQL%ROWCOUNT;
        COMMIT;

        v_resp.put('status', 'success');
        v_resp.put('message', 'Se restauraron los permisos por defecto.');
        v_resp.put('deleted', v_deleted);
        po_status_code := pkg_aox_util.c_success_ok_code;
        po_response_body := v_resp.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_reset_matrix;

END pkg_aox_permission_api;
/
