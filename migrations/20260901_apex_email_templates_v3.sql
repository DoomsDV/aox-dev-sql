PROMPT === Seed templates APEX email V3 (app_parameter) ===

MERGE INTO app_parameter t
USING (
    SELECT 'APEX_EMAIL_TEMPLATE_VERIFICATIONCODE' AS param_key,
           'VERIFICATIONCODEV3' AS param_value,
           'Static ID APEX: correo de verificación de registro (placeholders NOMBRE, CODIGO).' AS description
      FROM dual
    UNION ALL
    SELECT 'APEX_EMAIL_TEMPLATE_ACCEPTINVITE',
           'ACCEPTINVITEV3',
           'Static ID APEX: invitación a profesional (ORG_NAME, INVITE_URL, EXPIRES_AT).'
      FROM dual
    UNION ALL
    SELECT 'APEX_EMAIL_TEMPLATE_PWDRESET',
           'PWDRESETV3',
           'Static ID APEX: recuperación de contraseña (NOMBRE, TOKEN, BASE_URL).'
      FROM dual
    UNION ALL
    SELECT 'APEX_EMAIL_TEMPLATE_FACTURASUSCRIPCION',
           'FACTURASUSCRIPCIONV3',
           'Static ID APEX: factura electrónica de suscripción (NOMBRE, NUMERO_FACTURA, CDC, BASE_URL).'
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN MATCHED THEN
    UPDATE SET
        t.param_value = s.param_value,
        t.description = s.description
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);

COMMIT;

PROMPT Verificación:
SELECT param_key, param_value, description
  FROM app_parameter
 WHERE param_key LIKE 'APEX_EMAIL_TEMPLATE_%'
 ORDER BY param_key;
