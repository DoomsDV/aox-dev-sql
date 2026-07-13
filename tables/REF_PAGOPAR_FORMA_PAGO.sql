PROMPT CREATE TABLE ref_pagopar_forma_pago
CREATE TABLE ref_pagopar_forma_pago (
  id_forma_pago  NUMBER         NOT NULL,
  code           VARCHAR2(30)   NOT NULL,
  title          VARCHAR2(100)  NOT NULL,
  is_enabled_web NUMBER(1,0)    DEFAULT 1 NOT NULL,
  sort_order     NUMBER         DEFAULT 0 NOT NULL
)
/

PROMPT ALTER TABLE ref_pagopar_forma_pago ADD CONSTRAINT pk_ref_pagopar_forma_pago PRIMARY KEY
ALTER TABLE ref_pagopar_forma_pago
  ADD CONSTRAINT pk_ref_pagopar_forma_pago PRIMARY KEY (
    id_forma_pago
  )
/

PROMPT ALTER TABLE ref_pagopar_forma_pago ADD CONSTRAINT uq_ref_pfp_code UNIQUE
ALTER TABLE ref_pagopar_forma_pago
  ADD CONSTRAINT uq_ref_pfp_code UNIQUE (
    code
  )
/

PROMPT ALTER TABLE ref_pagopar_forma_pago ADD CONSTRAINT chk_ref_pfp_enabled CHECK
ALTER TABLE ref_pagopar_forma_pago
  ADD CONSTRAINT chk_ref_pfp_enabled CHECK (
    is_enabled_web IN (0, 1)
  )
/
