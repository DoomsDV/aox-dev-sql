PROMPT CREATE TABLE org_public_directory
-- Proyeccion publica SIN VPD. Solo columnas para resolver slug -> org_id
-- y flags de publicacion. No poner politicas VPD en esta tabla.
CREATE TABLE org_public_directory (
  org_id_organization    NUMBER         NOT NULL,
  profile_slug           VARCHAR2(100)  NOT NULL,
  is_listed              NUMBER(1)      DEFAULT 1 NOT NULL,
  is_unpublished         NUMBER(1)      DEFAULT 0 NOT NULL,
  blocks_public_booking  NUMBER(1)      DEFAULT 0 NOT NULL,
  updated_at             TIMESTAMP(6)   DEFAULT CURRENT_TIMESTAMP NOT NULL
)
  INITRANS  10
  STORAGE (
    NEXT       1024 K
  )
/

PROMPT ALTER TABLE org_public_directory ADD CONSTRAINT pk_org_public_directory PRIMARY KEY
ALTER TABLE org_public_directory
  ADD CONSTRAINT pk_org_public_directory PRIMARY KEY (
    org_id_organization
  )
  USING INDEX
    INITRANS  20
    STORAGE (
      NEXT       1024 K
    )
/

PROMPT ALTER TABLE org_public_directory ADD CONSTRAINT uq_org_public_dir_slug UNIQUE
ALTER TABLE org_public_directory
  ADD CONSTRAINT uq_org_public_dir_slug UNIQUE (
    profile_slug
  )
  USING INDEX
    INITRANS  20
    STORAGE (
      NEXT       1024 K
    )
/

PROMPT ALTER TABLE org_public_directory ADD CONSTRAINT fk_org_public_dir_org FOREIGN KEY
ALTER TABLE org_public_directory
  ADD CONSTRAINT fk_org_public_dir_org FOREIGN KEY (
    org_id_organization
  ) REFERENCES organization (
    id_organization
  ) ON DELETE CASCADE
/

PROMPT ALTER TABLE org_public_directory ADD CONSTRAINT chk_org_public_dir_listed CHECK
ALTER TABLE org_public_directory
  ADD CONSTRAINT chk_org_public_dir_listed CHECK (
    is_listed IN (0, 1)
  )
/

PROMPT ALTER TABLE org_public_directory ADD CONSTRAINT chk_org_public_dir_unpub CHECK
ALTER TABLE org_public_directory
  ADD CONSTRAINT chk_org_public_dir_unpub CHECK (
    is_unpublished IN (0, 1)
  )
/

PROMPT ALTER TABLE org_public_directory ADD CONSTRAINT chk_org_public_dir_blocks CHECK
ALTER TABLE org_public_directory
  ADD CONSTRAINT chk_org_public_dir_blocks CHECK (
    blocks_public_booking IN (0, 1)
  )
/

COMMENT ON TABLE org_public_directory IS
  'Proyeccion publica sin VPD: profile_slug -> org_id + flags de publicacion. Huevo/gallina de set_org.';
/

COMMENT ON COLUMN org_public_directory.profile_slug IS
  'Slug publico ya normalizado (lower/trim). Identidad para /:org_slug.';
/

COMMENT ON COLUMN org_public_directory.is_listed IS
  '1 si el slug es publico valido (no reservado). Las filas existentes suelen ser 1.';
/

COMMENT ON COLUMN org_public_directory.is_unpublished IS
  '1 si enforcement PUBLIC_UNPUBLISHED u OPERATIONS_SUSPENDED.';
/

COMMENT ON COLUMN org_public_directory.blocks_public_booking IS
  '1 si enforcement bloquea reserva publica (PUBLIC_BOOKINGS o superior).';
/
