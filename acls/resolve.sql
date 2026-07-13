-- Ejecutar como ADMIN (o usuario con permiso para gestionar ACLs de red)
-- Sustituir WKSP_AOX por tu esquema de aplicación

DECLARE
  c_principal CONSTANT VARCHAR2(128) := 'AOXDEV';

  PROCEDURE grant_resolve(p_host VARCHAR2) IS
  BEGIN
    DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
      host => p_host,
      ace  => xs$ace_type(
                privilege_list => xs$name_list('resolve'),
                principal_name => c_principal,
                principal_type => xs_acl.ptype_db
              )
    );
  END grant_resolve;

BEGIN
  -- Opcional: resolve amplio (aparece como host '*' en tu captura)
  --grant_resolve('*');

  grant_resolve('fcm.googleapis.com');
  grant_resolve('generativelanguage.googleapis.com');
  grant_resolve('hasel-openai-api.openai.azure.com');

  -- Si realmente usas el host corto "hasel" (poco habitual para HTTPS público)
  grant_resolve('hasel');

  -- Recomendado para AOX: WhatsApp/Meta (usado en PKG_AOX_META_API)
  grant_resolve('graph.facebook.com');

  COMMIT;
END;
/