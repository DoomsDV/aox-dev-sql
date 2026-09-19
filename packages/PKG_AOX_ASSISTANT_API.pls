PROMPT CREATE OR REPLACE PACKAGE pkg_aox_assistant_api
CREATE OR REPLACE PACKAGE pkg_aox_assistant_api IS

    /**
     * Lecturas acotadas para el asistente operativo. No recibe IDs de tenant,
     * usuario o profesional: el scope se deriva del JWT y de RLS.
     */
    PROCEDURE pr_review_summary(
        pi_auth_header   IN  VARCHAR2,
        pi_days          IN  NUMBER DEFAULT 30,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_list_reviews(
        pi_auth_header   IN  VARCHAR2,
        pi_days          IN  NUMBER DEFAULT 30,
        pi_limit         IN  NUMBER DEFAULT 10,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_assistant_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_assistant_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_assistant_api IS

    c_max_days  CONSTANT PLS_INTEGER := 90;
    c_max_limit CONSTANT PLS_INTEGER := 20;

    PROCEDURE pr_bind_and_assert(
        pi_auth_header IN  VARCHAR2,
        po_org_id      OUT NUMBER,
        po_user_id     OUT NUMBER,
        po_role_id     OUT NUMBER,
        po_prof_id     OUT NUMBER,
        po_org_viewer  OUT NUMBER
    ) IS
    BEGIN
        pkg_aox_session.pr_bind_tenant_from_jwt(
            pi_auth_header => pi_auth_header,
            po_org_id      => po_org_id,
            po_user_id     => po_user_id,
            po_role_id     => po_role_id
        );

        IF NVL(po_org_id, 0) <= 0 OR NVL(po_role_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token inválido o sin organización asociada.');
        END IF;

        pkg_aox_permission_api.pr_assert_capability(
            po_org_id,
            po_role_id,
            'assistant.use',
            'El asistente no está habilitado para esta organización o usuario.'
        );
        pkg_aox_permission_api.pr_assert_capability(
            po_org_id,
            po_role_id,
            'analytics.view',
            'No tienes permisos para ver analíticas y reseñas.'
        );

        po_org_viewer := CASE
            WHEN po_role_id IN (pkg_aox_util.fn_rol('ADMIN'), pkg_aox_util.fn_rol('RECEPCIONISTA')) THEN 1
            ELSE 0
        END;
        po_prof_id := NULL;

        IF po_org_viewer = 0 THEN
            BEGIN
                SELECT p.id_professional
                  INTO po_prof_id
                  FROM professional p
                 WHERE p.usr_id_user = po_user_id
                   AND p.org_id_organization = po_org_id
                   AND p.is_active = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    po_prof_id := -1;
            END;
        END IF;
    END pr_bind_and_assert;

    PROCEDURE pr_validate_days(pi_days IN NUMBER, po_days OUT PLS_INTEGER) IS
    BEGIN
        po_days := NVL(TRUNC(pi_days), 30);
        IF po_days < 1 OR po_days > c_max_days THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'days debe estar entre 1 y 90.');
        END IF;
    END pr_validate_days;

    PROCEDURE pr_validate_limit(pi_limit IN NUMBER, po_limit OUT PLS_INTEGER) IS
    BEGIN
        po_limit := NVL(TRUNC(pi_limit), 10);
        IF po_limit < 1 OR po_limit > c_max_limit THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'limit debe estar entre 1 y 20.');
        END IF;
    END pr_validate_limit;

    PROCEDURE pr_review_summary(
        pi_auth_header   IN  VARCHAR2,
        pi_days          IN  NUMBER DEFAULT 30,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id       NUMBER;
        v_user_id      NUMBER;
        v_role_id      NUMBER;
        v_prof_id      NUMBER;
        v_org_viewer   NUMBER;
        v_days         PLS_INTEGER;
        v_from         TIMESTAMP WITH TIME ZONE;
        v_total        NUMBER := 0;
        v_average      NUMBER;
        v_response     json_object_t := json_object_t();
        v_data         json_object_t := json_object_t();
        v_score_obj    json_object_t;
        v_by_score     json_array_t := json_array_t();
        v_score_count  NUMBER;
    BEGIN
        pr_bind_and_assert(
            pi_auth_header => pi_auth_header,
            po_org_id      => v_org_id,
            po_user_id     => v_user_id,
            po_role_id     => v_role_id,
            po_prof_id     => v_prof_id,
            po_org_viewer  => v_org_viewer
        );
        pr_validate_days(pi_days, v_days);
        v_from := SYSTIMESTAMP - NUMTODSINTERVAL(v_days, 'DAY');

        SELECT COUNT(*), ROUND(AVG(a.survey_score), 1)
          INTO v_total, v_average
          FROM appointment a
         WHERE a.org_id_organization = v_org_id
           AND a.survey_status = 'COMPLETED'
           AND a.survey_score BETWEEN 1 AND 5
           AND a.survey_replied_at >= v_from
           AND (v_org_viewer = 1 OR a.pro_id_professional = v_prof_id);

        FOR i IN 1 .. 5 LOOP
            SELECT COUNT(*)
              INTO v_score_count
              FROM appointment a
             WHERE a.org_id_organization = v_org_id
               AND a.survey_status = 'COMPLETED'
               AND a.survey_score = i
               AND a.survey_replied_at >= v_from
               AND (v_org_viewer = 1 OR a.pro_id_professional = v_prof_id);
            v_score_obj := json_object_t();
            v_score_obj.put('score', i);
            v_score_obj.put('count', v_score_count);
            v_by_score.append(v_score_obj);
        END LOOP;

        v_data.put('days', v_days);
        v_data.put('review_count', v_total);
        v_data.put('average_score', NVL(v_average, 0));
        v_data.put('by_score', v_by_score);
        v_data.put('scope', CASE WHEN v_org_viewer = 1 THEN 'organization' ELSE 'professional' END);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_review_summary;

    PROCEDURE pr_list_reviews(
        pi_auth_header   IN  VARCHAR2,
        pi_days          IN  NUMBER DEFAULT 30,
        pi_limit         IN  NUMBER DEFAULT 10,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id       NUMBER;
        v_user_id      NUMBER;
        v_role_id      NUMBER;
        v_prof_id      NUMBER;
        v_org_viewer   NUMBER;
        v_days         PLS_INTEGER;
        v_limit        PLS_INTEGER;
        v_from         TIMESTAMP WITH TIME ZONE;
        v_response     json_object_t := json_object_t();
        v_data         json_array_t := json_array_t();
        v_item         json_object_t;
    BEGIN
        pr_bind_and_assert(
            pi_auth_header => pi_auth_header,
            po_org_id      => v_org_id,
            po_user_id     => v_user_id,
            po_role_id     => v_role_id,
            po_prof_id     => v_prof_id,
            po_org_viewer  => v_org_viewer
        );
        pr_validate_days(pi_days, v_days);
        pr_validate_limit(pi_limit, v_limit);
        v_from := SYSTIMESTAMP - NUMTODSINTERVAL(v_days, 'DAY');

        FOR rec IN (
            SELECT a.id_appointment,
                   a.survey_score,
                   a.survey_comment,
                   a.survey_replied_at,
                   s.name AS service_name,
                   p.display_name AS professional_name
              FROM appointment a
              JOIN service s
                ON s.id_service = a.ser_id_service
              JOIN professional p
                ON p.id_professional = a.pro_id_professional
             WHERE a.org_id_organization = v_org_id
               AND a.survey_status = 'COMPLETED'
               AND a.survey_score BETWEEN 1 AND 5
               AND a.survey_replied_at >= v_from
               AND (v_org_viewer = 1 OR a.pro_id_professional = v_prof_id)
             ORDER BY a.survey_replied_at DESC
             FETCH FIRST v_limit ROWS ONLY
        ) LOOP
            v_item := json_object_t();
            v_item.put('appointment_id', rec.id_appointment);
            v_item.put('score', rec.survey_score);
            v_item.put('submitted_at', TO_CHAR(rec.survey_replied_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            v_item.put('service_name', rec.service_name);
            v_item.put('professional_name', rec.professional_name);
            IF rec.survey_comment IS NULL THEN
                v_item.put_null('comment');
            ELSE
                v_item.put('comment', SUBSTR(rec.survey_comment, 1, 400));
            END IF;
            v_data.append(v_item);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_reviews;

END pkg_aox_assistant_api;
/
