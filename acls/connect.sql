DECLARE
  c_principal CONSTANT VARCHAR2(128) := 'AOXDEV';

  PROCEDURE grant_connect(p_host VARCHAR2) IS
  BEGIN
    DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
      host       => p_host,
      lower_port => 443,
      upper_port => 443,
      ace        => xs$ace_type(
                      privilege_list => xs$name_list('connect'),
                      principal_name => c_principal,
                      principal_type => xs_acl.ptype_db
                    )
    );
  END grant_connect;

BEGIN
  grant_connect('fcm.googleapis.com');                    -- FCM (PKG_AOX_FCM_API)
  grant_connect('generativelanguage.googleapis.com');     -- Gemini / DBMS_CLOUD_AI
  grant_connect('hasel-openai-api.openai.azure.com');     -- Azure OpenAI (PKG_AOX_IA_MANAGER)
  grant_connect('graph.facebook.com');                    -- Meta WhatsApp API

  -- Solo si tu parámetro OCI_BUCKET_BASE_URL apunta a un host concreto, p. ej.:
  -- grant_connect('objectstorage.sa-saopaulo-1.oraclecloud.com');

  -- Solo si "hasel" es un host real en tu red
  -- grant_connect('hasel');

  COMMIT;
END;
/