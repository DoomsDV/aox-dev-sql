-- Respuestas ORDS de mas de 32 KB.
-- 190 de 194 handlers terminan con htp.prn(v_response_body). htp.prn recibe VARCHAR2
-- (max 32767 bytes): con un CLOB mas grande falla (ORA-06502) y ORDS devuelve 555
-- (p. ej. appointments/calendar de un mes en una org grande: 36 KB).
-- Patron recomendado por Oracle: escribir el CLOB por partes con htp.prn. Se centraliza
-- en pkg_aox_http.pr_print_clob y se reescriben los handlers existentes:
--   htp.prn(v_response_body)  ->  pkg_aox_http.pr_print_clob(v_response_body)
-- ORDS.define_handler reemplaza el handler; sus parametros (URI, headers como
-- X-Service-Token) se capturan antes y se redefinen igual. Si al final no coinciden
-- handlers o parametros, falla antes del COMMIT y no queda nada a medias.
-- Handlers nuevos: usar pkg_aox_http.pr_print_clob en vez de htp.prn(<clob>).
-- Como AOXDEV / WKSP_AOX. Idempotente (una segunda corrida no encuentra handlers).
-- Va despues de todas las migraciones que definen handlers.

SET SERVEROUTPUT ON SIZE UNLIMITED

@@../packages/PKG_AOX_HTTP.pls

DECLARE
    c_pattern CONSTANT VARCHAR2(100) := 'htp\.prn\(\s*v_response_body\s*\)';
    c_repl    CONSTANT VARCHAR2(100) := 'pkg_aox_http.pr_print_clob(v_response_body)';

    TYPE t_handler IS RECORD (
        id             NUMBER,
        module_name    VARCHAR2(255),
        uri_template   VARCHAR2(600),
        method         VARCHAR2(10),
        source_type    VARCHAR2(255),
        source         CLOB,
        items_per_page NUMBER,
        mimes_allowed  VARCHAR2(4000),
        comments       VARCHAR2(4000)
    );
    TYPE t_handlers IS TABLE OF t_handler;
    TYPE t_param IS RECORD (
        handler_id         NUMBER,
        name               VARCHAR2(255),
        bind_variable_name VARCHAR2(255),
        source_type        VARCHAR2(255),
        access_method      VARCHAR2(10),
        param_type         VARCHAR2(255),
        comments           VARCHAR2(4000)
    );
    TYPE t_params IS TABLE OF t_param;

    v_handlers      t_handlers;
    v_params        t_params;
    v_total_before  NUMBER;
    v_params_before NUMBER;
    v_total_after   NUMBER;
    v_params_after  NUMBER;
    v_left          NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_total_before FROM user_ords_handlers;
    SELECT COUNT(*) INTO v_params_before FROM user_ords_parameters;

    SELECT h.id, m.name, t.uri_template, h.method, h.source_type, h.source,
           h.items_per_page, h.mimes_allowed, h.comments
      BULK COLLECT INTO v_handlers
      FROM user_ords_handlers h
      JOIN user_ords_templates t ON t.id = h.template_id
      JOIN user_ords_modules m ON m.id = t.module_id
     WHERE REGEXP_LIKE(h.source, c_pattern, 'i');

    SELECT p.handler_id, p.name, p.bind_variable_name, p.source_type,
           p.access_method, p.param_type, p.comments
      BULK COLLECT INTO v_params
      FROM user_ords_parameters p
     WHERE p.handler_id IN (
               SELECT h.id FROM user_ords_handlers h WHERE REGEXP_LIKE(h.source, c_pattern, 'i'));

    DBMS_OUTPUT.PUT_LINE('Handlers a reescribir: ' || v_handlers.COUNT
                         || ' (parametros: ' || v_params.COUNT || ')');

    FOR i IN 1 .. v_handlers.COUNT LOOP
        ORDS.define_handler(
            p_module_name    => v_handlers(i).module_name,
            p_pattern        => v_handlers(i).uri_template,
            p_method         => v_handlers(i).method,
            p_source_type    => v_handlers(i).source_type,
            p_source         => REGEXP_REPLACE(v_handlers(i).source, c_pattern, c_repl, 1, 0, 'i'),
            p_items_per_page => v_handlers(i).items_per_page,
            p_mimes_allowed  => v_handlers(i).mimes_allowed,
            p_comments       => v_handlers(i).comments
        );
        FOR j IN 1 .. v_params.COUNT LOOP
            IF v_params(j).handler_id = v_handlers(i).id THEN
                ORDS.define_parameter(
                    p_module_name        => v_handlers(i).module_name,
                    p_pattern            => v_handlers(i).uri_template,
                    p_method             => v_handlers(i).method,
                    p_name               => v_params(j).name,
                    p_bind_variable_name => v_params(j).bind_variable_name,
                    p_source_type        => v_params(j).source_type,
                    p_param_type         => v_params(j).param_type,
                    p_access_method      => v_params(j).access_method,
                    p_comments           => v_params(j).comments
                );
            END IF;
        END LOOP;
    END LOOP;

    SELECT COUNT(*) INTO v_total_after FROM user_ords_handlers;
    SELECT COUNT(*) INTO v_params_after FROM user_ords_parameters;
    SELECT COUNT(*) INTO v_left FROM user_ords_handlers WHERE REGEXP_LIKE(source, c_pattern, 'i');

    IF v_total_after <> v_total_before OR v_params_after <> v_params_before OR v_left <> 0 THEN
        RAISE_APPLICATION_ERROR(-20000,
            'Verificacion fallida: handlers ' || v_total_before || '->' || v_total_after
            || ', parametros ' || v_params_before || '->' || v_params_after
            || ', pendientes ' || v_left);
    END IF;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('OK: ' || v_handlers.COUNT || ' handlers usan pkg_aox_http.pr_print_clob; '
                         || 'handlers=' || v_total_after || ' parametros=' || v_params_after);
END;
/
