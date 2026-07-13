PROMPT CREATE OR REPLACE PACKAGE pkg_aox_ia_manager
CREATE OR REPLACE PACKAGE pkg_aox_ia_manager IS
    FUNCTION fn_get_gemini_summary(
        pi_org_id  NUMBER,
        pi_role_id NUMBER,
        pi_prof_id NUMBER,
        pi_user_id NUMBER DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION fn_role_label(pi_role_id NUMBER)
    RETURN VARCHAR2;

    FUNCTION fn_tone_label(pi_role_id NUMBER)
    RETURN VARCHAR2;

    FUNCTION fn_structure_label(pi_role_id NUMBER)
    RETURN VARCHAR2;

    FUNCTION fn_goal_label(pi_role_id NUMBER)
    RETURN VARCHAR2;

    FUNCTION fn_transcribe_whisper_audio(
        pi_audio_base64 IN CLOB,
        pi_mime_type    IN VARCHAR2 DEFAULT 'audio/webm',
        pi_filename     IN VARCHAR2 DEFAULT 'cita.webm'
    ) RETURN CLOB;

    FUNCTION fn_parse_appointment_draft(
        pi_org_id     IN NUMBER,
        pi_role_id    IN NUMBER,
        pi_prof_id    IN NUMBER,
        pi_transcript IN CLOB
    ) RETURN CLOB;

    FUNCTION fn_process_voice_appointment_draft(
        pi_org_id       IN NUMBER,
        pi_role_id      IN NUMBER,
        pi_prof_id      IN NUMBER,
        pi_audio_base64 IN CLOB,
        pi_mime_type    IN VARCHAR2 DEFAULT 'audio/webm',
        pi_filename     IN VARCHAR2 DEFAULT 'cita.webm',
        pi_user_id      IN NUMBER DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION fn_build_summary_payload(
        pi_summary_short VARCHAR2,
        pi_sections      json_array_t
    ) RETURN CLOB;

    -- Fase B2: OCR multimodal de comprobante SIPAP (gpt-4o / gpt-4o-mini).
    -- pi_image_url: URL publica del bucket (pruebas) o data URL.
    FUNCTION fn_extract_transfer_receipt(
        pi_image_url     IN VARCHAR2,
        pi_expected_ref  IN VARCHAR2 DEFAULT NULL,
        pi_expected_amt  IN NUMBER   DEFAULT NULL,
        pi_org_id        IN NUMBER   DEFAULT NULL
    ) RETURN CLOB;

END pkg_aox_ia_manager;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_ia_manager
CREATE OR REPLACE PACKAGE BODY pkg_aox_ia_manager IS

    c_default_auto_score CONSTANT NUMBER := 0.82;
    c_default_gap_score  CONSTANT NUMBER := 0.05;
    c_default_min_score  CONSTANT NUMBER := 0.55;
    c_default_top_k      CONSTANT PLS_INTEGER := 5;

    FUNCTION fn_vector_auto_score RETURN NUMBER IS
    BEGIN
        RETURN GREATEST(0, LEAST(1, NVL(pkg_aox_util.fn_param_number('VECTOR_SEARCH_AUTO_SCORE', c_default_auto_score), c_default_auto_score)));
    END fn_vector_auto_score;

    FUNCTION fn_vector_gap_score RETURN NUMBER IS
    BEGIN
        RETURN GREATEST(0, LEAST(1, NVL(pkg_aox_util.fn_param_number('VECTOR_SEARCH_GAP_SCORE', c_default_gap_score), c_default_gap_score)));
    END fn_vector_gap_score;

    FUNCTION fn_vector_min_score RETURN NUMBER IS
    BEGIN
        RETURN GREATEST(0, LEAST(1, NVL(pkg_aox_util.fn_param_number('VECTOR_SEARCH_MIN_SCORE', c_default_min_score), c_default_min_score)));
    END fn_vector_min_score;

    FUNCTION fn_vector_top_k RETURN PLS_INTEGER IS
        v_top_k NUMBER;
    BEGIN
        v_top_k := NVL(pkg_aox_util.fn_param_number('VECTOR_SEARCH_TOP_K', c_default_top_k), c_default_top_k);
        RETURN GREATEST(1, LEAST(20, TRUNC(v_top_k)));
    END fn_vector_top_k;

    PROCEDURE pr_append_resolution_trace(
        pio_trace            IN OUT NOCOPY json_array_t,
        pi_field             IN VARCHAR2,
        pi_entity_type       IN VARCHAR2,
        pi_hint              IN VARCHAR2,
        pi_mode              IN VARCHAR2,
        pi_entity_id         IN NUMBER DEFAULT NULL,
        pi_top_score         IN NUMBER DEFAULT NULL,
        pi_second_score      IN NUMBER DEFAULT NULL,
        pi_candidate_count   IN NUMBER DEFAULT 0
    ) IS
        v_item json_object_t := json_object_t();
    BEGIN
        IF pio_trace IS NULL OR TRIM(pi_hint) IS NULL THEN
            RETURN;
        END IF;

        v_item.put('field', pi_field);
        v_item.put('entity_type', pi_entity_type);
        v_item.put('hint', SUBSTR(TRIM(pi_hint), 1, 500));
        v_item.put('mode', pi_mode);

        IF NVL(pi_entity_id, 0) > 0 THEN
            v_item.put('entity_id', pi_entity_id);
        END IF;
        IF pi_top_score IS NOT NULL THEN
            v_item.put('top_score', ROUND(pi_top_score, 6));
        END IF;
        IF pi_second_score IS NOT NULL THEN
            v_item.put('second_score', ROUND(pi_second_score, 6));
        END IF;
        IF NVL(pi_candidate_count, 0) > 0 THEN
            v_item.put('candidate_count', pi_candidate_count);
        END IF;

        pio_trace.append(v_item);
    END pr_append_resolution_trace;

    FUNCTION fn_build_voice_vector_metrics(
        pi_trace    IN json_array_t,
        pi_draft    IN json_object_t
    ) RETURN CLOB IS
        v_metrics      json_object_t := json_object_t();
        v_item         json_object_t;
        v_mode         VARCHAR2(30);
        v_auto_count   PLS_INTEGER := 0;
        v_cand_count   PLS_INTEGER := 0;
        v_unresolved   PLS_INTEGER := 0;
        v_missing_size PLS_INTEGER := 0;
    BEGIN
        IF pi_trace IS NOT NULL THEN
            FOR i IN 0 .. pi_trace.get_size - 1 LOOP
                v_item := TREAT(pi_trace.get(i) AS json_object_t);
                v_mode := LOWER(TRIM(v_item.get_string('mode')));

                IF v_mode IN ('auto', 'phone_exact', 'role_fixed') THEN
                    v_auto_count := v_auto_count + 1;
                ELSIF v_mode = 'candidates' THEN
                    v_cand_count := v_cand_count + 1;
                ELSIF v_mode = 'none' THEN
                    v_unresolved := v_unresolved + 1;
                END IF;
            END LOOP;
        END IF;

        IF pi_draft IS NOT NULL AND pi_draft.has('missing_fields') THEN
            v_missing_size := TREAT(pi_draft.get('missing_fields') AS json_array_t).get_size;
        END IF;

        v_metrics.put('auto_resolved_fields', v_auto_count);
        v_metrics.put('candidate_fields', v_cand_count);
        v_metrics.put('unresolved_fields', v_unresolved);
        v_metrics.put('missing_field_count', v_missing_size);

        IF pi_draft IS NOT NULL AND pi_draft.has('confidence') THEN
            v_metrics.put('confidence', TRIM(pi_draft.get_string('confidence')));
        END IF;

        RETURN v_metrics.to_clob();
    END fn_build_voice_vector_metrics;

    PROCEDURE pr_log_voice_vector_draft(
        pi_org_id          IN NUMBER,
        pi_user_id         IN NUMBER,
        pi_role_id         IN NUMBER,
        pi_prof_id         IN NUMBER,
        pi_transcript      IN CLOB,
        pi_gpt_slots       IN json_object_t,
        pi_resolution_trace IN json_array_t,
        pi_draft           IN json_object_t
    ) IS
        v_request    json_object_t := json_object_t();
        v_params     json_object_t := json_object_t();
        v_thresholds json_object_t := json_object_t();
    BEGIN
        v_request.put('transcript', DBMS_LOB.SUBSTR(pi_transcript, 32767, 1));
        IF pi_gpt_slots IS NOT NULL THEN
            v_request.put('gpt_slots', pi_gpt_slots);
        END IF;

        v_thresholds.put('auto_score', fn_vector_auto_score);
        v_thresholds.put('gap_score', fn_vector_gap_score);
        v_thresholds.put('min_score', fn_vector_min_score);
        v_thresholds.put('top_k', fn_vector_top_k);
        v_params.put('thresholds', v_thresholds);
        v_params.put('metrics', json_object_t.parse(fn_build_voice_vector_metrics(pi_resolution_trace, pi_draft)));
        IF pi_resolution_trace IS NOT NULL THEN
            v_params.put('resolution_trace', pi_resolution_trace);
        END IF;

        pkg_aox_util.pr_log_ai(
            pi_process_name    => 'VOICE_APPOINTMENT_VECTOR_DRAFT',
            pi_org_id          => pi_org_id,
            pi_user_id         => pi_user_id,
            pi_role_id         => pi_role_id,
            pi_pro_id          => pi_prof_id,
            pi_status          => 'SUCCESS',
            pi_status_code     => 200,
            pi_request_payload => v_request.to_clob(),
            pi_response_body   => pi_draft.to_clob(),
            pi_parameters      => v_params.to_clob()
        );
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END pr_log_voice_vector_draft;

    FUNCTION fn_role_label(pi_role_id NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN pi_role_id = pkg_aox_util.fn_rol('ADMIN') THEN 'DUENO'
            WHEN pi_role_id = pkg_aox_util.fn_rol('RECEPCIONISTA') THEN 'RECEPCIONISTA'
            ELSE 'PROFESIONAL'
        END;
    END fn_role_label;

    FUNCTION fn_tone_label(pi_role_id NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN pi_role_id = pkg_aox_util.fn_rol('ADMIN') THEN 'ejecutivo'
            WHEN pi_role_id = pkg_aox_util.fn_rol('RECEPCIONISTA') THEN 'operativo y claro'
            ELSE 'alentador y personal'
        END;
    END fn_tone_label;

    FUNCTION fn_structure_label(pi_role_id NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN pi_role_id = pkg_aox_util.fn_rol('ADMIN') THEN
                'summary_short: gancho breve. sections: panorama con saludo y citas/ingreso; contexto con 2-3 datos clave; sugerencia con una recomendacion concreta.'
            WHEN pi_role_id = pkg_aox_util.fn_rol('RECEPCIONISTA') THEN
                'summary_short: gancho breve operativo. sections: panorama con citas del local; contexto con proximas llegadas y pendientes; sugerencia operativa. Sin ingresos.'
            ELSE
                'summary_short: gancho personal breve. sections: panorama con citas propias; contexto con proxima cita o huecos; sugerencia personal. Sin ingresos.'
        END;
    END fn_structure_label;

    FUNCTION fn_goal_label(pi_role_id NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN pi_role_id = pkg_aox_util.fn_rol('ADMIN') THEN
                'Si los numeros son bajos presentalos como oportunidad. Si hay citas pendientes sin confirmar, recomenda confirmar o recordar al cliente. Si la actividad es alta, felicita brevemente y enfoca en sostenerla. No sugieras ejecutar acciones en el sistema; solo orienta.'
            WHEN pi_role_id = pkg_aox_util.fn_rol('RECEPCIONISTA') THEN
                'Enfocate en coordinacion del local: confirmaciones pendientes, proximas llegadas y distribucion de carga entre profesionales. Si la agenda esta tranquila, sugeri aprovechar para confirmar turnos futuros. No menciones ingresos. No sugieras ejecutar acciones en el sistema; solo orienta.'
            ELSE
                'Si no hay citas, incentiva el contacto proactivo con clientes recurrentes. Si hay huecos largos, sugeri completar la agenda. Si hay carga alta, recomenda preparar el espacio para no atrasarse. No menciones ingresos. No sugieras ejecutar acciones en el sistema; solo orienta.'
        END;
    END fn_goal_label;

    FUNCTION fn_compose_full_from_sections(pi_sections json_array_t) RETURN VARCHAR2 IS
        v_full       VARCHAR2(4000) := '';
        v_section    json_object_t;
        v_type       VARCHAR2(30);
        v_text       VARCHAR2(500);
        v_items      json_array_t;
        v_item_text  VARCHAR2(300);
    BEGIN
        IF pi_sections IS NULL OR pi_sections.get_size = 0 THEN
            RETURN NULL;
        END IF;

        FOR i IN 0 .. pi_sections.get_size - 1 LOOP
            v_section := TREAT(pi_sections.get(i) AS json_object_t);
            v_type    := LOWER(TRIM(v_section.get_string('type')));

            IF v_type = 'contexto' THEN
                v_items := TREAT(v_section.get('items') AS json_array_t);
                IF v_items IS NOT NULL THEN
                    FOR j IN 0 .. v_items.get_size - 1 LOOP
                        v_item_text := TRIM(v_items.get_string(j));
                        IF v_item_text IS NOT NULL THEN
                            IF v_full IS NOT NULL THEN
                                v_full := v_full || CHR(10);
                            END IF;
                            v_full := v_full || v_item_text;
                        END IF;
                    END LOOP;
                END IF;
            ELSE
                v_text := TRIM(v_section.get_string('text'));
                IF v_text IS NOT NULL THEN
                    IF v_full IS NOT NULL THEN
                        v_full := v_full || CHR(10);
                    END IF;
                    v_full := v_full || v_text;
                END IF;
            END IF;
        END LOOP;

        RETURN v_full;
    END fn_compose_full_from_sections;

    FUNCTION fn_build_sections_from_legacy(pi_text VARCHAR2) RETURN json_array_t IS
        v_arr        json_array_t := json_array_t();
        v_panorama   json_object_t := json_object_t();
        v_contexto   json_object_t := json_object_t();
        v_sugerencia json_object_t := json_object_t();
        v_items      json_array_t := json_array_t();
        v_clean      VARCHAR2(4000) := TRIM(REPLACE(NVL(pi_text, ''), CHR(13), ''));
        v_line       VARCHAR2(500);
        v_line_count PLS_INTEGER := 0;
        v_lines      sys.odcivarchar2list := sys.odcivarchar2list();
    BEGIN
        FOR i IN 1 .. 12 LOOP
            v_line := TRIM(REGEXP_SUBSTR(v_clean, '[^' || CHR(10) || ']+', 1, i));
            EXIT WHEN v_line IS NULL;
            v_lines.EXTEND;
            v_lines(v_lines.COUNT) := SUBSTR(v_line, 1, 320);
            v_line_count := v_line_count + 1;
        END LOOP;

        IF v_line_count = 0 THEN
            v_lines.EXTEND;
            v_lines(1) := 'Tu jornada esta lista para arrancar con buen pie.';
            v_line_count := 1;
        END IF;

        v_panorama.put('type', 'panorama');
        v_panorama.put('text', v_lines(1));

        v_contexto.put('type', 'contexto');
        IF v_line_count > 2 THEN
            FOR i IN 2 .. v_line_count - 1 LOOP
                v_items.append(v_lines(i));
            END LOOP;
        END IF;
        v_contexto.put('items', v_items);

        v_sugerencia.put('type', 'sugerencia');
        IF v_line_count >= 2 THEN
            v_sugerencia.put('text', v_lines(v_line_count));
        ELSE
            v_sugerencia.put('text', 'Conviene revisar tu agenda y confirmar los turnos pendientes.');
        END IF;

        v_arr.append(v_panorama);
        v_arr.append(v_contexto);
        v_arr.append(v_sugerencia);
        RETURN v_arr;
    END fn_build_sections_from_legacy;

    FUNCTION fn_sanitize_sections(pi_sections json_array_t) RETURN json_array_t IS
        v_result     json_array_t := json_array_t();
        v_section    json_object_t;
        v_type       VARCHAR2(30);
        v_text       VARCHAR2(500);
        v_items      json_array_t;
        v_clean_items json_array_t;
        v_item_text  VARCHAR2(300);
        v_out        json_object_t;
    BEGIN
        IF pi_sections IS NULL OR pi_sections.get_size = 0 THEN
            RETURN json_array_t();
        END IF;

        FOR i IN 0 .. pi_sections.get_size - 1 LOOP
            v_section := TREAT(pi_sections.get(i) AS json_object_t);
            v_type    := LOWER(TRIM(v_section.get_string('type')));

            IF v_type NOT IN ('panorama', 'contexto', 'sugerencia') THEN
                CONTINUE;
            END IF;

            v_out := json_object_t();
            v_out.put('type', v_type);

            IF v_type = 'contexto' THEN
                v_items := TREAT(v_section.get('items') AS json_array_t);
                v_clean_items := json_array_t();
                IF v_items IS NOT NULL THEN
                    FOR j IN 0 .. LEAST(v_items.get_size, 3) - 1 LOOP
                        v_item_text := SUBSTR(TRIM(v_items.get_string(j)), 1, 220);
                        IF v_item_text IS NOT NULL THEN
                            v_clean_items.append(v_item_text);
                        END IF;
                    END LOOP;
                END IF;
                v_out.put('items', v_clean_items);
            ELSE
                v_text := SUBSTR(TRIM(v_section.get_string('text')), 1, 320);
                IF v_text IS NOT NULL THEN
                    v_out.put('text', v_text);
                END IF;
            END IF;

            v_result.append(v_out);
        END LOOP;

        RETURN v_result;
    END fn_sanitize_sections;

    FUNCTION fn_fallback_summaries(pi_role_id NUMBER) RETURN CLOB IS
        v_short    VARCHAR2(500);
        v_sections json_array_t := json_array_t();
        v_panorama json_object_t := json_object_t();
        v_contexto json_object_t := json_object_t();
        v_sugerencia json_object_t := json_object_t();
        v_items    json_array_t := json_array_t();
    BEGIN
        IF pi_role_id = pkg_aox_util.fn_rol('ADMIN') THEN
            v_short := 'Buen dia. Hoy tu negocio tiene espacio para sumar reservas y ordenar la jornada.';
            v_panorama.put('type', 'panorama');
            v_panorama.put('text', 'Buen dia. Hoy tu negocio tiene espacio para sumar reservas y ordenar la jornada.');
            v_items.append('Revisa los turnos pendientes de confirmar.');
            v_items.append('Mira la distribucion de citas entre profesionales.');
            v_contexto.put('type', 'contexto');
            v_contexto.put('items', v_items);
            v_sugerencia.put('type', 'sugerencia');
            v_sugerencia.put('text', 'Conviene confirmar los turnos clave y contactar clientes habituales para completar la agenda.');
        ELSIF pi_role_id = pkg_aox_util.fn_rol('RECEPCIONISTA') THEN
            v_short := 'Buen dia. El local esta listo: revisa las proximas citas y las confirmaciones pendientes.';
            v_panorama.put('type', 'panorama');
            v_panorama.put('text', 'Buen dia. El local esta listo para recibir clientes.');
            v_items.append('Revisa las proximas citas de las proximas horas.');
            v_items.append('Hay turnos que aun estan pendientes de confirmar.');
            v_contexto.put('type', 'contexto');
            v_contexto.put('items', v_items);
            v_sugerencia.put('type', 'sugerencia');
            v_sugerencia.put('text', 'Conviene confirmar llegadas clave y coordinar con el equipo si hay huecos libres.');
        ELSE
            v_short := 'Buen dia. Tu agenda esta abierta: revisa tu proxima cita y los turnos restantes.';
            v_panorama.put('type', 'panorama');
            v_panorama.put('text', 'Buen dia. Tu agenda esta abierta y lista para la jornada.');
            v_items.append('Revisa tu proxima cita y los turnos que te quedan por atender hoy.');
            v_contexto.put('type', 'contexto');
            v_contexto.put('items', v_items);
            v_sugerencia.put('type', 'sugerencia');
            v_sugerencia.put('text', 'Conviene confirmar tus pendientes y preparar el espacio para no atrasarte.');
        END IF;

        v_sections.append(v_panorama);
        v_sections.append(v_contexto);
        v_sections.append(v_sugerencia);
        RETURN fn_build_summary_payload(v_short, v_sections);
    END fn_fallback_summaries;

    FUNCTION fn_build_summary_payload(
        pi_summary_short VARCHAR2,
        pi_sections      json_array_t
    ) RETURN CLOB IS
        v_obj         json_object_t := json_object_t();
        v_summary_full VARCHAR2(4000);
        v_sections    json_array_t;
    BEGIN
        v_sections := fn_sanitize_sections(pi_sections);
        IF v_sections.get_size = 0 THEN
            v_sections := fn_build_sections_from_legacy(NVL(TRIM(pi_summary_short), 'Resumen del dia.'));
        END IF;

        v_summary_full := fn_compose_full_from_sections(v_sections);

        v_obj.put('summary_short', NVL(TRIM(pi_summary_short), SUBSTR(v_summary_full, 1, 160)));
        v_obj.put('summary_full', NVL(v_summary_full, TRIM(pi_summary_short)));
        v_obj.put('sections', v_sections);
        RETURN v_obj.to_clob();
    END fn_build_summary_payload;

    FUNCTION fn_system_prompt RETURN CLOB IS
    BEGIN
        RETURN q'[
            Sos Hasel, asistente operativo para una app de turnos y reservas usada por duenos, recepcionistas y profesionales.
            Tu tarea es redactar un resumen breve (preview) y uno mas completo (detalle) del estado del dia, en espanol rioplatense con voseo formal.

            Formato de salida OBLIGATORIO:
            - Devolve UNICAMENTE un objeto JSON valido con estas claves: summary_short y sections.
            - summary_short: string de 1 a 2 lineas cortas (100 a 160 caracteres). Gancho breve que invite a leer el detalle.
            - sections: array con exactamente 3 objetos en este orden:
              1) { "type": "panorama", "text": "saludo segun hora local + panorama del dia en una oracion clara (max 140 caracteres)" }
              2) { "type": "contexto", "items": ["dato 1", "dato 2"] } con 1 a 3 strings cortos (max 110 caracteres c/u) con datos concretos del contexto.
              3) { "type": "sugerencia", "text": "una recomendacion concreta y util (max 140 caracteres)" }

            Contenido obligatorio:
            - panorama: saludo segun hora local y estado general del dia.
            - contexto: al menos un dato concreto (servicio mas pedido, proxima cita, pendientes, comparacion con ayer, cancelaciones, etc.).
            - sugerencia: una sola recomendacion orientativa. NUNCA pidas ejecutar acciones en el sistema.

            Reglas por rol (respetar writing_rules del contexto):
            - DUENO: puede mencionar ingreso proyectado en Gs. en panorama o contexto.
            - RECEPCIONISTA y PROFESIONAL: NO mencionar ingresos, montos ni ticket promedio.

            Estilo:
            - Tono profesional, calido, directo y motivador segun el rol.
            - Mostrar montos como Gs. 350.000 solo si el rol es DUENO.
            - Usar voseo formal: vos, tenes, podes, conviene, sumas.
            - Sin emojis, sin asteriscos, sin markdown, sin viñetas en el JSON.
            - No uses guarani ni ingles ni la palabra lucas.
            - Si un dato falta o vale 0, omitirlo en lugar de inventar o decir cero.
            - Si no hay datos para contexto, devolve items como array vacio [].

            Devolve unicamente el JSON, sin texto antes ni despues.
            ]';
    END fn_system_prompt;

    FUNCTION fn_build_user_prompt(
        pi_role_id                  NUMBER,
        pi_organization_name        VARCHAR2,
        pi_business_type            VARCHAR2,
        pi_workspace_description    VARCHAR2,
        pi_user                     VARCHAR2,
        pi_local_date               VARCHAR2,
        pi_local_time               VARCHAR2,
        pi_today_apps               NUMBER,
        pi_pending_apps             NUMBER,
        pi_confirmed_apps           NUMBER,
        pi_completed_apps           NUMBER,
        pi_canceled_apps            NUMBER,
        pi_revenue_projected        NUMBER,
        pi_revenue_confirmed        NUMBER,
        pi_revenue_realized         NUMBER,
        pi_avg_ticket               NUMBER,
        pi_cancel_rate              NUMBER,
        pi_first_appointment        VARCHAR2,
        pi_last_appointment         VARCHAR2,
        pi_busiest_hour             VARCHAR2,
        pi_services_list            VARCHAR2,
        pi_next_apps                VARCHAR2,
        pi_remaining_today          NUMBER,
        pi_pending_next_2h          NUMBER,
        pi_new_customers            NUMBER,
        pi_returning_customers      NUMBER,
        pi_active_customers_30d     NUMBER,
        pi_yesterday_apps           NUMBER,
        pi_appointments_vs_7d_avg   NUMBER,
        pi_top_service              VARCHAR2,
        pi_staff_list               VARCHAR2,
        pi_top_professional         VARCHAR2,
        pi_total_active_pros        NUMBER
    ) RETURN CLOB IS
        v_prompt             CLOB;
        v_team_visible       VARCHAR2(2);
        v_team_staff         VARCHAR2(4000);
        v_team_top           VARCHAR2(400);
        v_team_total_pros    NUMBER;
    BEGIN
        IF pi_role_id = pkg_aox_util.fn_rol('ADMIN') THEN
            v_team_visible    := 'si';
            v_team_staff      := NVL(pi_staff_list, 'sin actividad');
            v_team_top        := NVL(pi_top_professional, 'no_aplica');
            v_team_total_pros := NVL(pi_total_active_pros, 0);
        ELSIF pi_role_id = pkg_aox_util.fn_rol('RECEPCIONISTA') THEN
            v_team_visible    := 'si';
            v_team_staff      := NVL(pi_staff_list, 'sin actividad');
            v_team_top        := NVL(pi_top_professional, 'no_aplica');
            v_team_total_pros := NVL(pi_total_active_pros, 0);
        ELSE
            v_team_visible    := 'no';
            v_team_staff      := 'no_aplica';
            v_team_top        := 'no_aplica';
            v_team_total_pros := 0;
        END IF;

        SELECT json_object(
            'task' VALUE 'Generar un resumen operativo del dia, util y accionable para el dashboard',
            'role_context'          VALUE json_object(
                'role_id'           VALUE pi_role_id,
                'role_name'         VALUE fn_role_label(pi_role_id),
                'organization_name' VALUE pi_organization_name,
                'business_type'     VALUE NVL(pi_business_type, 'turnos y reservas'),
                'workspace_context' VALUE NVL(pi_workspace_description, ''),
                'current_user'      VALUE NVL(pi_user, ''),
                'timezone'          VALUE pkg_aox_util.fn_app_timezone,
                'local_date'        VALUE pi_local_date,
                'local_time'        VALUE pi_local_time
            ),
            'today_overview' VALUE json_object(
                'total_active_appointments' VALUE NVL(pi_today_apps, 0),
                'pending_appointments'      VALUE NVL(pi_pending_apps, 0),
                'confirmed_appointments'    VALUE NVL(pi_confirmed_apps, 0),
                'completed_appointments'    VALUE NVL(pi_completed_apps, 0),
                'canceled_appointments'     VALUE NVL(pi_canceled_apps, 0),
                'remaining_today_appointments' VALUE NVL(pi_remaining_today, 0),
                'pending_next_2_hours'      VALUE NVL(pi_pending_next_2h, 0),
                'cancellation_rate_pct'     VALUE NVL(pi_cancel_rate, 0)
            ),
            'revenue' VALUE json_object(
                'currency'                  VALUE 'Gs.',
                'projected_today'           VALUE NVL(pi_revenue_projected, 0),
                'confirmed_today'           VALUE NVL(pi_revenue_confirmed, 0),
                'realized_today'            VALUE NVL(pi_revenue_realized, 0),
                'average_ticket'            VALUE NVL(pi_avg_ticket, 0)
            ),
            'agenda_highlights' VALUE json_object(
                'first_appointment'         VALUE NVL(pi_first_appointment, 'no_aplica'),
                'last_appointment'          VALUE NVL(pi_last_appointment, 'no_aplica'),
                'busiest_hour'              VALUE NVL(pi_busiest_hour, 'no_aplica'),
                'services_summary'          VALUE NVL(pi_services_list, 'ninguno'),
                'top_service'               VALUE NVL(pi_top_service, 'no_aplica'),
                'next_appointments'         VALUE NVL(pi_next_apps, 'sin proximas citas')
            ),
            'customers' VALUE json_object(
                'new_customers_today'       VALUE NVL(pi_new_customers, 0),
                'returning_customers_today' VALUE NVL(pi_returning_customers, 0),
                'active_customers_30d'      VALUE NVL(pi_active_customers_30d, 0)
            ),
            'comparisons' VALUE json_object(
                'yesterday_appointments'    VALUE NVL(pi_yesterday_apps, 0),
                'appointments_vs_7d_avg'    VALUE NVL(pi_appointments_vs_7d_avg, 0)
            ),
            'team' VALUE json_object(
                'visible_for_role'              VALUE v_team_visible,
                'staff_performance'             VALUE v_team_staff,
                'top_professional'              VALUE v_team_top,
                'total_active_professionals'    VALUE v_team_total_pros
            ),
            'writing_rules' VALUE json_object(
                'greeting_based_on_local_time'  VALUE 'obligatorio',
                'tone'                          VALUE fn_tone_label(pi_role_id),
                'structure'                     VALUE fn_structure_label(pi_role_id),
                'objective'                     VALUE fn_goal_label(pi_role_id),
                'revenue_visible'               VALUE CASE WHEN pi_role_id = pkg_aox_util.fn_rol('ADMIN') THEN 'si' ELSE 'no' END,
                'summary_short_chars'           VALUE '100-160',
                'sections'                      VALUE 'panorama, contexto, sugerencia',
                'output_format'                 VALUE 'JSON con summary_short y sections',
                'currency'                      VALUE 'Gs.'
            )
            RETURNING CLOB
        )
        INTO v_prompt
        FROM dual;

        RETURN v_prompt;
    END fn_build_user_prompt;

    FUNCTION fn_get_gemini_summary(
        pi_org_id  NUMBER,
        pi_role_id NUMBER,
        pi_prof_id NUMBER,
        pi_user_id NUMBER DEFAULT NULL
    ) RETURN CLOB IS
        v_url               VARCHAR2(1000);
        v_body              CLOB;
        v_response          CLOB;
        v_system_prompt     CLOB;
        v_user_prompt       CLOB;
        v_ai_text           CLOB;
        v_summary_short     VARCHAR2(500);
        v_summary_full      VARCHAR2(4000);
        v_sections          json_array_t;
        v_sections_raw      json_array_t;
        v_is_org_viewer     NUMBER := CASE
            WHEN pi_role_id IN (
                pkg_aox_util.fn_rol('ADMIN'),
                pkg_aox_util.fn_rol('RECEPCIONISTA')
            ) THEN 1
            ELSE 0
        END;

        v_today_apps          NUMBER := 0;
        v_pending_apps        NUMBER := 0;
        v_confirmed_apps      NUMBER := 0;
        v_completed_apps      NUMBER := 0;
        v_canceled_apps       NUMBER := 0;
        v_revenue_projected   NUMBER := 0;
        v_revenue_confirmed   NUMBER := 0;
        v_revenue_realized    NUMBER := 0;
        v_avg_ticket          NUMBER := 0;
        v_cancel_rate         NUMBER := 0;
        v_first_appointment   VARCHAR2(200);
        v_last_appointment    VARCHAR2(200);
        v_busiest_hour        VARCHAR2(50);
        v_remaining_today     NUMBER := 0;
        v_pending_next_2h     NUMBER := 0;
        v_yesterday_apps      NUMBER := 0;
        v_week_avg_apps       NUMBER := 0;
        v_apps_vs_7d_avg      NUMBER := 0;
        v_new_customers       NUMBER := 0;
        v_returning_customers NUMBER := 0;
        v_active_customers_30 NUMBER := 0;
        v_services_list       VARCHAR2(4000) := 'ninguno';
        v_top_service         VARCHAR2(400);
        v_next_apps           VARCHAR2(4000) := 'sin proximas citas';
        v_staff_list          VARCHAR2(4000) := 'sin actividad';
        v_top_professional    VARCHAR2(400);
        v_total_active_pros   NUMBER := 0;
        v_now_local           TIMESTAMP;
        v_today_start         TIMESTAMP;
        v_tomorrow_start      TIMESTAMP;
        v_yesterday_start     TIMESTAMP;
        v_week_start          TIMESTAMP;
        v_month_back_start    TIMESTAMP;
        v_next_2h             TIMESTAMP;
        v_local_date          VARCHAR2(10);
        v_local_time          VARCHAR2(5);
        v_organization_name   ORGANIZATION.name%TYPE;
        v_business_type       VARCHAR2(100) := 'turnos y reservas';
        v_workspace_description VARCHAR2(1000) := '';
        v_user                VARCHAR2(100) := '';
        v_timezone            VARCHAR2(64)  := pkg_aox_util.fn_app_timezone;
        v_endpoint            VARCHAR2(500) := fn_get_parameter('AZURE_OPENAI_ENDPOINT');
        v_deployment          VARCHAR2(100) := fn_get_parameter('AZURE_OPENAI_DEPLOYMENT');
        v_api_version         VARCHAR2(50)  := fn_get_parameter('AZURE_OPENAI_API_VERSION');
        v_api_key             VARCHAR2(4000) := fn_get_parameter('AZURE_OPENAI_API_KEY');
    BEGIN
        v_now_local        := CAST(SYSTIMESTAMP AT TIME ZONE v_timezone AS TIMESTAMP);
        v_today_start      := CAST(TRUNC(v_now_local) AS TIMESTAMP);
        v_tomorrow_start   := v_today_start + NUMTODSINTERVAL(1, 'DAY');
        v_yesterday_start  := v_today_start - NUMTODSINTERVAL(1, 'DAY');
        v_week_start       := v_today_start - NUMTODSINTERVAL(7, 'DAY');
        v_month_back_start := v_today_start - NUMTODSINTERVAL(30, 'DAY');
        v_next_2h          := v_now_local  + NUMTODSINTERVAL(2, 'HOUR');
        v_local_date       := TO_CHAR(v_today_start, 'YYYY-MM-DD');
        v_local_time       := TO_CHAR(v_now_local, 'HH24:MI');

        SELECT
            o.name,
            NVL(os.name, 'turnos y reservas'),
            NVL(ws.description, '')
        INTO
            v_organization_name,
            v_business_type,
            v_workspace_description
        FROM organization o
        LEFT JOIN org_specialty os
            ON os.id_org_specialty = o.org_spe_id_specialty
        LEFT JOIN workspace_setting ws
            ON ws.org_id_organization = o.id_organization
        WHERE o.id_organization = pi_org_id;

        SELECT
            NVL(SUM(CASE WHEN a.status <> 'CANCELADO' THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'PENDIENTE' THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'CONFIRMADO' THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'COMPLETADO' THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'CANCELADO' THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status <> 'CANCELADO' THEN NVL(s.price, 0) ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status IN ('CONFIRMADO', 'COMPLETADO') THEN NVL(s.price, 0) ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'COMPLETADO' THEN NVL(s.price, 0) ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status IN ('PENDIENTE', 'CONFIRMADO') AND a.start_time >= v_now_local THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE
                WHEN a.status = 'PENDIENTE'
                 AND a.start_time >= v_now_local
                 AND a.start_time <  v_next_2h
                THEN 1 ELSE 0
            END), 0)
        INTO
            v_today_apps,
            v_pending_apps,
            v_confirmed_apps,
            v_completed_apps,
            v_canceled_apps,
            v_revenue_projected,
            v_revenue_confirmed,
            v_revenue_realized,
            v_remaining_today,
            v_pending_next_2h
        FROM appointment a
        LEFT JOIN service s
            ON s.id_service         = a.ser_id_service
        WHERE a.org_id_organization = pi_org_id
            AND ((v_is_org_viewer = 1) OR (a.pro_id_professional = pi_prof_id))
            AND a.start_time >= v_today_start
            AND a.start_time < v_tomorrow_start;

        IF NVL(v_today_apps, 0) > 0 THEN
            v_avg_ticket := ROUND(v_revenue_projected / v_today_apps);
        END IF;

        IF (NVL(v_today_apps, 0) + NVL(v_canceled_apps, 0)) > 0 THEN
            v_cancel_rate := ROUND(
                NVL(v_canceled_apps, 0) * 100
                    / (NVL(v_today_apps, 0) + NVL(v_canceled_apps, 0))
            );
        END IF;

        BEGIN
            SELECT
                TO_CHAR(MIN(a.start_time), 'HH24:MI'),
                TO_CHAR(MAX(a.start_time), 'HH24:MI')
            INTO
                v_first_appointment,
                v_last_appointment
            FROM appointment a
            WHERE a.org_id_organization = pi_org_id
              AND ((v_is_org_viewer = 1) OR (a.pro_id_professional = pi_prof_id))
              AND a.start_time >= v_today_start
              AND a.start_time <  v_tomorrow_start
              AND a.status <> 'CANCELADO';
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_first_appointment := NULL;
                v_last_appointment  := NULL;
        END;

        BEGIN
            SELECT block_label
            INTO   v_busiest_hour
            FROM (
                SELECT
                    TO_CHAR(a.start_time, 'HH24') || ':00' AS block_label,
                    COUNT(*) qty
                FROM appointment a
                WHERE a.org_id_organization = pi_org_id
                  AND ((v_is_org_viewer = 1) OR (a.pro_id_professional = pi_prof_id))
                  AND a.start_time >= v_today_start
                  AND a.start_time <  v_tomorrow_start
                  AND a.status <> 'CANCELADO'
                GROUP BY TO_CHAR(a.start_time, 'HH24') || ':00'
                ORDER BY qty DESC, block_label ASC
                FETCH FIRST 1 ROW ONLY
            );
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_busiest_hour := NULL;
        END;

        BEGIN
            SELECT name
            INTO   v_top_service
            FROM (
                SELECT
                    s2.name,
                    COUNT(*) qty
                FROM appointment a2
                JOIN service s2
                    ON s2.id_service = a2.ser_id_service
                WHERE a2.org_id_organization = pi_org_id
                  AND ((v_is_org_viewer = 1) OR (a2.pro_id_professional = pi_prof_id))
                  AND a2.start_time >= v_today_start
                  AND a2.start_time <  v_tomorrow_start
                  AND a2.status <> 'CANCELADO'
                GROUP BY s2.name
                ORDER BY qty DESC, s2.name ASC
                FETCH FIRST 1 ROW ONLY
            );
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_top_service := NULL;
        END;

        BEGIN
            SELECT COUNT(DISTINCT c.id_customer)
            INTO   v_active_customers_30
            FROM appointment ac
            JOIN customer c
              ON c.id_customer = ac.cus_id_customer
            WHERE ac.org_id_organization = pi_org_id
              AND ((v_is_org_viewer = 1) OR (ac.pro_id_professional = pi_prof_id))
              AND ac.start_time >= v_month_back_start
              AND ac.start_time <  v_tomorrow_start
              AND ac.status <> 'CANCELADO';
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_active_customers_30 := 0;
        END;

        SELECT NVL(
            LISTAGG(name || ' (x' || qty || ')', ', ')
                WITHIN GROUP (ORDER BY qty DESC),
            'ninguno'
            )
        INTO v_services_list
        FROM (
            SELECT
                s2.name,
                COUNT(*) qty
            FROM appointment a2
            JOIN service s2
                ON s2.id_service          = a2.ser_id_service
            WHERE a2.org_id_organization  = pi_org_id
                AND ((v_is_org_viewer = 1) OR (a2.pro_id_professional = pi_prof_id))
                AND a2.start_time >= v_today_start
                AND a2.start_time < v_tomorrow_start
                AND a2.status <> 'CANCELADO'
            GROUP BY s2.name
            ORDER BY qty DESC
            FETCH FIRST 4 ROWS ONLY
        );

        SELECT NVL(
            LISTAGG(next_label, '; ')
                WITHIN GROUP (ORDER BY start_time),
            'sin proximas citas'
            )
        INTO v_next_apps
        FROM (
            SELECT
                a3.start_time,
                TO_CHAR(a3.start_time, 'HH24:MI')
                    || ' '
                    || s3.name
                    || CASE
                        WHEN v_is_org_viewer = 1 THEN ' con ' || u3.first_name
                        ELSE ''
                    END AS next_label
            FROM appointment a3
            JOIN service s3
                ON s3.id_service = a3.ser_id_service
            JOIN professional p3
                ON p3.id_professional = a3.pro_id_professional
            JOIN app_user u3
                ON u3.id_user = p3.usr_id_user
            WHERE a3.org_id_organization = pi_org_id
                AND ((v_is_org_viewer = 1) OR (a3.pro_id_professional = pi_prof_id))
                AND a3.start_time >= v_now_local
                AND a3.start_time < v_tomorrow_start
                AND a3.status IN ('PENDIENTE', 'CONFIRMADO')
            ORDER BY a3.start_time
            FETCH FIRST 3 ROWS ONLY
        );

        SELECT
            COUNT(DISTINCT CASE
                WHEN c.created_at >= FROM_TZ(v_today_start, v_timezone)
                 AND c.created_at <  FROM_TZ(v_tomorrow_start, v_timezone) THEN c.id_customer
            END),
            COUNT(DISTINCT CASE
                WHEN c.created_at < FROM_TZ(v_today_start, v_timezone) THEN c.id_customer
            END)
        INTO
            v_new_customers,
            v_returning_customers
        FROM appointment a4
        JOIN customer c
            ON c.id_customer = a4.cus_id_customer
        WHERE a4.org_id_organization = pi_org_id
            AND ((v_is_org_viewer = 1) OR (a4.pro_id_professional = pi_prof_id))
            AND a4.start_time >= v_today_start
            AND a4.start_time < v_tomorrow_start
            AND a4.status <> 'CANCELADO';

        SELECT
            COUNT(*)
        INTO
            v_yesterday_apps
        FROM appointment a5
        WHERE a5.org_id_organization = pi_org_id
            AND ((v_is_org_viewer = 1) OR (a5.pro_id_professional = pi_prof_id))
            AND a5.start_time >= v_yesterday_start
            AND a5.start_time < v_today_start
            AND a5.status <> 'CANCELADO';

        SELECT
            ROUND(COUNT(*) / 7, 1)
        INTO
            v_week_avg_apps
        FROM appointment a6
        WHERE a6.org_id_organization = pi_org_id
            AND ((v_is_org_viewer = 1) OR (a6.pro_id_professional = pi_prof_id))
            AND a6.start_time >= v_week_start
            AND a6.start_time < v_today_start
            AND a6.status <> 'CANCELADO';

        v_apps_vs_7d_avg := NVL(v_today_apps, 0) - NVL(v_week_avg_apps, 0);

        BEGIN
            SELECT
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name))
            INTO
                v_user
            FROM professional p
            JOIN app_user u
                ON u.id_user        = p.usr_id_user
            WHERE p.id_professional = pi_prof_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_user := '';
        END;

        IF v_user IS NULL OR TRIM(v_user) IS NULL THEN
            BEGIN
                SELECT TRIM(first_name || ' ' || last_name)
                INTO v_user
                FROM app_user
                WHERE id_user = pi_user_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_user := '';
            END;
        END IF;

        IF pi_role_id = pkg_aox_util.fn_rol('ADMIN') THEN
            SELECT NVL(
                LISTAGG(NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) || ' (' || a_counts.qty || ' citas, Gs. ' || a_counts.revenue || ')', ', ')
                    WITHIN GROUP (ORDER BY a_counts.qty DESC),
                'sin actividad'
                )
            INTO v_staff_list
            FROM (
                SELECT
                    a.pro_id_professional,
                    COUNT(*) qty,
                    NVL(SUM(NVL(s.price, 0)), 0) revenue
                FROM appointment a
                LEFT JOIN service s
                    ON s.id_service = a.ser_id_service
                WHERE a.org_id_organization = pi_org_id
                  AND a.start_time >= v_today_start
                  AND a.start_time < v_tomorrow_start
                  AND a.status <> 'CANCELADO'
                GROUP BY a.pro_id_professional
                ORDER BY qty DESC
                FETCH FIRST 5 ROWS ONLY
            ) a_counts
            JOIN professional p
                ON p.id_professional  = a_counts.pro_id_professional
            JOIN app_user u
                ON u.id_user          = p.usr_id_user;

            BEGIN
                SELECT NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name))
                INTO   v_top_professional
                FROM (
                    SELECT
                        a.pro_id_professional,
                        COUNT(*) qty
                    FROM appointment a
                    WHERE a.org_id_organization = pi_org_id
                      AND a.start_time >= v_today_start
                      AND a.start_time <  v_tomorrow_start
                      AND a.status <> 'CANCELADO'
                    GROUP BY a.pro_id_professional
                    ORDER BY qty DESC
                    FETCH FIRST 1 ROW ONLY
                ) top_one
                JOIN professional p
                  ON p.id_professional = top_one.pro_id_professional
                JOIN app_user u
                  ON u.id_user         = p.usr_id_user;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_top_professional := NULL;
            END;

            BEGIN
                SELECT COUNT(DISTINCT a.pro_id_professional)
                INTO   v_total_active_pros
                FROM appointment a
                WHERE a.org_id_organization = pi_org_id
                  AND a.start_time >= v_today_start
                  AND a.start_time <  v_tomorrow_start
                  AND a.status <> 'CANCELADO';
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_total_active_pros := 0;
            END;
        ELSIF pi_role_id = pkg_aox_util.fn_rol('RECEPCIONISTA') THEN
            SELECT NVL(
                LISTAGG(NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) || ' (' || a_counts.qty || ' citas)', ', ')
                    WITHIN GROUP (ORDER BY a_counts.qty DESC),
                'sin actividad'
                )
            INTO v_staff_list
            FROM (
                SELECT
                    a.pro_id_professional,
                    COUNT(*) qty
                FROM appointment a
                WHERE a.org_id_organization = pi_org_id
                  AND a.start_time >= v_today_start
                  AND a.start_time < v_tomorrow_start
                  AND a.status <> 'CANCELADO'
                GROUP BY a.pro_id_professional
                ORDER BY qty DESC
                FETCH FIRST 5 ROWS ONLY
            ) a_counts
            JOIN professional p
                ON p.id_professional  = a_counts.pro_id_professional
            JOIN app_user u
                ON u.id_user          = p.usr_id_user;

            BEGIN
                SELECT NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name))
                INTO   v_top_professional
                FROM (
                    SELECT
                        a.pro_id_professional,
                        COUNT(*) qty
                    FROM appointment a
                    WHERE a.org_id_organization = pi_org_id
                      AND a.start_time >= v_today_start
                      AND a.start_time <  v_tomorrow_start
                      AND a.status <> 'CANCELADO'
                    GROUP BY a.pro_id_professional
                    ORDER BY qty DESC
                    FETCH FIRST 1 ROW ONLY
                ) top_one
                JOIN professional p
                  ON p.id_professional = top_one.pro_id_professional
                JOIN app_user u
                  ON u.id_user         = p.usr_id_user;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_top_professional := NULL;
            END;

            BEGIN
                SELECT COUNT(DISTINCT a.pro_id_professional)
                INTO   v_total_active_pros
                FROM appointment a
                WHERE a.org_id_organization = pi_org_id
                  AND a.start_time >= v_today_start
                  AND a.start_time <  v_tomorrow_start
                  AND a.status <> 'CANCELADO';
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_total_active_pros := 0;
            END;
        END IF;

        v_system_prompt := fn_system_prompt;
        v_user_prompt   := fn_build_user_prompt(
            pi_role_id                => pi_role_id,
            pi_organization_name      => v_organization_name,
            pi_business_type          => v_business_type,
            pi_workspace_description  => v_workspace_description,
            pi_user                   => v_user,
            pi_local_date             => v_local_date,
            pi_local_time             => v_local_time,
            pi_today_apps             => v_today_apps,
            pi_pending_apps           => v_pending_apps,
            pi_confirmed_apps         => v_confirmed_apps,
            pi_completed_apps         => v_completed_apps,
            pi_canceled_apps          => v_canceled_apps,
            pi_revenue_projected      => v_revenue_projected,
            pi_revenue_confirmed      => v_revenue_confirmed,
            pi_revenue_realized       => v_revenue_realized,
            pi_avg_ticket             => v_avg_ticket,
            pi_cancel_rate            => v_cancel_rate,
            pi_first_appointment      => v_first_appointment,
            pi_last_appointment       => v_last_appointment,
            pi_busiest_hour           => v_busiest_hour,
            pi_services_list          => v_services_list,
            pi_next_apps              => v_next_apps,
            pi_remaining_today        => v_remaining_today,
            pi_pending_next_2h        => v_pending_next_2h,
            pi_new_customers          => v_new_customers,
            pi_returning_customers    => v_returning_customers,
            pi_active_customers_30d   => v_active_customers_30,
            pi_yesterday_apps         => v_yesterday_apps,
            pi_appointments_vs_7d_avg => v_apps_vs_7d_avg,
            pi_top_service            => v_top_service,
            pi_staff_list             => v_staff_list,
            pi_top_professional       => v_top_professional,
            pi_total_active_pros      => v_total_active_pros
        );

        IF v_endpoint IS NULL OR v_deployment IS NULL OR v_api_version IS NULL OR v_api_key IS NULL THEN
            RETURN fn_fallback_summaries(pi_role_id);
        END IF;

        v_url := RTRIM(v_endpoint, '/')
              || '/openai/deployments/'
              || v_deployment
              || '/chat/completions?api-version='
              || v_api_version;

        SELECT json_object(
            'messages' VALUE json_array(
                json_object(
                    'role' VALUE 'system',
                    'content' VALUE v_system_prompt
                ),
                json_object(
                    'role' VALUE 'user',
                    'content' VALUE v_user_prompt
                )
            ),
            'temperature' VALUE 0.4,
            'top_p' VALUE 0.9,
            'max_tokens' VALUE 750
            RETURNING CLOB
            )
        INTO v_body
        FROM dual;

        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';
        apex_web_service.g_request_headers(2).name  := 'api-key';
        apex_web_service.g_request_headers(2).value := v_api_key;

        v_response := apex_web_service.make_rest_request(
            p_url         => v_url,
            p_http_method => 'POST',
            p_body        => v_body
        );

        SELECT
            json_value(v_response, '$.choices[0].message.content' RETURNING CLOB)
        INTO
            v_ai_text
        FROM dual;

        IF v_ai_text IS NULL OR TRIM(v_ai_text) IS NULL THEN
            RETURN fn_fallback_summaries(pi_role_id);
        END IF;

        v_ai_text := REPLACE(TRIM(v_ai_text), CHR(13), '');
        v_ai_text := REGEXP_REPLACE(v_ai_text, '^\s*```(?:json)?\s*', '', 1, 0, 'i');
        v_ai_text := REGEXP_REPLACE(v_ai_text, '\s*```\s*$', '');

        BEGIN
            SELECT
                json_value(v_ai_text, '$.summary_short' RETURNING VARCHAR2(500))
            INTO
                v_summary_short
            FROM dual;

            v_sections_raw := json_array_t(json_query(v_ai_text, '$.sections'));
        EXCEPTION
            WHEN OTHERS THEN
                v_summary_short := NULL;
                v_sections_raw  := NULL;
        END;

        IF v_sections_raw IS NULL OR v_sections_raw.get_size = 0 THEN
            BEGIN
                SELECT json_value(v_ai_text, '$.summary_full' RETURNING VARCHAR2(4000))
                INTO v_summary_full
                FROM dual;
            EXCEPTION
                WHEN OTHERS THEN
                    v_summary_full := NULL;
            END;

            IF v_summary_full IS NULL OR TRIM(v_summary_full) IS NULL THEN
                v_summary_full := DBMS_LOB.SUBSTR(v_ai_text, 4000, 1);
            END IF;

            v_sections_raw := fn_build_sections_from_legacy(v_summary_full);
        END IF;

        IF v_summary_short IS NULL OR TRIM(v_summary_short) IS NULL THEN
            v_summary_full := fn_compose_full_from_sections(fn_sanitize_sections(v_sections_raw));
            v_summary_short := SUBSTR(NVL(v_summary_full, 'Resumen del dia.'), 1, 160);
        END IF;

        v_sections := fn_sanitize_sections(v_sections_raw);
        RETURN fn_build_summary_payload(v_summary_short, v_sections);

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_ai(
                pi_process_name    => 'PKG_AOX_IA_MANAGER.FN_GET_GEMINI_SUMMARY',
                pi_org_id          => pi_org_id,
                pi_role_id         => pi_role_id,
                pi_pro_id          => pi_prof_id,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_prompt          => v_user_prompt,
                pi_request_payload => v_body,
                pi_response_body   => v_response
            );
            RETURN fn_fallback_summaries(pi_role_id);
    END fn_get_gemini_summary;

    PROCEDURE pr_append_text_to_blob(
        p_blob IN OUT NOCOPY BLOB,
        p_text IN VARCHAR2
    ) IS
        l_raw RAW(32767);
    BEGIN
        IF p_text IS NULL THEN
            RETURN;
        END IF;

        IF p_blob IS NULL THEN
            DBMS_LOB.CREATETEMPORARY(p_blob, TRUE);
        END IF;

        l_raw := UTL_RAW.CAST_TO_RAW(p_text);
        IF l_raw IS NOT NULL AND UTL_RAW.LENGTH(l_raw) > 0 THEN
            DBMS_LOB.WRITEAPPEND(p_blob, UTL_RAW.LENGTH(l_raw), l_raw);
        END IF;
    END pr_append_text_to_blob;

    PROCEDURE pr_append_blob_to_blob(
        p_target IN OUT NOCOPY BLOB,
        p_source IN BLOB
    ) IS
        l_amount INTEGER := 32767;
        l_offset INTEGER := 1;
        l_buffer RAW(32767);
        l_length INTEGER;
    BEGIN
        IF p_source IS NULL THEN
            RETURN;
        END IF;

        IF p_target IS NULL THEN
            DBMS_LOB.CREATETEMPORARY(p_target, TRUE);
        END IF;

        l_length := DBMS_LOB.GETLENGTH(p_source);
        WHILE l_offset <= l_length LOOP
            DBMS_LOB.READ(p_source, l_amount, l_offset, l_buffer);
            DBMS_LOB.WRITEAPPEND(p_target, UTL_RAW.LENGTH(l_buffer), l_buffer);
            l_offset := l_offset + l_amount;
        END LOOP;
    END pr_append_blob_to_blob;

    FUNCTION fn_base64_clob_to_blob(pi_clob IN CLOB) RETURN BLOB IS
        l_blob BLOB;
    BEGIN
        IF pi_clob IS NULL OR DBMS_LOB.GETLENGTH(pi_clob) = 0 THEN
            RETURN NULL;
        END IF;

        l_blob := apex_web_service.clobbase642blob(p_clob => pi_clob);
        RETURN l_blob;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END fn_base64_clob_to_blob;

    FUNCTION fn_call_azure_openai_chat(
        pi_system_prompt IN CLOB,
        pi_user_prompt   IN CLOB,
        pi_max_tokens    IN NUMBER DEFAULT 700,
        pi_temperature   IN NUMBER DEFAULT 0.2
    ) RETURN CLOB IS
        v_endpoint     VARCHAR2(500) := fn_get_parameter('AZURE_OPENAI_ENDPOINT');
        v_deployment   VARCHAR2(100) := fn_get_parameter('AZURE_OPENAI_DEPLOYMENT');
        v_api_version  VARCHAR2(50)  := fn_get_parameter('AZURE_OPENAI_API_VERSION');
        v_api_key      VARCHAR2(4000) := fn_get_parameter('AZURE_OPENAI_API_KEY');
        v_url          VARCHAR2(2000);
        v_body         CLOB;
        v_response     CLOB;
        v_ai_text      CLOB;
    BEGIN
        IF v_endpoint IS NULL OR v_deployment IS NULL OR v_api_version IS NULL OR v_api_key IS NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'Faltan parametros Azure OpenAI.');
        END IF;

        v_url := RTRIM(v_endpoint, '/')
              || '/openai/deployments/'
              || v_deployment
              || '/chat/completions?api-version='
              || v_api_version;

        SELECT json_object(
            'messages' VALUE json_array(
                json_object('role' VALUE 'system', 'content' VALUE pi_system_prompt),
                json_object('role' VALUE 'user',   'content' VALUE pi_user_prompt)
            ),
            'temperature' VALUE pi_temperature,
            'max_tokens'  VALUE pi_max_tokens
            RETURNING CLOB
        )
        INTO v_body
        FROM dual;

        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';
        apex_web_service.g_request_headers(2).name  := 'api-key';
        apex_web_service.g_request_headers(2).value := v_api_key;

        v_response := apex_web_service.make_rest_request(
            p_url         => v_url,
            p_http_method => 'POST',
            p_body        => v_body
        );

        SELECT json_value(v_response, '$.choices[0].message.content' RETURNING CLOB)
        INTO v_ai_text
        FROM dual;

        RETURN v_ai_text;
    END fn_call_azure_openai_chat;

    -- Chat multimodal: texto + image_url (gpt-4o / gpt-4o-mini).
    FUNCTION fn_call_azure_openai_vision(
        pi_system_prompt IN CLOB,
        pi_user_text     IN CLOB,
        pi_image_url     IN VARCHAR2,
        pi_max_tokens    IN NUMBER DEFAULT 800,
        pi_temperature   IN NUMBER DEFAULT 0.1,
        pi_deployment    IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        v_endpoint     VARCHAR2(500) := fn_get_parameter('AZURE_OPENAI_ENDPOINT');
        v_deployment   VARCHAR2(100) := NVL(
            NULLIF(TRIM(pi_deployment), ''),
            NVL(
                NULLIF(TRIM(fn_get_parameter('AZURE_OPENAI_RECEIPT_DEPLOYMENT')), ''),
                fn_get_parameter('AZURE_OPENAI_DEPLOYMENT')
            )
        );
        v_api_version  VARCHAR2(50)  := fn_get_parameter('AZURE_OPENAI_API_VERSION');
        v_api_key      VARCHAR2(4000) := fn_get_parameter('AZURE_OPENAI_API_KEY');
        v_url          VARCHAR2(2000);
        v_body         CLOB;
        v_response     CLOB;
        v_ai_text      CLOB;
        v_messages     json_array_t := json_array_t();
        v_sys_msg      json_object_t := json_object_t();
        v_user_msg     json_object_t := json_object_t();
        v_content      json_array_t := json_array_t();
        v_text_part    json_object_t := json_object_t();
        v_img_part     json_object_t := json_object_t();
        v_img_url_obj  json_object_t := json_object_t();
        v_root         json_object_t := json_object_t();
    BEGIN
        IF v_endpoint IS NULL OR v_deployment IS NULL OR v_api_version IS NULL OR v_api_key IS NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'Faltan parametros Azure OpenAI.');
        END IF;

        IF pi_image_url IS NULL OR LENGTH(TRIM(pi_image_url)) = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'URL de imagen requerida para OCR.');
        END IF;

        v_url := RTRIM(v_endpoint, '/')
              || '/openai/deployments/'
              || v_deployment
              || '/chat/completions?api-version='
              || v_api_version;

        v_sys_msg.put('role', 'system');
        v_sys_msg.put('content', pi_system_prompt);

        v_text_part.put('type', 'text');
        v_text_part.put('text', NVL(pi_user_text, TO_CLOB('Extrae los datos del comprobante.')));

        v_img_url_obj.put('url', TRIM(pi_image_url));
        v_img_part.put('type', 'image_url');
        v_img_part.put('image_url', v_img_url_obj);

        v_content.append(v_text_part);
        v_content.append(v_img_part);

        v_user_msg.put('role', 'user');
        v_user_msg.put('content', v_content);

        v_messages.append(v_sys_msg);
        v_messages.append(v_user_msg);

        v_root.put('messages', v_messages);
        v_root.put('temperature', pi_temperature);
        v_root.put('max_tokens', pi_max_tokens);
        v_body := v_root.to_clob();

        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';
        apex_web_service.g_request_headers(2).name  := 'api-key';
        apex_web_service.g_request_headers(2).value := v_api_key;

        v_response := apex_web_service.make_rest_request(
            p_url         => v_url,
            p_http_method => 'POST',
            p_body        => v_body
        );

        SELECT json_value(v_response, '$.choices[0].message.content' RETURNING CLOB)
        INTO v_ai_text
        FROM dual;

        RETURN v_ai_text;
    END fn_call_azure_openai_vision;

    FUNCTION fn_extract_transfer_receipt(
        pi_image_url     IN VARCHAR2,
        pi_expected_ref  IN VARCHAR2 DEFAULT NULL,
        pi_expected_amt  IN NUMBER   DEFAULT NULL,
        pi_org_id        IN NUMBER   DEFAULT NULL
    ) RETURN CLOB IS
        v_system   CLOB;
        v_user     CLOB;
        v_raw      CLOB;
        v_clean    CLOB;
        v_result   json_object_t := json_object_t();
        v_parsed   json_object_t;
        v_status   VARCHAR2(30) := 'OK';
        v_err_msg  VARCHAR2(4000);
    BEGIN
        v_system := TO_CLOB(
            'Sos un extractor de comprobantes de transferencia bancaria de Paraguay (SIPAP). '
            || 'Respondé SOLO con un JSON válido, sin markdown ni texto extra. '
            || 'Schema: {"reference":string|null,"amount":number|null,"transfer_datetime":string|null,'
            || '"bank_hint":string|null,"confidence":number}. '
            || 'reference: codigo tipo HASEL-XXXXXXXX si aparece (asunto/concepto/referencia). '
            || 'amount: monto transferido en guaranies (numero, sin puntos de miles). '
            || 'transfer_datetime: ISO-8601 si se ve fecha/hora; si no, null. '
            || 'bank_hint: nombre de banco si se ve. '
            || 'confidence: 0 a 1 segun legibilidad y certeza.'
        );

        v_user := TO_CLOB('Extrae los datos del comprobante.');
        IF pi_expected_ref IS NOT NULL THEN
            v_user := v_user || TO_CLOB(CHR(10) || 'Codigo esperado (puede estar truncado): ' || pi_expected_ref);
        END IF;
        IF pi_expected_amt IS NOT NULL THEN
            v_user := v_user || TO_CLOB(CHR(10) || 'Monto esperado aproximado (Gs): ' || TO_CHAR(pi_expected_amt));
        END IF;

        BEGIN
            v_raw := fn_call_azure_openai_vision(
                pi_system_prompt => v_system,
                pi_user_text     => v_user,
                pi_image_url     => pi_image_url,
                pi_max_tokens    => 600,
                pi_temperature   => 0.1
            );
        EXCEPTION
            WHEN OTHERS THEN
                v_status  := 'ERROR';
                v_err_msg := SUBSTR(SQLERRM, 1, 4000);
                v_result.put('status', 'error');
                v_result.put('error', v_err_msg);
                v_result.put_null('reference');
                v_result.put_null('amount');
                v_result.put_null('transfer_datetime');
                v_result.put_null('bank_hint');
                v_result.put('confidence', 0);
                pkg_aox_util.pr_log_ai(
                    pi_process_name    => 'PKG_AOX_IA_MANAGER.FN_EXTRACT_TRANSFER_RECEIPT',
                    pi_session_id      => NULL,
                    pi_org_id          => pi_org_id,
                    pi_user_id         => NULL,
                    pi_role_id         => NULL,
                    pi_pro_id          => NULL,
                    pi_status          => 'ERROR',
                    pi_status_code     => 500,
                    pi_error_code      => SQLCODE,
                    pi_error_message   => v_err_msg,
                    pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                    pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                    pi_prompt          => v_user,
                    pi_request_payload => TO_CLOB(SUBSTR(pi_image_url, 1, 500)),
                    pi_response_body   => NULL,
                    pi_parameters      => NULL
                );
                RETURN v_result.to_clob();
        END;

        -- Limpiar fences markdown si el modelo las agrega.
        v_clean := TRIM(v_raw);
        IF v_clean IS NOT NULL THEN
            v_clean := REGEXP_REPLACE(v_clean, '^\s*```(?:json)?\s*', '', 1, 1, 'i');
            v_clean := REGEXP_REPLACE(v_clean, '\s*```\s*$', '', 1, 1);
            v_clean := TRIM(v_clean);
        END IF;

        BEGIN
            v_parsed := json_object_t.parse(v_clean);
            v_result.put('status', 'ok');
            BEGIN
                v_result.put('reference', v_parsed.get_string('reference'));
            EXCEPTION WHEN OTHERS THEN v_result.put_null('reference');
            END;
            BEGIN
                v_result.put('amount', v_parsed.get_number('amount'));
            EXCEPTION WHEN OTHERS THEN v_result.put_null('amount');
            END;
            BEGIN
                v_result.put('transfer_datetime', v_parsed.get_string('transfer_datetime'));
            EXCEPTION WHEN OTHERS THEN v_result.put_null('transfer_datetime');
            END;
            BEGIN
                v_result.put('bank_hint', v_parsed.get_string('bank_hint'));
            EXCEPTION WHEN OTHERS THEN v_result.put_null('bank_hint');
            END;
            BEGIN
                v_result.put('confidence', NVL(v_parsed.get_number('confidence'), 0));
            EXCEPTION WHEN OTHERS THEN v_result.put('confidence', 0);
            END;
            v_result.put('raw', v_clean);
        EXCEPTION
            WHEN OTHERS THEN
                v_status := 'PARSE_ERROR';
                v_result.put('status', 'parse_error');
                v_result.put('error', SUBSTR(SQLERRM, 1, 400));
                v_result.put_null('reference');
                v_result.put_null('amount');
                v_result.put_null('transfer_datetime');
                v_result.put_null('bank_hint');
                v_result.put('confidence', 0);
                IF v_clean IS NOT NULL THEN
                    v_result.put('raw', v_clean);
                END IF;
        END;

        pkg_aox_util.pr_log_ai(
            pi_process_name    => 'PKG_AOX_IA_MANAGER.FN_EXTRACT_TRANSFER_RECEIPT',
            pi_session_id      => NULL,
            pi_org_id          => pi_org_id,
            pi_user_id         => NULL,
            pi_role_id         => NULL,
            pi_pro_id          => NULL,
            pi_status          => CASE WHEN v_status = 'OK' THEN 'OK' ELSE 'ERROR' END,
            pi_status_code     => CASE WHEN v_status = 'OK' THEN 200 ELSE 500 END,
            pi_error_code      => NULL,
            pi_error_message   => CASE WHEN v_status = 'OK' THEN NULL ELSE v_status END,
            pi_error_stack     => NULL,
            pi_error_backtrace => NULL,
            pi_prompt          => v_user,
            pi_request_payload => TO_CLOB(SUBSTR(pi_image_url, 1, 500)),
            pi_response_body   => v_clean,
            pi_parameters      => NULL
        );

        RETURN v_result.to_clob();
    END fn_extract_transfer_receipt;

    FUNCTION fn_transcribe_whisper_audio(
        pi_audio_base64 IN CLOB,
        pi_mime_type    IN VARCHAR2 DEFAULT 'audio/webm',
        pi_filename     IN VARCHAR2 DEFAULT 'cita.webm'
    ) RETURN CLOB IS
        v_endpoint            VARCHAR2(500) := NVL(
            fn_get_parameter('AZURE_OPENAI_WHISPER_ENDPOINT'),
            fn_get_parameter('AZURE_OPENAI_ENDPOINT')
        );
        v_whisper_deployment  VARCHAR2(100) := NVL(fn_get_parameter('AZURE_OPENAI_WHISPER_DEPLOYMENT'), 'whisper');
        v_api_version         VARCHAR2(50)  := NVL(
            fn_get_parameter('AZURE_OPENAI_WHISPER_API_VERSION'),
            fn_get_parameter('AZURE_OPENAI_API_VERSION')
        );
        v_api_key             VARCHAR2(4000) := NVL(
            fn_get_parameter('AZURE_OPENAI_WHISPER_API_KEY'),
            fn_get_parameter('AZURE_OPENAI_API_KEY')
        );
        v_url                 VARCHAR2(2000);
        v_boundary            VARCHAR2(100) := '----HaselWhisperBoundary';
        v_audio_blob          BLOB;
        v_body_blob           BLOB;
        v_response            CLOB;
        v_transcript          CLOB;
        v_mime_type           VARCHAR2(100) := NVL(TRIM(pi_mime_type), 'audio/webm');
        v_filename            VARCHAR2(200) := NVL(TRIM(pi_filename), 'cita.webm');
    BEGIN
        IF pi_audio_base64 IS NULL OR DBMS_LOB.GETLENGTH(pi_audio_base64) = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'El audio esta vacio.');
        END IF;

        IF v_endpoint IS NULL OR v_api_key IS NULL OR v_api_version IS NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'Faltan parametros Azure OpenAI para Whisper.');
        END IF;

        v_audio_blob := fn_base64_clob_to_blob(pi_audio_base64);
        IF v_audio_blob IS NULL OR DBMS_LOB.GETLENGTH(v_audio_blob) = 0 THEN
            RAISE_APPLICATION_ERROR(-20003, 'No fue posible decodificar el audio.');
        END IF;

        v_url := RTRIM(v_endpoint, '/')
              || '/openai/deployments/'
              || v_whisper_deployment
              || '/audio/transcriptions?api-version='
              || v_api_version;

        pr_append_text_to_blob(
            v_body_blob,
            '--' || v_boundary || CHR(13) || CHR(10)
            || 'Content-Disposition: form-data; name="file"; filename="' || v_filename || '"' || CHR(13) || CHR(10)
            || 'Content-Type: ' || v_mime_type || CHR(13) || CHR(10) || CHR(13) || CHR(10)
        );
        pr_append_blob_to_blob(v_body_blob, v_audio_blob);
        pr_append_text_to_blob(
            v_body_blob,
            CHR(13) || CHR(10) || '--' || v_boundary || CHR(13) || CHR(10)
            || 'Content-Disposition: form-data; name="language"' || CHR(13) || CHR(10) || CHR(13) || CHR(10)
            || 'es' || CHR(13) || CHR(10)
            || '--' || v_boundary || CHR(13) || CHR(10)
            || 'Content-Disposition: form-data; name="prompt"' || CHR(13) || CHR(10) || CHR(13) || CHR(10)
            || 'Cita medica o de servicios en espanol paraguayo. Nombres propios, correcciones del hablante, fechas relativas como proximo lunes o manana.'
            || CHR(13) || CHR(10)
            || '--' || v_boundary || '--' || CHR(13) || CHR(10)
        );

        apex_web_service.g_request_headers.delete;
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'multipart/form-data; boundary=' || v_boundary;
        apex_web_service.g_request_headers(2).name  := 'api-key';
        apex_web_service.g_request_headers(2).value := v_api_key;

        v_response := apex_web_service.make_rest_request(
            p_url         => v_url,
            p_http_method => 'POST',
            p_body_blob   => v_body_blob
        );

        SELECT json_value(v_response, '$.text' RETURNING CLOB)
        INTO v_transcript
        FROM dual;

        IF v_transcript IS NULL OR TRIM(v_transcript) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20004, 'No se detecto voz en la grabacion.');
        END IF;

        RETURN v_transcript;
    END fn_transcribe_whisper_audio;

    FUNCTION fn_build_appointment_catalog_json(
        pi_org_id  IN NUMBER,
        pi_role_id IN NUMBER,
        pi_prof_id IN NUMBER
    ) RETURN CLOB IS
        v_professionals json_array_t := json_array_t();
        v_locations     json_array_t := json_array_t();
        v_services      json_array_t := json_array_t();
        v_obj           json_object_t;
        v_catalog       json_object_t := json_object_t();
    BEGIN
        FOR rec IN (
            SELECT p.id_professional,
                   NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS full_name
            FROM professional p
            JOIN app_user u ON u.id_user = p.usr_id_user
            WHERE p.org_id_organization = pi_org_id
              AND p.is_active = 1
              AND (
                    pi_role_id <> pkg_aox_util.fn_rol('PROFESIONAL')
                 OR pi_prof_id IS NULL
                 OR pi_prof_id <= 0
                 OR p.id_professional = pi_prof_id
              )
            ORDER BY full_name
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('id_professional', rec.id_professional);
            v_obj.put('name', rec.full_name);
            v_professionals.append(v_obj);
        END LOOP;

        FOR rec IN (
            SELECT id_location, name
            FROM location
            WHERE org_id_organization = pi_org_id
              AND is_active = 1
            ORDER BY name
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('id_location', rec.id_location);
            v_obj.put('name', rec.name);
            v_locations.append(v_obj);
        END LOOP;

        FOR rec IN (
            SELECT id_service, name, duration_minutes
            FROM service
            WHERE org_id_organization = pi_org_id
              AND is_active = 1
            ORDER BY name
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('id_service', rec.id_service);
            v_obj.put('name', rec.name);
            v_obj.put('duration_minutes', rec.duration_minutes);
            v_services.append(v_obj);
        END LOOP;

        v_catalog.put('professionals', v_professionals);
        v_catalog.put('locations', v_locations);
        v_catalog.put('services', v_services);
        RETURN v_catalog.to_clob();
    END fn_build_appointment_catalog_json;

    FUNCTION fn_json_opt_string(pi_obj IN json_object_t, pi_key IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF pi_obj IS NULL OR NOT pi_obj.has(pi_key) THEN
            RETURN NULL;
        END IF;
        RETURN TRIM(pi_obj.get_string(pi_key));
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END fn_json_opt_string;

    FUNCTION fn_normalize_phone_digits(pi_phone IN VARCHAR2) RETURN VARCHAR2 IS
        v_digits VARCHAR2(20);
    BEGIN
        v_digits := REGEXP_REPLACE(NVL(pi_phone, ''), '[^0-9]', '');
        IF v_digits IS NULL THEN
            RETURN NULL;
        END IF;
        IF LENGTH(v_digits) > 9 THEN
            v_digits := SUBSTR(v_digits, -9);
        END IF;
        RETURN v_digits;
    END fn_normalize_phone_digits;

    FUNCTION fn_normalize_person_name(pi_name IN VARCHAR2) RETURN VARCHAR2 IS
        v_text VARCHAR2(500);
    BEGIN
        v_text := TRIM(NVL(pi_name, ''));
        IF v_text IS NULL THEN
            RETURN NULL;
        END IF;

        v_text := TRIM(REGEXP_SUBSTR(v_text, '^[^|]+'));

        v_text := TRANSLATE(v_text, 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNAEIOUUN');
        v_text := LOWER(v_text);
        v_text := REGEXP_REPLACE(v_text, '[^a-z0-9]', ' ');
        v_text := TRIM(REGEXP_REPLACE(v_text, '\s+', ' '));

        IF v_text IS NULL OR v_text = '' THEN
            RETURN NULL;
        END IF;

        RETURN v_text;
    END fn_normalize_person_name;

    FUNCTION fn_person_names_fully_match(
        pi_spoken    IN VARCHAR2,
        pi_candidate IN VARCHAR2
    ) RETURN BOOLEAN IS
        v_spoken    VARCHAR2(500);
        v_candidate VARCHAR2(500);
    BEGIN
        v_spoken := fn_normalize_person_name(pi_spoken);
        v_candidate := fn_normalize_person_name(pi_candidate);

        IF v_spoken IS NULL OR v_candidate IS NULL THEN
            RETURN FALSE;
        END IF;

        RETURN v_spoken = v_candidate;
    END fn_person_names_fully_match;

    FUNCTION fn_lookup_customer_by_full_name(
        pi_org_id IN NUMBER,
        pi_name   IN VARCHAR2
    ) RETURN NUMBER IS
        v_spoken_norm VARCHAR2(500) := fn_normalize_person_name(pi_name);
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 OR v_spoken_norm IS NULL THEN
            RETURN NULL;
        END IF;

        -- No usar fn_normalize_person_name en SQL (PLS-00231); comparar en PL/SQL.
        FOR r IN (
            SELECT c.id_customer, c.full_name
              FROM customer c
             WHERE c.org_id_organization = pi_org_id
        ) LOOP
            IF fn_normalize_person_name(r.full_name) = v_spoken_norm THEN
                RETURN r.id_customer;
            END IF;
        END LOOP;

        RETURN NULL;
    END fn_lookup_customer_by_full_name;

    FUNCTION fn_lookup_customer_by_phone(
        pi_org_id IN NUMBER,
        pi_phone  IN VARCHAR2
    ) RETURN NUMBER IS
        v_digits VARCHAR2(20) := fn_normalize_phone_digits(pi_phone);
        v_id     NUMBER;
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 OR v_digits IS NULL THEN
            RETURN NULL;
        END IF;

        BEGIN
            SELECT c.id_customer
            INTO v_id
            FROM customer c
            WHERE c.org_id_organization = pi_org_id
              AND REGEXP_REPLACE(c.phone_number, '[^0-9]', '') = v_digits
            FETCH FIRST 1 ROW ONLY;

            RETURN v_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN NULL;
        END;
    END fn_lookup_customer_by_phone;

    PROCEDURE pr_fill_customer_fields(
        pi_org_id  IN NUMBER,
        pi_cust_id IN NUMBER,
        pio_draft  IN OUT NOCOPY json_object_t
    ) IS
        v_name  VARCHAR2(200);
        v_phone VARCHAR2(20);
    BEGIN
        IF NVL(pi_cust_id, 0) <= 0 THEN
            RETURN;
        END IF;

        SELECT TRIM(full_name), TRIM(phone_number)
        INTO v_name, v_phone
        FROM customer
        WHERE id_customer = pi_cust_id
          AND org_id_organization = pi_org_id;

        pio_draft.put('id_customer', pi_cust_id);
        IF v_name IS NOT NULL THEN
            pio_draft.put('customer_name', v_name);
        END IF;
        IF v_phone IS NOT NULL THEN
            pio_draft.put('customer_phone', v_phone);
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            NULL;
    END pr_fill_customer_fields;

    FUNCTION fn_filter_vector_candidates(pi_search_json IN CLOB) RETURN json_array_t IS
        v_raw      json_array_t;
        v_filtered json_array_t := json_array_t();
        v_obj      json_object_t;
        v_score    NUMBER;
    BEGIN
        IF pi_search_json IS NULL OR TRIM(pi_search_json) IN ('[]', 'null') THEN
            RETURN v_filtered;
        END IF;

        v_raw := json_array_t.parse(pi_search_json);

        FOR i IN 0 .. v_raw.get_size - 1 LOOP
            v_obj   := TREAT(v_raw.get(i) AS json_object_t);
            v_score := v_obj.get_number('score');

            IF v_score >= fn_vector_min_score THEN
                v_filtered.append(v_obj);
            END IF;
        END LOOP;

        RETURN v_filtered;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN json_array_t();
    END fn_filter_vector_candidates;

    FUNCTION fn_resolve_entity_slot(
        pi_org_id      IN NUMBER,
        pi_entity_type IN VARCHAR2,
        pi_hint        IN VARCHAR2
    ) RETURN json_object_t IS
        v_result       json_object_t := json_object_t();
        v_candidates   json_array_t;
        v_top          json_object_t;
        v_second       json_object_t;
        v_entity_id    NUMBER;
        v_search       CLOB;
        v_top_score    NUMBER;
        v_second_score NUMBER;
        v_mode         VARCHAR2(30) := 'NONE';
        v_top_label    VARCHAR2(500);
    BEGIN
        v_result.put('candidates', json_array_t());
        v_result.put('resolution_mode', v_mode);

        IF NVL(pi_org_id, 0) <= 0 OR TRIM(pi_hint) IS NULL THEN
            RETURN v_result;
        END IF;

        BEGIN
            v_search := pkg_aox_vector_search.fn_search_top_k(
                pi_org_id      => pi_org_id,
                pi_entity_type => pi_entity_type,
                pi_query_text  => TRIM(pi_hint),
                pi_top_k       => fn_vector_top_k
            );
        EXCEPTION
            WHEN OTHERS THEN
                v_result.put('resolution_mode', 'ERROR');
                RETURN v_result;
        END;

        v_candidates := fn_filter_vector_candidates(v_search);
        v_result.put('candidates', v_candidates);
        v_result.put('candidate_count', v_candidates.get_size);

        IF v_candidates.get_size > 0 THEN
            v_top       := TREAT(v_candidates.get(0) AS json_object_t);
            v_top_score := v_top.get_number('score');
            v_result.put('top_score', v_top_score);
            v_entity_id := TRUNC(v_top.get_number('entity_id'));
            v_mode      := 'AUTO';

            IF UPPER(TRIM(pi_entity_type)) = pkg_aox_vector_search.c_entity_customer THEN
                v_top_label := COALESCE(
                    fn_json_opt_string(v_top, 'label'),
                    fn_json_opt_string(v_top, 'source_text')
                );

                IF NOT fn_person_names_fully_match(pi_hint, v_top_label) THEN
                    v_entity_id := NULL;
                    v_mode      := 'NAME_MISMATCH';
                END IF;
            END IF;

            IF NVL(v_entity_id, 0) > 0 THEN
                v_result.put('entity_id', v_entity_id);
            END IF;

            IF v_candidates.get_size > 1 THEN
                v_second       := TREAT(v_candidates.get(1) AS json_object_t);
                v_second_score := v_second.get_number('score');
                v_result.put('second_score', v_second_score);
            END IF;
        END IF;

        v_result.put('resolution_mode', v_mode);
        RETURN v_result;
    EXCEPTION
        WHEN OTHERS THEN
            v_result.put('resolution_mode', 'ERROR');
            RETURN v_result;
    END fn_resolve_entity_slot;

    PROCEDURE pr_apply_slot_resolution(
        pi_org_id         IN NUMBER,
        pi_entity_type    IN VARCHAR2,
        pi_hint           IN VARCHAR2,
        pi_id_key         IN VARCHAR2,
        pi_candidate_key  IN VARCHAR2,
        pio_draft         IN OUT NOCOPY json_object_t,
        pio_candidates    IN OUT NOCOPY json_object_t,
        pio_trace         IN OUT NOCOPY json_array_t
    ) IS
        v_resolution json_object_t;
        v_entity_id  NUMBER;
        v_cands      json_array_t;
        v_mode       VARCHAR2(30);
        v_top_score  NUMBER;
        v_second_score NUMBER;
        v_cand_count PLS_INTEGER;
    BEGIN
        IF TRIM(pi_hint) IS NULL THEN
            RETURN;
        END IF;

        IF pio_draft.has(pi_id_key) AND NVL(pio_draft.get_number(pi_id_key), 0) > 0 THEN
            RETURN;
        END IF;

        v_resolution := fn_resolve_entity_slot(pi_org_id, pi_entity_type, pi_hint);
        v_cands      := TREAT(v_resolution.get('candidates') AS json_array_t);
        v_mode       := v_resolution.get_string('resolution_mode');
        v_cand_count := v_cands.get_size;

        IF v_resolution.has('top_score') THEN
            v_top_score := v_resolution.get_number('top_score');
        END IF;
        IF v_resolution.has('second_score') THEN
            v_second_score := v_resolution.get_number('second_score');
        END IF;

        IF v_resolution.has('entity_id') THEN
            v_entity_id := TRUNC(v_resolution.get_number('entity_id'));
            IF v_entity_id > 0 THEN
                pio_draft.put(pi_id_key, v_entity_id);
            END IF;
        END IF;

        pr_append_resolution_trace(
            pio_trace          => pio_trace,
            pi_field             => pi_candidate_key,
            pi_entity_type       => pi_entity_type,
            pi_hint              => pi_hint,
            pi_mode              => v_mode,
            pi_entity_id         => v_entity_id,
            pi_top_score         => v_top_score,
            pi_second_score      => v_second_score,
            pi_candidate_count   => v_cand_count
        );
    END pr_apply_slot_resolution;

    FUNCTION fn_resolve_appointment_draft_entities(
        pi_slots      IN json_object_t,
        pi_org_id     IN NUMBER,
        pi_role_id    IN NUMBER,
        pi_prof_id    IN NUMBER,
        pio_trace     IN OUT NOCOPY json_array_t
    ) RETURN json_object_t IS
        v_out          json_object_t;
        v_candidates   json_object_t := json_object_t();
        v_customer_id  NUMBER;
        v_customer_name VARCHAR2(200);
        v_customer_phone VARCHAR2(20);
        v_hint         VARCHAR2(500);
        v_prof_hint    VARCHAR2(200);
        v_loc_hint     VARCHAR2(200);
        v_svc_hint     VARCHAR2(200);
    BEGIN
        IF pi_slots IS NULL THEN
            RETURN json_object_t();
        END IF;

        IF pio_trace IS NULL THEN
            pio_trace := json_array_t();
        END IF;

        v_out := json_object_t.parse(pi_slots.to_clob());

        v_customer_name  := fn_json_opt_string(v_out, 'customer_name');
        v_customer_phone := fn_json_opt_string(v_out, 'customer_phone');
        v_customer_id    := CASE
            WHEN v_out.has('id_customer') THEN v_out.get_number('id_customer')
            ELSE NULL
        END;

        IF NVL(v_customer_id, 0) <= 0 AND v_customer_phone IS NOT NULL THEN
            v_customer_id := fn_lookup_customer_by_phone(pi_org_id, v_customer_phone);
            IF NVL(v_customer_id, 0) > 0 THEN
                pr_fill_customer_fields(pi_org_id, v_customer_id, v_out);
                v_hint := NVL(v_customer_name, v_customer_phone);
                pr_append_resolution_trace(
                    pio_trace        => pio_trace,
                    pi_field         => 'customer',
                    pi_entity_type   => pkg_aox_vector_search.c_entity_customer,
                    pi_hint          => v_hint,
                    pi_mode          => 'PHONE_EXACT',
                    pi_entity_id     => v_customer_id
                );
            END IF;
        END IF;

        IF NVL(v_customer_id, 0) <= 0 AND v_customer_name IS NOT NULL THEN
            v_customer_id := fn_lookup_customer_by_full_name(pi_org_id, v_customer_name);
            IF NVL(v_customer_id, 0) > 0 THEN
                v_out.put('id_customer', v_customer_id);
                pr_fill_customer_fields(pi_org_id, v_customer_id, v_out);
                pr_append_resolution_trace(
                    pio_trace        => pio_trace,
                    pi_field         => 'customer',
                    pi_entity_type   => pkg_aox_vector_search.c_entity_customer,
                    pi_hint          => v_customer_name,
                    pi_mode          => 'NAME_EXACT',
                    pi_entity_id     => v_customer_id
                );
            END IF;
        END IF;

        IF NVL(v_customer_id, 0) <= 0 AND v_customer_name IS NOT NULL THEN
            pr_apply_slot_resolution(
                pi_org_id        => pi_org_id,
                pi_entity_type   => pkg_aox_vector_search.c_entity_customer,
                pi_hint          => v_customer_name,
                pi_id_key        => 'id_customer',
                pi_candidate_key => 'customer',
                pio_draft        => v_out,
                pio_candidates   => v_candidates,
                pio_trace        => pio_trace
            );

            IF v_out.has('id_customer') AND NVL(v_out.get_number('id_customer'), 0) > 0 THEN
                pr_fill_customer_fields(pi_org_id, v_out.get_number('id_customer'), v_out);
            END IF;
        END IF;

        IF pi_role_id = pkg_aox_util.fn_rol('PROFESIONAL') AND NVL(pi_prof_id, 0) > 0 THEN
            v_out.put('pro_id_professional', pi_prof_id);
            v_prof_hint := COALESCE(
                fn_json_opt_string(v_out, 'professional_name'),
                fn_json_opt_string(v_out, 'professional_hint'),
                'profesional_sesion'
            );
            pr_append_resolution_trace(
                pio_trace        => pio_trace,
                pi_field         => 'professional',
                pi_entity_type   => pkg_aox_vector_search.c_entity_professional,
                pi_hint          => v_prof_hint,
                pi_mode          => 'ROLE_FIXED',
                pi_entity_id     => pi_prof_id
            );
        ELSE
            v_prof_hint := COALESCE(
                fn_json_opt_string(v_out, 'professional_name'),
                fn_json_opt_string(v_out, 'professional_hint')
            );
            pr_apply_slot_resolution(
                pi_org_id        => pi_org_id,
                pi_entity_type   => pkg_aox_vector_search.c_entity_professional,
                pi_hint          => v_prof_hint,
                pi_id_key        => 'pro_id_professional',
                pi_candidate_key => 'professional',
                pio_draft        => v_out,
                pio_candidates   => v_candidates,
                pio_trace        => pio_trace
            );
        END IF;

        v_loc_hint := COALESCE(
            fn_json_opt_string(v_out, 'location_name'),
            fn_json_opt_string(v_out, 'location_hint')
        );
        pr_apply_slot_resolution(
            pi_org_id        => pi_org_id,
            pi_entity_type   => pkg_aox_vector_search.c_entity_location,
            pi_hint          => v_loc_hint,
            pi_id_key        => 'loc_id_location',
            pi_candidate_key => 'location',
            pio_draft        => v_out,
            pio_candidates   => v_candidates,
            pio_trace        => pio_trace
        );

        v_svc_hint := COALESCE(
            fn_json_opt_string(v_out, 'service_name'),
            fn_json_opt_string(v_out, 'service_hint')
        );
        pr_apply_slot_resolution(
            pi_org_id        => pi_org_id,
            pi_entity_type   => pkg_aox_vector_search.c_entity_service,
            pi_hint          => v_svc_hint,
            pi_id_key        => 'ser_id_service',
            pi_candidate_key => 'service',
            pio_draft        => v_out,
            pio_candidates   => v_candidates,
            pio_trace        => pio_trace
        );

        RETURN v_out;
    END fn_resolve_appointment_draft_entities;

    FUNCTION fn_appointment_voice_system_prompt RETURN CLOB IS
    BEGIN
        RETURN q'[
            Eres un extractor de datos para agendar citas en una clinica o negocio de servicios en Paraguay.
            Responde SOLO JSON valido, sin markdown ni texto adicional.

            REGLAS GENERALES:
            - NO inventes IDs numericos.
            - Extrae nombres y datos textuales; el backend resolvera las entidades contra el catalogo.
            - Nunca inventes telefonos. Para telefonos paraguayos usa 9 digitos locales sin +595.
            - start_time y end_time deben ser ISO 8601 con offset del timezone recibido (ej. 2026-06-16T09:00:00-03:00).

            CORRECCIONES EN EL AUDIO (MUY IMPORTANTE):
            - La transcripcion puede incluir autocorrecciones: "perdon", "perdón", "no", "mejor dicho", "corrijo",
              "en realidad", "dije mal", "quise decir", "me confundi", "no es X es Y".
            - Cuando el hablante corrige un dato, usa SIEMPRE el ULTIMO valor valido y descarta el anterior.
            - Ejemplo: "cliente Daniel Villasanti, perdon es Ramon Villasanti" -> customer_name = "Ramon Villasanti".
            - Ejemplo: "el lunes... no, mejor el martes" -> calcula la fecha del martes, no del lunes.
            - Si hay conflicto, prioriza lo dicho DESPUES de la correccion.

            FECHAS Y HORAS RELATIVAS:
            - Usa current_datetime, current_date y current_weekday como referencia absoluta.
            - Interpreta expresiones como: hoy, manana, pasado manana, este lunes/martes/..., proximo lunes/martes/...,
              la semana que viene, dentro de X dias, a las 3 de la tarde, a las 10, etc.
            - "Proximo lunes" = el primer lunes estrictamente posterior a hoy. Si hoy es lunes, "proximo lunes"
              normalmente es el lunes de la semana siguiente (salvo que digan "este lunes" o "hoy").
            - Calcula la fecha concreta antes de responder start_time.
            - Si mencionan el dia pero NO la hora, usa las 09:00 hora local.
            - Si mencionan hora explicita, usala en formato 24 horas.
            - end_time = start_time + duracion del servicio en catalog.services si la conoces; si no, +60 minutos.
            - No uses fechas del pasado salvo que lo pidan explicitamente.

            CAMPOS JSON ESPERADOS:
            customer_name, customer_phone, professional_name, location_name, service_name,
            start_time, end_time, interpretation, confidence (high|medium|low), missing_fields (array).

            FORMATO DE NOMBRES:
            - customer_name con iniciales en mayuscula (Title Case) cuando el cliente es nuevo.
            - professional_name, location_name y service_name tal como suenan, alineados al catalogo si es posible.

            Si un dato no esta claro, dejalo null y agregalo a missing_fields.
            En interpretation resume brevemente como interpretaste correcciones y fechas relativas.
            ]';
    END fn_appointment_voice_system_prompt;

    FUNCTION fn_parse_iso_timestamp_tz(pi_value IN VARCHAR2) RETURN TIMESTAMP WITH TIME ZONE IS
        v_raw VARCHAR2(200) := TRIM(pi_value);
    BEGIN
        IF v_raw IS NULL THEN
            RETURN NULL;
        END IF;

        BEGIN
            RETURN TO_TIMESTAMP_TZ(v_raw, 'YYYY-MM-DD"T"HH24:MI:SS.FF9TZH:TZM', 'NLS_DATE_LANGUAGE=ENGLISH');
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        BEGIN
            RETURN TO_TIMESTAMP_TZ(v_raw, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM', 'NLS_DATE_LANGUAGE=ENGLISH');
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        BEGIN
            RETURN TO_TIMESTAMP_TZ(v_raw, 'YYYY-MM-DD"T"HH24:MI:SSXFFTZH:TZM', 'NLS_DATE_LANGUAGE=ENGLISH');
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        RETURN NULL;
    END fn_parse_iso_timestamp_tz;

    FUNCTION fn_sanitize_appointment_draft(
        pi_draft    IN json_object_t,
        pi_org_id   IN NUMBER,
        pi_role_id  IN NUMBER,
        pi_prof_id  IN NUMBER
    ) RETURN json_object_t IS
        v_out           json_object_t := json_object_t();
        v_prof_id       NUMBER;
        v_loc_id        NUMBER;
        v_service_id    NUMBER;
        v_customer_id   NUMBER;
        v_count         NUMBER;
        v_service_mins  NUMBER;
        v_start_time    TIMESTAMP WITH TIME ZONE;
        v_end_time      TIMESTAMP WITH TIME ZONE;
        v_missing       json_array_t := json_array_t();
        v_start_adjusted BOOLEAN := FALSE;
    BEGIN
        IF pi_draft IS NULL THEN
            RETURN v_out;
        END IF;

        v_customer_id := CASE
            WHEN pi_draft.has('id_customer') THEN pi_draft.get_number('id_customer')
            ELSE NULL
        END;

        v_prof_id := CASE
            WHEN pi_draft.has('pro_id_professional') THEN pi_draft.get_number('pro_id_professional')
            ELSE NULL
        END;

        IF pi_role_id = pkg_aox_util.fn_rol('PROFESIONAL') AND NVL(pi_prof_id, 0) > 0 THEN
            v_prof_id := pi_prof_id;
        ELSIF NVL(v_prof_id, 0) > 0 THEN
            SELECT COUNT(*)
            INTO v_count
            FROM professional
            WHERE id_professional = v_prof_id
              AND org_id_organization = pi_org_id
              AND is_active = 1;

            IF v_count = 0 THEN
                v_prof_id := NULL;
            END IF;
        END IF;

        v_loc_id := CASE
            WHEN pi_draft.has('loc_id_location') THEN pi_draft.get_number('loc_id_location')
            ELSE NULL
        END;

        IF NVL(v_loc_id, 0) > 0 THEN
            SELECT COUNT(*)
            INTO v_count
            FROM location
            WHERE id_location = v_loc_id
              AND org_id_organization = pi_org_id
              AND is_active = 1;

            IF v_count = 0 THEN
                v_loc_id := NULL;
            END IF;
        END IF;

        v_service_id := CASE
            WHEN pi_draft.has('ser_id_service') THEN pi_draft.get_number('ser_id_service')
            ELSE NULL
        END;

        IF NVL(v_service_id, 0) > 0 THEN
            BEGIN
                SELECT NVL(duration_minutes, 60)
                INTO v_service_mins
                FROM service
                WHERE id_service = v_service_id
                  AND org_id_organization = pi_org_id
                  AND is_active = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_service_id := NULL;
                    v_service_mins := NULL;
            END;
        ELSE
            v_service_mins := NULL;
        END IF;

        IF pi_draft.has('customer_name') THEN
            IF NVL(v_customer_id, 0) <= 0 THEN
                v_out.put(
                    'customer_name',
                    INITCAP(TRIM(pi_draft.get_string('customer_name')))
                );
            ELSE
                v_out.put('customer_name', TRIM(pi_draft.get_string('customer_name')));
            END IF;
        END IF;
        IF pi_draft.has('customer_phone') THEN
            v_out.put('customer_phone', TRIM(pi_draft.get_string('customer_phone')));
        END IF;
        IF NVL(v_customer_id, 0) > 0 THEN
            v_out.put('id_customer', v_customer_id);
        END IF;
        IF NVL(v_prof_id, 0) > 0 THEN
            v_out.put('pro_id_professional', v_prof_id);
        END IF;
        IF NVL(v_loc_id, 0) > 0 THEN
            v_out.put('loc_id_location', v_loc_id);
        END IF;
        IF NVL(v_service_id, 0) > 0 THEN
            v_out.put('ser_id_service', v_service_id);
        END IF;

        IF pi_draft.has('start_time') AND TRIM(pi_draft.get_string('start_time')) IS NOT NULL THEN
            v_start_time := fn_parse_iso_timestamp_tz(pi_draft.get_string('start_time'));
            IF v_start_time IS NOT NULL
               AND TO_CHAR(CAST(v_start_time AS TIMESTAMP), 'HH24:MI:SS') = '00:00:00' THEN
                v_start_time := v_start_time + NUMTODSINTERVAL(9, 'HOUR');
                v_start_adjusted := TRUE;
            END IF;
            IF v_start_time IS NOT NULL THEN
                v_out.put(
                    'start_time',
                    TO_CHAR(v_start_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF9TZH:TZM', 'NLS_DATE_LANGUAGE=ENGLISH')
                );
            END IF;
        END IF;

        IF pi_draft.has('end_time') AND TRIM(pi_draft.get_string('end_time')) IS NOT NULL THEN
            v_end_time := fn_parse_iso_timestamp_tz(pi_draft.get_string('end_time'));
            IF v_end_time IS NOT NULL THEN
                v_out.put(
                    'end_time',
                    TO_CHAR(v_end_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF9TZH:TZM', 'NLS_DATE_LANGUAGE=ENGLISH')
                );
            END IF;
        END IF;

        IF v_start_adjusted
           AND v_out.has('start_time')
           AND v_out.has('end_time') THEN
            BEGIN
                v_start_time := fn_parse_iso_timestamp_tz(v_out.get_string('start_time'));
                v_end_time   := fn_parse_iso_timestamp_tz(v_out.get_string('end_time'));
                IF v_end_time IS NOT NULL
                   AND v_start_time IS NOT NULL
                   AND v_end_time <= v_start_time + NUMTODSINTERVAL(30, 'MINUTE') THEN
                    v_out.remove('end_time');
                    v_end_time := NULL;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
        END IF;

        IF NOT v_out.has('end_time') AND v_out.has('start_time') AND NVL(v_service_mins, 0) > 0 THEN
            BEGIN
                v_start_time := fn_parse_iso_timestamp_tz(v_out.get_string('start_time'));
                IF v_start_time IS NOT NULL THEN
                    v_end_time := v_start_time + NUMTODSINTERVAL(v_service_mins, 'MINUTE');
                    v_out.put(
                        'end_time',
                        TO_CHAR(v_end_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF9TZH:TZM', 'NLS_DATE_LANGUAGE=ENGLISH')
                    );
                END IF;
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
        ELSIF NOT v_out.has('end_time') AND v_out.has('start_time') THEN
            BEGIN
                v_start_time := fn_parse_iso_timestamp_tz(v_out.get_string('start_time'));
                IF v_start_time IS NOT NULL THEN
                    v_end_time := v_start_time + NUMTODSINTERVAL(60, 'MINUTE');
                    v_out.put(
                        'end_time',
                        TO_CHAR(v_end_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF9TZH:TZM', 'NLS_DATE_LANGUAGE=ENGLISH')
                    );
                END IF;
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
        END IF;

        IF NOT v_out.has('customer_name') OR TRIM(v_out.get_string('customer_name')) IS NULL THEN
            v_missing.append('customer_name');
        END IF;
        IF NOT v_out.has('customer_phone') OR TRIM(v_out.get_string('customer_phone')) IS NULL THEN
            v_missing.append('customer_phone');
        END IF;
        IF NOT v_out.has('pro_id_professional') THEN v_missing.append('pro_id_professional'); END IF;
        IF NOT v_out.has('loc_id_location') THEN v_missing.append('loc_id_location'); END IF;
        IF NOT v_out.has('ser_id_service') THEN v_missing.append('ser_id_service'); END IF;
        IF NOT v_out.has('start_time') THEN v_missing.append('start_time'); END IF;
        IF NOT v_out.has('end_time') THEN v_missing.append('end_time'); END IF;

        IF pi_draft.has('confidence') THEN
            v_out.put('confidence', LOWER(TRIM(pi_draft.get_string('confidence'))));
        ELSIF v_missing.get_size <= 2 THEN
            v_out.put('confidence', 'medium');
        ELSE
            v_out.put('confidence', 'low');
        END IF;

        v_out.put('missing_fields', v_missing);

        IF pi_draft.has('interpretation') THEN
            v_out.put('interpretation', TRIM(pi_draft.get_string('interpretation')));
        END IF;

        RETURN v_out;
    END fn_sanitize_appointment_draft;

    FUNCTION fn_parse_appointment_draft_full(
        pi_org_id     IN NUMBER,
        pi_role_id    IN NUMBER,
        pi_prof_id    IN NUMBER,
        pi_transcript IN CLOB,
        pio_trace     IN OUT NOCOPY json_array_t
    ) RETURN json_object_t IS
        v_system_prompt CLOB;
        v_user_prompt   CLOB;
        v_user_obj      json_object_t := json_object_t();
        v_current_dt    VARCHAR2(64);
        v_current_date  VARCHAR2(10);
        v_current_day   VARCHAR2(30);
        v_catalog_json  CLOB;
        v_ai_text       CLOB;
        v_ai_clean      CLOB;
        v_draft_raw     json_object_t;
        v_draft_resolved json_object_t;
        v_draft         json_object_t;
        v_result        json_object_t := json_object_t();
        v_timezone      VARCHAR2(64) := pkg_aox_util.fn_app_timezone;
    BEGIN
        IF pi_transcript IS NULL OR DBMS_LOB.GETLENGTH(pi_transcript) = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'La transcripcion esta vacia.');
        END IF;

        IF pio_trace IS NULL THEN
            pio_trace := json_array_t();
        END IF;

        v_system_prompt := fn_appointment_voice_system_prompt;

        v_user_obj.put('transcript', DBMS_LOB.SUBSTR(pi_transcript, 32767, 1));
        v_current_dt := TO_CHAR(
            SYSTIMESTAMP AT TIME ZONE v_timezone,
            'YYYY-MM-DD"T"HH24:MI:SS.FF9TZH:TZM',
            'NLS_DATE_LANGUAGE=ENGLISH'
        );
        v_current_date := TO_CHAR(
            SYSTIMESTAMP AT TIME ZONE v_timezone,
            'YYYY-MM-DD',
            'NLS_DATE_LANGUAGE=ENGLISH'
        );
        v_current_day := TRIM(TO_CHAR(
            SYSTIMESTAMP AT TIME ZONE v_timezone,
            'DAY',
            'NLS_DATE_LANGUAGE=SPANISH'
        ));
        v_user_obj.put('current_datetime', v_current_dt);
        v_user_obj.put('current_date', v_current_date);
        v_user_obj.put('current_weekday', v_current_day);
        v_user_obj.put('timezone', v_timezone);

        v_catalog_json := fn_build_appointment_catalog_json(pi_org_id, pi_role_id, pi_prof_id);
        IF v_catalog_json IS NOT NULL AND LENGTH(TRIM(v_catalog_json)) > 2 THEN
            v_user_obj.put('catalog', json_object_t.parse(v_catalog_json));
        END IF;

        v_user_prompt := v_user_obj.to_clob();

        v_ai_text := fn_call_azure_openai_chat(v_system_prompt, v_user_prompt, 900, 0.1);

        IF v_ai_text IS NULL OR TRIM(v_ai_text) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20005, 'La IA no devolvio un borrador.');
        END IF;

        v_ai_clean := REPLACE(TRIM(v_ai_text), CHR(13), '');
        v_ai_clean := REGEXP_REPLACE(v_ai_clean, '^\s*```(?:json)?\s*', '', 1, 0, 'i');
        v_ai_clean := REGEXP_REPLACE(v_ai_clean, '\s*```\s*$', '');

        v_draft_raw      := json_object_t.parse(v_ai_clean);
        v_draft_resolved := fn_resolve_appointment_draft_entities(
            v_draft_raw,
            pi_org_id,
            pi_role_id,
            pi_prof_id,
            pio_trace
        );
        v_draft          := fn_sanitize_appointment_draft(v_draft_resolved, pi_org_id, pi_role_id, pi_prof_id);

        v_result.put('draft', v_draft);
        v_result.put('gpt_slots', v_draft_raw);
        v_result.put('resolution_trace', pio_trace);
        RETURN v_result;
    END fn_parse_appointment_draft_full;

    FUNCTION fn_parse_appointment_draft(
        pi_org_id     IN NUMBER,
        pi_role_id    IN NUMBER,
        pi_prof_id    IN NUMBER,
        pi_transcript IN CLOB
    ) RETURN CLOB IS
        v_trace  json_array_t := json_array_t();
        v_result json_object_t;
    BEGIN
        v_result := fn_parse_appointment_draft_full(
            pi_org_id,
            pi_role_id,
            pi_prof_id,
            pi_transcript,
            v_trace
        );
        RETURN TREAT(v_result.get('draft') AS json_object_t).to_clob();
    END fn_parse_appointment_draft;

    FUNCTION fn_process_voice_appointment_draft(
        pi_org_id       IN NUMBER,
        pi_role_id      IN NUMBER,
        pi_prof_id      IN NUMBER,
        pi_audio_base64 IN CLOB,
        pi_mime_type    IN VARCHAR2 DEFAULT 'audio/webm',
        pi_filename     IN VARCHAR2 DEFAULT 'cita.webm',
        pi_user_id      IN NUMBER DEFAULT NULL
    ) RETURN CLOB IS
        v_transcript CLOB;
        v_parse      json_object_t;
        v_draft      json_object_t;
        v_trace      json_array_t := json_array_t();
        v_gpt_slots  json_object_t;
        v_result     json_object_t := json_object_t();
    BEGIN
        v_transcript := fn_transcribe_whisper_audio(pi_audio_base64, pi_mime_type, pi_filename);
        v_parse      := fn_parse_appointment_draft_full(
            pi_org_id,
            pi_role_id,
            pi_prof_id,
            v_transcript,
            v_trace
        );
        v_draft     := TREAT(v_parse.get('draft') AS json_object_t);
        v_gpt_slots := TREAT(v_parse.get('gpt_slots') AS json_object_t);
        v_trace     := TREAT(v_parse.get('resolution_trace') AS json_array_t);

        pr_log_voice_vector_draft(
            pi_org_id           => pi_org_id,
            pi_user_id          => pi_user_id,
            pi_role_id          => pi_role_id,
            pi_prof_id          => pi_prof_id,
            pi_transcript       => v_transcript,
            pi_gpt_slots        => v_gpt_slots,
            pi_resolution_trace => v_trace,
            pi_draft            => v_draft
        );

        v_result.put('transcript', DBMS_LOB.SUBSTR(v_transcript, 32767, 1));
        v_result.put('draft', v_draft);
        RETURN v_result.to_clob();
    END fn_process_voice_appointment_draft;

END pkg_aox_ia_manager;
/

