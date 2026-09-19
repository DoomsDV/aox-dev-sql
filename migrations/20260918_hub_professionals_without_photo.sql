-- HAS-112: el hub lista profesionales activos con o sin foto/bio.
-- Filtro restante en pr_get_org_hub: is_active=1, profile_slug no vacio,
-- org no unpublished. Foto y bio no son gate de visibilidad.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260918_hub_professionals_without_photo ===

COMMENT ON COLUMN professional.short_bio IS
    'Bio corta opcional (1-2 lineas) para el hub publico. Foto y bio no son gate de visibilidad.';

@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls

PROMPT === HAS-112 hub sin gate de foto/bio ===
