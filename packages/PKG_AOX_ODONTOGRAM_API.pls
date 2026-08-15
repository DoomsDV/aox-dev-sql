PROMPT CREATE OR REPLACE PACKAGE pkg_aox_odontogram_api
CREATE OR REPLACE PACKAGE pkg_aox_odontogram_api IS

    PROCEDURE pr_get_chart(
        pi_auth_header   IN  VARCHAR2,
        pi_customer_id   IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_add_event(
        pi_auth_header   IN  VARCHAR2,
        pi_customer_id   IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_void_event(
        pi_auth_header   IN  VARCHAR2,
        pi_customer_id   IN  NUMBER,
        pi_event_id      IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_odontogram_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_odontogram_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_odontogram_api IS

    c_iso_fmt CONSTANT VARCHAR2(50) := 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR';
    c_feature CONSTANT VARCHAR2(50) := 'ODONTOGRAM_3D';

    FUNCTION fn_ts_to_iso(
        pi_ts IN TIMESTAMP WITH TIME ZONE
    ) RETURN VARCHAR2 IS
    BEGIN
        IF pi_ts IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN TO_CHAR(pi_ts, c_iso_fmt);
    END fn_ts_to_iso;

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
        pi_org_id       IN NUMBER,
        pi_customer_id  IN NUMBER
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

    FUNCTION fn_is_valid_fdi(
        pi_fdi IN NUMBER
    ) RETURN BOOLEAN IS
        v_quad NUMBER;
        v_n    NUMBER;
    BEGIN
        IF pi_fdi IS NULL THEN
            RETURN FALSE;
        END IF;
        v_quad := TRUNC(pi_fdi / 10);
        v_n    := MOD(pi_fdi, 10);
        RETURN v_quad IN (1, 2, 3, 4) AND v_n BETWEEN 1 AND 8;
    END fn_is_valid_fdi;

    FUNCTION fn_json_01(
        pi_obj IN json_object_t,
        pi_key IN VARCHAR2
    ) RETURN NUMBER IS
        v_n NUMBER;
    BEGIN
        IF pi_obj IS NULL OR NOT pi_obj.has(pi_key) OR pi_obj.get(pi_key).is_null THEN
            RETURN 0;
        END IF;

        BEGIN
            v_n := NVL(pi_obj.get_number(pi_key), 0);
        EXCEPTION
            WHEN OTHERS THEN
                DECLARE
                    v_raw VARCHAR2(20);
                BEGIN
                    v_raw := LOWER(TRIM(BOTH '"' FROM pi_obj.get(pi_key).stringify()));
                    IF v_raw IN ('true', '1') THEN
                        RETURN 1;
                    ELSIF v_raw IN ('false', '0') THEN
                        RETURN 0;
                    END IF;
                    v_n := TO_NUMBER(v_raw);
                EXCEPTION
                    WHEN OTHERS THEN
                        RAISE_APPLICATION_ERROR(
                            pkg_aox_util.c_sqlcode_validation,
                            'Cada cara debe ser 0 o 1.'
                        );
                END;
        END;

        IF NVL(v_n, -1) NOT IN (0, 1) THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Cada cara debe ser 0 o 1.'
            );
        END IF;

        RETURN v_n;
    END fn_json_01;

    FUNCTION fn_faces_obj(
        pi_occlusal    IN NUMBER,
        pi_vestibular  IN NUMBER,
        pi_palatal     IN NUMBER,
        pi_mesial      IN NUMBER,
        pi_distal      IN NUMBER
    ) RETURN json_object_t IS
        v_faces json_object_t := json_object_t();
    BEGIN
        v_faces.put('occlusal', NVL(pi_occlusal, 0));
        v_faces.put('vestibular', NVL(pi_vestibular, 0));
        v_faces.put('palatal', NVL(pi_palatal, 0));
        v_faces.put('mesial', NVL(pi_mesial, 0));
        v_faces.put('distal', NVL(pi_distal, 0));
        RETURN v_faces;
    END fn_faces_obj;

    FUNCTION fn_tooth_json(
        pi_tooth_fdi      IN NUMBER,
        pi_finding_code   IN VARCHAR2,
        pi_notes          IN VARCHAR2,
        pi_created_at     IN TIMESTAMP WITH TIME ZONE,
        pi_occlusal       IN NUMBER,
        pi_vestibular     IN NUMBER,
        pi_palatal        IN NUMBER,
        pi_mesial         IN NUMBER,
        pi_distal         IN NUMBER
    ) RETURN json_object_t IS
        v_obj json_object_t := json_object_t();
    BEGIN
        v_obj.put('tooth_fdi', pi_tooth_fdi);
        v_obj.put('finding_code', pi_finding_code);
        IF pi_notes IS NULL THEN
            v_obj.put_null('notes');
        ELSE
            v_obj.put('notes', pi_notes);
        END IF;
        v_obj.put('created_at', fn_ts_to_iso(pi_created_at));
        v_obj.put('faces', fn_faces_obj(
            pi_occlusal, pi_vestibular, pi_palatal, pi_mesial, pi_distal
        ));
        RETURN v_obj;
    END fn_tooth_json;

    FUNCTION fn_event_json(
        pi_id_event       IN NUMBER,
        pi_tooth_fdi      IN NUMBER,
        pi_finding_code   IN VARCHAR2,
        pi_notes          IN VARCHAR2,
        pi_created_at     IN TIMESTAMP WITH TIME ZONE,
        pi_occlusal       IN NUMBER,
        pi_vestibular     IN NUMBER,
        pi_palatal        IN NUMBER,
        pi_mesial         IN NUMBER,
        pi_distal         IN NUMBER
    ) RETURN json_object_t IS
        v_obj json_object_t;
    BEGIN
        v_obj := fn_tooth_json(
            pi_tooth_fdi, pi_finding_code, pi_notes, pi_created_at,
            pi_occlusal, pi_vestibular, pi_palatal, pi_mesial, pi_distal
        );
        v_obj.put('id_event', pi_id_event);
        RETURN v_obj;
    END fn_event_json;

    PROCEDURE pr_get_chart(
        pi_auth_header   IN  VARCHAR2,
        pi_customer_id   IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_entitled      NUMBER := 0;
        v_response_json json_object_t := json_object_t();
        v_data          json_object_t := json_object_t();
        v_teeth         json_array_t  := json_array_t();
        v_events        json_array_t  := json_array_t();
    BEGIN
        v_org_id := fn_require_org_id(pi_auth_header);
        pr_assert_customer_in_org(v_org_id, pi_customer_id);

        v_entitled := pkg_aox_subscription_api.fn_org_has_feature(v_org_id, c_feature);

        IF v_entitled = 1 THEN
            FOR rec IN (
                SELECT id_event,
                       tooth_fdi,
                       finding_code,
                       notes,
                       created_at,
                       face_occlusal,
                       face_vestibular,
                       face_palatal,
                       face_mesial,
                       face_distal
                  FROM (
                        SELECT e.id_event,
                               e.tooth_fdi,
                               e.finding_code,
                               e.notes,
                               e.created_at,
                               e.face_occlusal,
                               e.face_vestibular,
                               e.face_palatal,
                               e.face_mesial,
                               e.face_distal,
                               ROW_NUMBER() OVER (
                                   PARTITION BY e.tooth_fdi
                                   ORDER BY CASE e.finding_code
                                                WHEN 'EXTRACTION' THEN 0
                                                WHEN 'CROWN' THEN 1
                                                ELSE 2
                                            END,
                                            e.created_at DESC,
                                            e.id_event DESC
                               ) AS rn
                          FROM customer_odontogram_event e
                         WHERE e.org_id_organization = v_org_id
                           AND e.cus_id_customer = pi_customer_id
                           AND e.deleted_at IS NULL
                       )
                 WHERE rn = 1
                 ORDER BY tooth_fdi
            ) LOOP
                v_teeth.append(
                    fn_tooth_json(
                        rec.tooth_fdi, rec.finding_code, rec.notes, rec.created_at,
                        rec.face_occlusal, rec.face_vestibular, rec.face_palatal,
                        rec.face_mesial, rec.face_distal
                    )
                );
            END LOOP;

            FOR rec IN (
                SELECT id_event,
                       tooth_fdi,
                       finding_code,
                       notes,
                       created_at,
                       face_occlusal,
                       face_vestibular,
                       face_palatal,
                       face_mesial,
                       face_distal
                  FROM customer_odontogram_event
                 WHERE org_id_organization = v_org_id
                   AND cus_id_customer = pi_customer_id
                   AND deleted_at IS NULL
                 ORDER BY created_at DESC, id_event DESC
                 FETCH FIRST 100 ROWS ONLY
            ) LOOP
                v_events.append(
                    fn_event_json(
                        rec.id_event, rec.tooth_fdi, rec.finding_code, rec.notes, rec.created_at,
                        rec.face_occlusal, rec.face_vestibular, rec.face_palatal,
                        rec.face_mesial, rec.face_distal
                    )
                );
            END LOOP;
        END IF;

        v_data.put('entitled', v_entitled);
        v_data.put('teeth', v_teeth);
        v_data.put('events', v_events);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_data);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_chart;

    PROCEDURE pr_add_event(
        pi_auth_header   IN  VARCHAR2,
        pi_customer_id   IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_user_id       NUMBER;
        v_json          json_object_t;
        v_faces         json_object_t;
        v_response_json json_object_t := json_object_t();
        v_tooth_fdi     NUMBER;
        v_finding       VARCHAR2(20);
        v_notes         VARCHAR2(2000);
        v_occlusal      NUMBER := 0;
        v_vestibular    NUMBER := 0;
        v_palatal       NUMBER := 0;
        v_mesial        NUMBER := 0;
        v_distal        NUMBER := 0;
        v_id_event      NUMBER;
        v_created_at    TIMESTAMP WITH TIME ZONE;
        v_face_sum      NUMBER;
    BEGIN
        v_org_id  := fn_require_org_id(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        pr_assert_customer_in_org(v_org_id, pi_customer_id);

        pkg_aox_subscription_api.pr_assert_org_has_feature(v_org_id, c_feature);
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        BEGIN
            v_json := json_object_t.parse(pi_body);
            IF v_json.has('tooth_fdi') AND NOT v_json.get('tooth_fdi').is_null THEN
                v_tooth_fdi := v_json.get_number('tooth_fdi');
            END IF;
            IF v_json.has('finding_code') AND NOT v_json.get('finding_code').is_null THEN
                v_finding := UPPER(TRIM(v_json.get_string('finding_code')));
            END IF;
            IF v_json.has('notes') AND NOT v_json.get('notes').is_null THEN
                v_notes := TRIM(v_json.get_string('notes'));
                IF v_notes IS NOT NULL AND LENGTH(v_notes) = 0 THEN
                    v_notes := NULL;
                END IF;
            END IF;
            IF v_json.has('faces') AND NOT v_json.get('faces').is_null THEN
                v_faces := v_json.get_object('faces');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'JSON invalido o malformado.');
        END;

        IF NOT fn_is_valid_fdi(v_tooth_fdi) THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Pieza dental inválida (FDI adulto 11-18, 21-28, 31-38, 41-48).'
            );
        END IF;

        IF v_finding IS NULL OR v_finding NOT IN ('CARIES', 'RESTORATION', 'EXTRACTION', 'CROWN') THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'finding_code inválido.'
            );
        END IF;

        v_occlusal   := fn_json_01(v_faces, 'occlusal');
        v_vestibular := fn_json_01(v_faces, 'vestibular');
        v_palatal    := fn_json_01(v_faces, 'palatal');
        v_mesial     := fn_json_01(v_faces, 'mesial');
        v_distal     := fn_json_01(v_faces, 'distal');
        v_face_sum   := v_occlusal + v_vestibular + v_palatal + v_mesial + v_distal;

        -- Corona recubre toda la pieza; Extracción no tiene caras.
        IF v_finding IN ('EXTRACTION', 'CROWN') THEN
            v_occlusal   := 0;
            v_vestibular := 0;
            v_palatal    := 0;
            v_mesial     := 0;
            v_distal     := 0;
        ELSIF v_face_sum < 1 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Indicá al menos una cara afectada.'
            );
        END IF;

        INSERT /*+ no_parallel */ INTO customer_odontogram_event (
            org_id_organization,
            cus_id_customer,
            tooth_fdi,
            face_occlusal,
            face_vestibular,
            face_palatal,
            face_mesial,
            face_distal,
            finding_code,
            notes,
            created_by_user
        ) VALUES (
            v_org_id,
            pi_customer_id,
            v_tooth_fdi,
            v_occlusal,
            v_vestibular,
            v_palatal,
            v_mesial,
            v_distal,
            v_finding,
            v_notes,
            v_user_id
        )
        RETURNING id_event, created_at
             INTO v_id_event, v_created_at;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put(
            'data',
            fn_event_json(
                v_id_event, v_tooth_fdi, v_finding, v_notes, v_created_at,
                v_occlusal, v_vestibular, v_palatal, v_mesial, v_distal
            )
        );
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_add_event;

    PROCEDURE pr_void_event(
        pi_auth_header   IN  VARCHAR2,
        pi_customer_id   IN  NUMBER,
        pi_event_id      IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_user_id       NUMBER;
        v_response_json json_object_t := json_object_t();
    BEGIN
        v_org_id  := fn_require_org_id(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        pr_assert_customer_in_org(v_org_id, pi_customer_id);

        pkg_aox_subscription_api.pr_assert_org_has_feature(v_org_id, c_feature);
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        IF NVL(pi_event_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Evento inválido.');
        END IF;

        UPDATE /*+ no_parallel */ customer_odontogram_event
           SET deleted_at = CURRENT_TIMESTAMP,
               deleted_by_user = v_user_id
         WHERE id_event = pi_event_id
           AND org_id_organization = v_org_id
           AND cus_id_customer = pi_customer_id
           AND deleted_at IS NULL;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Registro de odontograma no encontrado.');
        END IF;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_void_event;

END pkg_aox_odontogram_api;
/
