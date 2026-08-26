-- CORS: permitir subida directa de adjuntos desde astro local en 127.0.0.1
-- (pnpm run perf:serve / astro --host 127.0.0.1). localhost:4321 ya estaba.
-- El 413 de Vercel se evita en el frontend (POST directo a ORDS); este origen
-- habilita esa misma vía en desarrollo local.

DECLARE
    c_origins CONSTANT VARCHAR2(500) :=
        'https://hasel.app,https://staging.hasel.app,http://localhost:4321,http://127.0.0.1:4321';
BEGIN
    FOR r IN (
        SELECT name FROM user_ords_modules
         WHERE name IN ('hasel', 'public', 'ai', 'whatsapp', 'pagopar')
    ) LOOP
        ORDS.set_module_origins_allowed(
            p_module_name     => r.name,
            p_origins_allowed => c_origins
        );
    END LOOP;
    COMMIT;
END;
/
