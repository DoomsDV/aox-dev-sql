PROMPT CREATE TABLE ref_plan
CREATE TABLE ref_plan (
  id_plan             NUMBER         NOT NULL,
  code                VARCHAR2(30)   NOT NULL,
  name                VARCHAR2(100)  NOT NULL,
  price_amount        NUMBER         DEFAULT 0 NOT NULL,
  currency            VARCHAR2(3)    DEFAULT 'PYG' NOT NULL,
  billing_period      VARCHAR2(10)   DEFAULT 'MONTHLY' NOT NULL,
  storage_limit_bytes NUMBER         DEFAULT 0 NOT NULL,
  is_active           NUMBER(1,0)    DEFAULT 1 NOT NULL,
  sort_order          NUMBER         DEFAULT 0 NOT NULL
)
/

PROMPT ALTER TABLE ref_plan ADD CONSTRAINT pk_ref_plan PRIMARY KEY
ALTER TABLE ref_plan
  ADD CONSTRAINT pk_ref_plan PRIMARY KEY (
    id_plan
  )
/

PROMPT ALTER TABLE ref_plan ADD CONSTRAINT uq_ref_plan_code UNIQUE
ALTER TABLE ref_plan
  ADD CONSTRAINT uq_ref_plan_code UNIQUE (
    code
  )
/

PROMPT ALTER TABLE ref_plan ADD CONSTRAINT chk_ref_plan_active CHECK
ALTER TABLE ref_plan
  ADD CONSTRAINT chk_ref_plan_active CHECK (
    is_active IN (0, 1)
  )
/

PROMPT ALTER TABLE ref_plan ADD CONSTRAINT chk_ref_plan_period CHECK
ALTER TABLE ref_plan
  ADD CONSTRAINT chk_ref_plan_period CHECK (
    billing_period IN ('MONTHLY', 'YEARLY')
  )
/

COMMENT ON TABLE ref_plan IS 'Catalogo de planes (BASE, PREMIUM, FREE/Continuidad). FREE no se ofrece en checkout; es destino de Terminar suscripcion.';
COMMENT ON COLUMN ref_plan.storage_limit_bytes IS 'Storage base incluido en el plan (sin addons). Base/FREE=0, Premium=5GB.';
