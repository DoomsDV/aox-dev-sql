PROMPT CREATE TABLE org_public_token
-- Indice publico SIN VPD: token_hash -> org_id (+ cita). No poner politicas VPD.
CREATE TABLE org_public_token (
  token_hash          RAW(32)       NOT NULL,
  org_id_organization NUMBER        NOT NULL,
  app_id_appointment  NUMBER        NULL,
  token_kind          VARCHAR2(30)  DEFAULT 'APPOINTMENT_MANAGE' NOT NULL,
  created_at          TIMESTAMP(6)  DEFAULT CURRENT_TIMESTAMP NOT NULL,
  updated_at          TIMESTAMP(6)  DEFAULT CURRENT_TIMESTAMP NOT NULL
)
  INITRANS  10
  STORAGE (
    NEXT       1024 K
  )
/

PROMPT ALTER TABLE org_public_token ADD CONSTRAINT pk_org_public_token PRIMARY KEY
ALTER TABLE org_public_token
  ADD CONSTRAINT pk_org_public_token PRIMARY KEY (
    token_hash
  )
  USING INDEX
    INITRANS  20
    STORAGE (
      NEXT       1024 K
    )
/

PROMPT CREATE INDEX idx_org_pub_tok_org
CREATE INDEX idx_org_pub_tok_org
  ON org_public_token (
    org_id_organization
  )
  INITRANS  20
  STORAGE (
    NEXT       1024 K
  )
/

PROMPT CREATE UNIQUE INDEX uq_org_pub_tok_app_kind
CREATE UNIQUE INDEX uq_org_pub_tok_app_kind
  ON org_public_token (
    app_id_appointment,
    token_kind
  )
  INITRANS  20
  STORAGE (
    NEXT       1024 K
  )
/

PROMPT ALTER TABLE org_public_token ADD CONSTRAINT fk_org_pub_tok_org FOREIGN KEY
ALTER TABLE org_public_token
  ADD CONSTRAINT fk_org_pub_tok_org FOREIGN KEY (
    org_id_organization
  ) REFERENCES organization (
    id_organization
  ) ON DELETE CASCADE
/

PROMPT ALTER TABLE org_public_token ADD CONSTRAINT fk_org_pub_tok_app FOREIGN KEY
ALTER TABLE org_public_token
  ADD CONSTRAINT fk_org_pub_tok_app FOREIGN KEY (
    app_id_appointment
  ) REFERENCES appointment (
    id_appointment
  ) ON DELETE CASCADE
/

PROMPT ALTER TABLE org_public_token ADD CONSTRAINT chk_org_pub_tok_kind CHECK
ALTER TABLE org_public_token
  ADD CONSTRAINT chk_org_pub_tok_kind CHECK (
    token_kind IN ('APPOINTMENT_MANAGE')
  )
/

COMMENT ON TABLE org_public_token IS
  'Lookup publico sin VPD: SHA-256(token) -> org_id. El plaintext vive en appointment (con VPD).';
/

COMMENT ON COLUMN org_public_token.token_hash IS
  'STANDARD_HASH(lower(trim(token)), SHA256). Nunca guardar el token en claro aqui.';
/

COMMENT ON COLUMN org_public_token.token_kind IS
  'APPOINTMENT_MANAGE = public_manage_token de /r/:hash.';
/
