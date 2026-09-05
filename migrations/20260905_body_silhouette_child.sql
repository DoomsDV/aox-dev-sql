-- Ampliar silueta corporal con variante infantil (CHILD).
BEGIN
  EXECUTE IMMEDIATE q'[
    ALTER TABLE customer_body_snapshot DROP CONSTRAINT chk_body_snap_silhouette
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-2443) THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE q'[
    ALTER TABLE customer_body_snapshot ADD CONSTRAINT chk_body_snap_silhouette
      CHECK (silhouette IN ('NEUTRAL', 'FEMALE', 'MALE', 'CHILD'))
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-2260, -2261, -2264) THEN RAISE; END IF;
END;
/

COMMIT;
