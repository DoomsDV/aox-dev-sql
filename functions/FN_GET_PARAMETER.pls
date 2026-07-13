PROMPT CREATE OR REPLACE FUNCTION fn_get_parameter
CREATE OR REPLACE FUNCTION fn_get_parameter (
    pi_param_key IN VARCHAR2
) RETURN VARCHAR2 IS
    v_param_value app_parameter.param_value%TYPE;
BEGIN
    SELECT
      param_value
    INTO
      v_param_value
    FROM app_parameter
    WHERE param_key = pi_param_key;

    RETURN v_param_value;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        -- Si el parámetro no existe, devolvemos NULL en lugar de un error fatal
        RETURN NULL;
    WHEN OTHERS THEN
        -- Si pasa cualquier otra cosa rara
        RETURN NULL;
END fn_get_parameter;
/

