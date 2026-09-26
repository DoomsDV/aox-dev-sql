PROMPT CREATE OR REPLACE PACKAGE pkg_aox_http
CREATE OR REPLACE PACKAGE pkg_aox_http AS
/**
 * Salida HTTP para handlers ORDS PL/SQL.
 *
 * htp.prn recibe VARCHAR2 (max 32767 bytes): pasarle un CLOB mas grande falla
 * (ORA-06502) y ORDS responde 555. pr_print_clob escribe el CLOB por partes.
 * Paquete sin dependencias propias: se puede recompilar sin invalidar las APIs.
 *
 * Uso en un handler:
 *   IF v_response_body IS NOT NULL THEN pkg_aox_http.pr_print_clob(v_response_body); END IF;
 */
    PROCEDURE pr_print_clob(pi_clob IN CLOB);
END pkg_aox_http;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_http
CREATE OR REPLACE PACKAGE BODY pkg_aox_http AS

    PROCEDURE pr_print_clob(pi_clob IN CLOB) IS
        -- 4000 caracteres son a lo sumo 16000 bytes en AL32UTF8: siempre entra en htp.prn.
        c_chunk  CONSTANT PLS_INTEGER := 4000;
        v_len    INTEGER;
        v_offset INTEGER := 1;
        v_amount INTEGER;
    BEGIN
        IF pi_clob IS NULL THEN
            RETURN;
        END IF;
        v_len := NVL(DBMS_LOB.getlength(pi_clob), 0);
        WHILE v_offset <= v_len LOOP
            v_amount := LEAST(c_chunk, v_len - v_offset + 1);
            htp.prn(DBMS_LOB.substr(pi_clob, v_amount, v_offset));
            v_offset := v_offset + v_amount;
        END LOOP;
    END pr_print_clob;

END pkg_aox_http;
/
