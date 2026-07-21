-- Migracion: galeria sin tope de 30 imagenes
-- Relaja chk_orggal_sort: sort_order >= 1 (sin upper bound)

PROMPT === Drop chk_orggal_sort (BETWEEN 1 AND 30) ===
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_gallery_image DROP CONSTRAINT chk_orggal_sort';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -2443 THEN NULL; ELSE RAISE; END IF; -- ORA-02443: cannot drop constraint - nonexistent
END;
/

PROMPT === Add chk_orggal_sort (sort_order >= 1) ===
ALTER TABLE org_gallery_image
  ADD CONSTRAINT chk_orggal_sort CHECK (
    sort_order >= 1
  )
/
