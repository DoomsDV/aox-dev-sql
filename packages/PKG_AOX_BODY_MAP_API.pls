PROMPT CREATE OR REPLACE PACKAGE pkg_aox_body_map_api
CREATE OR REPLACE PACKAGE pkg_aox_body_map_api IS

    PROCEDURE pr_get_snapshot(
        pi_auth_header    IN  VARCHAR2,
        pi_customer_id    IN  NUMBER,
        pi_appointment_id IN  NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );

    PROCEDURE pr_put_snapshot(
        pi_auth_header    IN  VARCHAR2,
        pi_customer_id    IN  NUMBER,
        pi_appointment_id IN  NUMBER,
        pi_body           IN  CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );

    PROCEDURE pr_list_snapshots(
        pi_auth_header   IN  VARCHAR2,
        pi_customer_id   IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    FUNCTION fn_mark_count_from_json(
        pi_snapshot_json IN CLOB
    ) RETURN NUMBER;

END pkg_aox_body_map_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_body_map_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_body_map_api IS

    c_iso_fmt CONSTANT VARCHAR2(50) := 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR';
    c_feature CONSTANT VARCHAR2(50) := 'BODY_MAP';

    FUNCTION fn_require_org_id(
        pi_auth_header IN VARCHAR2
    ) RETURN NUMBER IS
        v_org_id NUMBER;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_session,
                'Token inválido o sin organización asociada.'
            );
        END IF;
        RETURN v_org_id;
    END fn_require_org_id;

    PROCEDURE pr_assert_customer_in_org(
        pi_org_id      IN NUMBER,
        pi_customer_id IN NUMBER
    ) IS
        v_dummy NUMBER;
    BEGIN
        IF NVL(pi_customer_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Cliente inválido.');
        END IF;

        SELECT 1
          INTO v_dummy
          FROM customer
         WHERE id_customer = pi_customer_id
           AND org_id_organization = pi_org_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20004, 'Cliente no encontrado.');
    END pr_assert_customer_in_org;

    PROCEDURE pr_assert_appointment_for_customer(
        pi_org_id         IN NUMBER,
        pi_customer_id    IN NUMBER,
        pi_appointment_id IN NUMBER
    ) IS
        v_dummy NUMBER;
    BEGIN
        IF NVL(pi_appointment_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Cita inválida.');
        END IF;

        SELECT 1
          INTO v_dummy
          FROM appointment
         WHERE id_appointment = pi_appointment_id
           AND org_id_organization = pi_org_id
           AND cus_id_customer = pi_customer_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20004, 'Cita no encontrada para este cliente.');
    END pr_assert_appointment_for_customer;

    FUNCTION fn_mark_count_from_json(
        pi_snapshot_json IN CLOB
    ) RETURN NUMBER IS
        v_count NUMBER := 0;
    BEGIN
        IF pi_snapshot_json IS NULL OR DBMS_LOB.getlength(pi_snapshot_json) = 0 THEN
            RETURN 0;
        END IF;

        SELECT COUNT(*)
          INTO v_count
          FROM JSON_TABLE(
                   pi_snapshot_json FORMAT JSON,
                   '$.marks[*]'
                   COLUMNS (dummy NUMBER PATH '$')
               );

        RETURN NVL(v_count, 0);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN 0;
    END fn_mark_count_from_json;

    FUNCTION fn_ts_to_iso(
        pi_ts IN TIMESTAMP WITH TIME ZONE
    ) RETURN VARCHAR2 IS
    BEGIN
        IF pi_ts IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN TO_CHAR(pi_ts, c_iso_fmt);
    END fn_ts_to_iso;

    PROCEDURE pr_get_snapshot(
        pi_auth_header    IN  VARCHAR2,
        pi_customer_id    IN  NUMBER,
        pi_appointment_id IN  NUMBER,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_data          json_object_t := json_object_t();
        v_snapshot      json_object_t;
        v_silhouette    VARCHAR2(10);
        v_json          CLOB;
        v_captured      TIMESTAMP WITH TIME ZONE;
    BEGIN
        v_org_id := fn_require_org_id(pi_auth_header);
        pr_assert_customer_in_org(v_org_id, pi_customer_id);
        pr_assert_appointment_for_customer(v_org_id, pi_customer_id, pi_appointment_id);

        IF pkg_aox_subscription_api.fn_org_has_feature(v_org_id, c_feature) = 0 THEN
            RAISE_APPLICATION_ERROR(-20003, 'Complemento no activo para esta organización.');
        END IF;

        BEGIN
            SELECT silhouette, snapshot_json, captured_at
              INTO v_silhouette, v_json, v_captured
              FROM customer_body_snapshot
             WHERE org_id_organization = v_org_id
               AND cus_id_customer = pi_customer_id
               AND app_id_appointment = pi_appointment_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := pkg_aox_util.c_success_ok_code;
                v_response_json.put('status', 'success');
                v_response_json.put_null('data');
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        v_snapshot := JSON_OBJECT_T.parse(v_json);
        v_data.put('customer_id', pi_customer_id);
        v_data.put('appointment_id', pi_appointment_id);
        v_data.put('silhouette', v_silhouette);
        v_data.put('captured_at', fn_ts_to_iso(v_captured));
        v_data.put('snapshot', v_snapshot);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_data);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_snapshot;

    PROCEDURE pr_put_snapshot(
        pi_auth_header    IN  VARCHAR2,
        pi_customer_id    IN  NUMBER,
        pi_appointment_id IN  NUMBER,
        pi_body           IN  CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_user_id       NUMBER;
        v_response_json json_object_t := json_object_t();
        v_data          json_object_t;
        v_json          json_object_t;
        v_silhouette    VARCHAR2(20);
        v_snapshot_json CLOB;
        v_captured_iso  VARCHAR2(80);
        v_captured_ts   TIMESTAMP WITH TIME ZONE;
        v_app_status    appointment.status%TYPE;
    BEGIN
        v_org_id  := fn_require_org_id(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        pr_assert_customer_in_org(v_org_id, pi_customer_id);
        pr_assert_appointment_for_customer(v_org_id, pi_customer_id, pi_appointment_id);

        SELECT status
          INTO v_app_status
          FROM appointment
         WHERE id_appointment = pi_appointment_id
           AND org_id_organization = v_org_id
           AND cus_id_customer = pi_customer_id;

        IF v_app_status IN ('COMPLETADO', 'CANCELADO') THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'No se puede editar el mapa de una cita cerrada.'
            );
        END IF;

        pkg_aox_subscription_api.pr_assert_org_has_feature(v_org_id, c_feature);
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        IF pi_body IS NULL OR DBMS_LOB.getlength(pi_body) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Cuerpo de solicitud vacío.');
        END IF;

        BEGIN
            v_json := JSON_OBJECT_T.parse(pi_body);
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'JSON inválido o malformado.');
        END;

        v_silhouette := UPPER(TRIM(v_json.get_string('silhouette')));
        IF v_silhouette NOT IN ('NEUTRAL', 'FEMALE', 'MALE', 'CHILD') THEN
            v_silhouette := 'NEUTRAL';
        END IF;

        v_snapshot_json := v_json.to_clob();

        v_captured_iso := TRIM(v_json.get_string('captured_at'));
        IF v_captured_iso IS NOT NULL THEN
            BEGIN
                v_captured_ts := TO_TIMESTAMP_TZ(v_captured_iso, c_iso_fmt);
            EXCEPTION
                WHEN OTHERS THEN
                    v_captured_ts := CURRENT_TIMESTAMP;
            END;
        ELSE
            v_captured_ts := CURRENT_TIMESTAMP;
        END IF;

        MERGE /*+ no_parallel */ INTO customer_body_snapshot t
        USING (
            SELECT v_org_id AS org_id,
                   pi_customer_id AS cus_id,
                   pi_appointment_id AS app_id
              FROM dual
        ) s
        ON (
            t.org_id_organization = s.org_id
            AND t.cus_id_customer = s.cus_id
            AND t.app_id_appointment = s.app_id
        )
        WHEN MATCHED THEN
            UPDATE SET
                silhouette = v_silhouette,
                snapshot_json = v_snapshot_json,
                captured_at = v_captured_ts,
                updated_at = CURRENT_TIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (
                org_id_organization,
                cus_id_customer,
                app_id_appointment,
                silhouette,
                snapshot_json,
                captured_at,
                created_by_user
            ) VALUES (
                v_org_id,
                pi_customer_id,
                pi_appointment_id,
                v_silhouette,
                v_snapshot_json,
                v_captured_ts,
                v_user_id
            );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_data := json_object_t();
        v_data.put('appointment_id', pi_appointment_id);
        v_data.put('mark_count', fn_mark_count_from_json(v_snapshot_json));
        v_response_json.put('data', v_data);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_put_snapshot;

    PROCEDURE pr_list_snapshots(
        pi_auth_header   IN  VARCHAR2,
        pi_customer_id   IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_arr           json_array_t  := json_array_t();
        v_item          json_object_t;
    BEGIN
        v_org_id := fn_require_org_id(pi_auth_header);
        pr_assert_customer_in_org(v_org_id, pi_customer_id);

        IF pkg_aox_subscription_api.fn_org_has_feature(v_org_id, c_feature) = 0 THEN
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('data', v_arr);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        FOR rec IN (
            SELECT app_id_appointment,
                   silhouette,
                   snapshot_json,
                   captured_at
              FROM customer_body_snapshot
             WHERE org_id_organization = v_org_id
               AND cus_id_customer = pi_customer_id
             ORDER BY captured_at DESC
        ) LOOP
            v_item := json_object_t();
            v_item.put('appointment_id', rec.app_id_appointment);
            v_item.put('silhouette', rec.silhouette);
            v_item.put('captured_at', fn_ts_to_iso(rec.captured_at));
            v_item.put('mark_count', fn_mark_count_from_json(rec.snapshot_json));
            v_arr.append(v_item);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_snapshots;

END pkg_aox_body_map_api;
/
