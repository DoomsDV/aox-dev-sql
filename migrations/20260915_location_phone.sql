-- HAS-26: telefono opcional de sucursal (visible en el hub publico).
-- no va a prod hasta el pase conjunto con bookmate (busqueda + hub).

ALTER TABLE location ADD phone VARCHAR2(40);

COMMENT ON COLUMN location.phone IS
  'Telefono opcional de la sucursal. Visible en el hub publico para llamar a esta sucursal.';
