-- Stand-by del complemento Cuerpo (BODY_MAP).
-- Kill-switch de catálogo: ref_addon.is_active.
-- No borra org_addon ni snapshots; al reactivar (is_active=1) vuelven los grants.

PROMPT === Stand-by complemento BODY_MAP ===
UPDATE ref_addon
   SET is_active = 0
 WHERE code = 'BODY_MAP';

COMMIT;

PROMPT OK: BODY_MAP is_active=0 (stand-by)
