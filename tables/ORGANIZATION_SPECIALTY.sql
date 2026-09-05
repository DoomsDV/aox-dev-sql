PROMPT CREATE TABLE organization_specialty
CREATE TABLE organization_specialty (
  org_id_organization    NUMBER NOT NULL,
  osp_id_org_specialty   NUMBER NOT NULL,
  created_at             TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL
)
/

PROMPT ALTER TABLE organization_specialty ADD CONSTRAINT pk_organization_specialty PRIMARY KEY
ALTER TABLE organization_specialty
  ADD CONSTRAINT pk_organization_specialty PRIMARY KEY (
    org_id_organization,
    osp_id_org_specialty
  )
/

PROMPT ALTER TABLE organization_specialty ADD CONSTRAINT fk_orgspec_org FOREIGN KEY
ALTER TABLE organization_specialty
  ADD CONSTRAINT fk_orgspec_org FOREIGN KEY (
    org_id_organization
  ) REFERENCES organization (
    id_organization
  ) ON DELETE CASCADE
/

PROMPT ALTER TABLE organization_specialty ADD CONSTRAINT fk_orgspec_specialty FOREIGN KEY
ALTER TABLE organization_specialty
  ADD CONSTRAINT fk_orgspec_specialty FOREIGN KEY (
    osp_id_org_specialty
  ) REFERENCES org_specialty (
    id_org_specialty
  ) ON DELETE CASCADE
/

PROMPT CREATE INDEX idx_orgspec_specialty ON organization_specialty (osp_id_org_specialty)
CREATE INDEX idx_orgspec_specialty
  ON organization_specialty (
    osp_id_org_specialty
  )
/

COMMENT ON TABLE organization_specialty IS 'Rubros comerciales de una org (M:N). organization.org_spe_id_specialty = rubro principal denormalizado.';
COMMENT ON COLUMN organization_specialty.org_id_organization IS 'FK a organization.id_organization.';
COMMENT ON COLUMN organization_specialty.osp_id_org_specialty IS 'FK a org_specialty.id_org_specialty.';
