-- Copy de catálogo: beneficio de producto, sin jerga de fases internas.

UPDATE ref_addon
   SET short_description = 'Ficha clinica interactiva y evolucion de tratamientos. Pronto con soporte 3D avanzado.'
 WHERE code = 'ODONTOGRAM_3D';

COMMIT;

PROMPT OK: odontogram addon copy
