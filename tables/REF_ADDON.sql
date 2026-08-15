PROMPT CREATE TABLE ref_addon
CREATE TABLE ref_addon (
  id_addon           NUMBER         NOT NULL,
  code               VARCHAR2(30)   NOT NULL,
  name               VARCHAR2(100)  NOT NULL,
  short_description  VARCHAR2(400)  NULL,
  feature_code       VARCHAR2(50)   NOT NULL,
  price_amount       NUMBER         DEFAULT 0 NOT NULL,
  currency           VARCHAR2(3)    DEFAULT 'PYG' NOT NULL,
  billing_period     VARCHAR2(10)   DEFAULT 'MONTHLY' NOT NULL,
  is_active          NUMBER(1,0)    DEFAULT 1 NOT NULL,
  sort_order         NUMBER         DEFAULT 0 NOT NULL,
  audience_code      VARCHAR2(30)   NULL
)
/

PROMPT ALTER TABLE ref_addon ADD CONSTRAINT pk_ref_addon PRIMARY KEY
ALTER TABLE ref_addon
  ADD CONSTRAINT pk_ref_addon PRIMARY KEY (
    id_addon
  )
/

PROMPT ALTER TABLE ref_addon ADD CONSTRAINT uq_ref_addon_code UNIQUE
ALTER TABLE ref_addon
  ADD CONSTRAINT uq_ref_addon_code UNIQUE (
    code
  )
/

PROMPT ALTER TABLE ref_addon ADD CONSTRAINT uq_ref_addon_feature UNIQUE
ALTER TABLE ref_addon
  ADD CONSTRAINT uq_ref_addon_feature UNIQUE (
    feature_code
  )
/

PROMPT ALTER TABLE ref_addon ADD CONSTRAINT chk_ref_addon_active CHECK
ALTER TABLE ref_addon
  ADD CONSTRAINT chk_ref_addon_active CHECK (
    is_active IN (0, 1)
  )
/

PROMPT ALTER TABLE ref_addon ADD CONSTRAINT chk_ref_addon_period CHECK
ALTER TABLE ref_addon
  ADD CONSTRAINT chk_ref_addon_period CHECK (
    billing_period IN ('MONTHLY', 'YEARLY')
  )
/

COMMENT ON TABLE ref_addon IS 'Catalogo de complementos mensuales (modulos, no storage). Precio de lista; el cobro Pagopar se habilita con ADDONS_BILLING_LIVE.';
COMMENT ON COLUMN ref_addon.feature_code IS 'Codigo de entitlement org-level (ej. ODONTOGRAM_3D). Nunca va en ref_plan_feature.';
COMMENT ON COLUMN ref_addon.audience_code IS 'Filtro de visibilidad: NULL=todas las orgs; DENTAL=org_specialty.code DENTAL.';
COMMENT ON COLUMN ref_addon.price_amount IS 'Precio mensual de lista en currency. En preview no se cobra.';
