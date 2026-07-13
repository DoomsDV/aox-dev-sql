PROMPT CREATE TABLE aox_fcm_log
CREATE TABLE aox_fcm_log (
  id_log        NUMBER         GENERATED ALWAYS AS IDENTITY,
  log_date      TIMESTAMP(6)   DEFAULT CURRENT_TIMESTAMP NULL,
  fcm_token     VARCHAR2(4000) NULL,
  status_code   NUMBER         NULL,
  response_body CLOB           NULL,
  error_msg     VARCHAR2(4000) NULL
)
  INITRANS  10
  STORAGE (
    NEXT       1024 K
  )
/


