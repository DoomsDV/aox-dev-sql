PROMPT CREATE TABLE ref_sipap_bank
CREATE TABLE ref_sipap_bank (
  id_bank    NUMBER         NOT NULL,
  code       VARCHAR2(30)   NOT NULL,
  name       VARCHAR2(120)  NOT NULL,
  is_active  NUMBER(1,0)    DEFAULT 1 NOT NULL,
  sort_order NUMBER         DEFAULT 0 NOT NULL
)
/

PROMPT ALTER TABLE ref_sipap_bank ADD CONSTRAINT pk_ref_sipap_bank PRIMARY KEY
ALTER TABLE ref_sipap_bank
  ADD CONSTRAINT pk_ref_sipap_bank PRIMARY KEY (
    id_bank
  )
/

PROMPT ALTER TABLE ref_sipap_bank ADD CONSTRAINT uq_ref_sipap_bank_code UNIQUE
ALTER TABLE ref_sipap_bank
  ADD CONSTRAINT uq_ref_sipap_bank_code UNIQUE (
    code
  )
/

PROMPT ALTER TABLE ref_sipap_bank ADD CONSTRAINT chk_ref_sipap_bank_active CHECK
ALTER TABLE ref_sipap_bank
  ADD CONSTRAINT chk_ref_sipap_bank_active CHECK (
    is_active IN (0, 1)
  )
/

COMMENT ON TABLE ref_sipap_bank IS
  'Catalogo de bancos y financieras de Paraguay para cobro de senas SIPAP.';
/

COMMENT ON COLUMN ref_sipap_bank.code IS
  'Codigo estable interno (CONTINENTAL, ITAU, UENO, ...).';
/

COMMENT ON COLUMN ref_sipap_bank.name IS
  'Nombre visible en Ajustes y reserva publica.';
/
