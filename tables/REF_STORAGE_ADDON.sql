PROMPT CREATE TABLE ref_storage_addon
CREATE TABLE ref_storage_addon (
  id_storage_addon NUMBER         NOT NULL,
  code             VARCHAR2(30)   NOT NULL,
  name             VARCHAR2(100)  NOT NULL,
  extra_bytes      NUMBER         NOT NULL,
  price_amount     NUMBER         DEFAULT 0 NOT NULL,
  currency         VARCHAR2(3)    DEFAULT 'PYG' NOT NULL,
  billing_period   VARCHAR2(10)   DEFAULT 'MONTHLY' NOT NULL,
  is_active        NUMBER(1,0)    DEFAULT 1 NOT NULL,
  sort_order       NUMBER         DEFAULT 0 NOT NULL
)
/

PROMPT ALTER TABLE ref_storage_addon ADD CONSTRAINT pk_ref_storage_addon PRIMARY KEY
ALTER TABLE ref_storage_addon
  ADD CONSTRAINT pk_ref_storage_addon PRIMARY KEY (
    id_storage_addon
  )
/

PROMPT ALTER TABLE ref_storage_addon ADD CONSTRAINT uq_ref_storage_addon_code UNIQUE
ALTER TABLE ref_storage_addon
  ADD CONSTRAINT uq_ref_storage_addon_code UNIQUE (
    code
  )
/

PROMPT ALTER TABLE ref_storage_addon ADD CONSTRAINT chk_ref_sad_active CHECK
ALTER TABLE ref_storage_addon
  ADD CONSTRAINT chk_ref_sad_active CHECK (
    is_active IN (0, 1)
  )
/

COMMENT ON TABLE ref_storage_addon IS 'Catalogo de paquetes de storage adicional (ej. +5 GB, +15 GB) para planes que lo permiten.';
COMMENT ON COLUMN ref_storage_addon.extra_bytes IS 'Bytes adicionales que aporta el addon al storage_limit de la organizacion.';
