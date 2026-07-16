-- DEV/staging: return URL del iframe uPay (catastro) debe coincidir con el dominio
-- donde se incrusta el form. En PROD dejar https://hasel.app/panel/plan.
-- Ejecutar solo en aoxdev.

PROMPT === PAGOPAR_UPAY_RETURN_URL -> staging.hasel.app ===

MERGE INTO app_parameter t
USING (
  SELECT 'PAGOPAR_UPAY_RETURN_URL' AS param_key,
         'https://staging.hasel.app/panel/plan' AS param_value,
         'URL HTTPS donde se incrusta el iframe uPay y a la que Pagopar redirige (DEV).' AS description
  FROM dual
) s
ON (t.param_key = s.param_key)
WHEN MATCHED THEN
  UPDATE SET t.param_value = s.param_value
WHEN NOT MATCHED THEN
  INSERT (param_key, param_value, description)
  VALUES (s.param_key, s.param_value, s.description);

COMMIT;

PROMPT OK: PAGOPAR_UPAY_RETURN_URL = https://staging.hasel.app/panel/plan
