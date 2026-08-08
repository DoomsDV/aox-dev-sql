-- Contabilizar logo, banner, galeria, foto de profesional y portada de servicio
-- en org_subscription.storage_used_bytes (antes solo appointment_attachment).

ALTER SESSION DISABLE PARALLEL DML;

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE workspace_setting ADD (logo_size_bytes NUMBER DEFAULT 0 NOT NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE workspace_setting ADD (banner_size_bytes NUMBER DEFAULT 0 NOT NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE org_gallery_image ADD (size_bytes NUMBER DEFAULT 0 NOT NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE professional ADD (profile_image_size_bytes NUMBER DEFAULT 0 NOT NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE service ADD (image_size_bytes NUMBER DEFAULT 0 NOT NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

COMMENT ON COLUMN workspace_setting.logo_size_bytes IS 'Tamano del logo en bytes; suma a storage_used_bytes de la org.';
COMMENT ON COLUMN workspace_setting.banner_size_bytes IS 'Tamano del banner en bytes; suma a storage_used_bytes de la org.';
COMMENT ON COLUMN org_gallery_image.size_bytes IS 'Tamano de la imagen de galeria en bytes; suma a storage_used_bytes de la org.';
COMMENT ON COLUMN professional.profile_image_size_bytes IS 'Tamano de la foto de perfil en bytes; suma a storage_used_bytes de la org.';
COMMENT ON COLUMN service.image_size_bytes IS 'Tamano de la portada del servicio en bytes; suma a storage_used_bytes de la org.';
COMMENT ON COLUMN org_subscription.storage_used_bytes IS 'Bytes ocupados por assets de la org (logo, banner, galeria, fotos de profesionales/servicios y adjuntos de citas).';

COMMIT;
