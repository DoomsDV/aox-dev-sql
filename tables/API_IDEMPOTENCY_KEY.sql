PROMPT CREATE TABLE api_idempotency_key
CREATE TABLE api_idempotency_key (
  scope_code            VARCHAR2(64)  NOT NULL,
  idem_key              VARCHAR2(255) NOT NULL,
  request_hash          VARCHAR2(64)  NOT NULL,
  status                VARCHAR2(20)  DEFAULT 'IN_PROGRESS' NOT NULL,
  response_status_code  NUMBER,
  response_payload      CLOB,
  created_at            TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
  completed_at          TIMESTAMP WITH TIME ZONE,
  expires_at            TIMESTAMP WITH TIME ZONE NOT NULL,
  CONSTRAINT pk_api_idempotency_key PRIMARY KEY (scope_code, idem_key),
  CONSTRAINT ck_api_idempotency_status CHECK (status IN ('IN_PROGRESS', 'COMPLETED'))
)
/

PROMPT CREATE INDEX ix_api_idempotency_expires
CREATE INDEX ix_api_idempotency_expires
  ON api_idempotency_key (expires_at)
/

COMMENT ON TABLE api_idempotency_key IS
  'Framework generico de Idempotency-Key (estilo Stripe): dedupe de reintentos de operaciones mutantes (cobros, reservas, uploads) por scope+key. status=IN_PROGRESS mientras se procesa; COMPLETED guarda response_status_code/response_payload para replay exacto en reintentos.';
