PROMPT CREATE TABLE ref_body_region
CREATE TABLE ref_body_region (
  region_code   VARCHAR2(40)  NOT NULL,
  view_code     VARCHAR2(10)  NOT NULL,
  label         VARCHAR2(100) NOT NULL,
  sort_order    NUMBER        DEFAULT 0 NOT NULL,
  is_active     NUMBER(1,0)   DEFAULT 1 NOT NULL
)
/

PROMPT ALTER TABLE ref_body_region ADD CONSTRAINT pk_ref_body_region PRIMARY KEY
ALTER TABLE ref_body_region
  ADD CONSTRAINT pk_ref_body_region PRIMARY KEY (
    region_code
  )
/

PROMPT ALTER TABLE ref_body_region ADD CONSTRAINT chk_ref_body_region_view CHECK
ALTER TABLE ref_body_region
  ADD CONSTRAINT chk_ref_body_region_view CHECK (
    view_code IN ('FRONT', 'BACK', 'SIDE')
  )
/

PROMPT ALTER TABLE ref_body_region ADD CONSTRAINT chk_ref_body_region_active CHECK
ALTER TABLE ref_body_region
  ADD CONSTRAINT chk_ref_body_region_active CHECK (
    is_active IN (0, 1)
  )
/

COMMENT ON TABLE ref_body_region IS 'Catálogo allowlist de regiones corporales para mapa Cuerpo (sin columna/cara/uñas).';
COMMENT ON COLUMN ref_body_region.region_code IS 'Código estable (ej. FRONT_SHOULDER_L).';
