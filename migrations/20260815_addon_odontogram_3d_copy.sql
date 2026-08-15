-- Copy de catálogo: el editor 3D ya es el odontograma clínico.

UPDATE ref_addon
   SET short_description = 'Ficha clinica interactiva 3D y evolucion de tratamientos.'
 WHERE code = 'ODONTOGRAM_3D';

COMMIT;

PROMPT OK: odontogram 3D addon copy
