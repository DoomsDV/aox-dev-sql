# ATC KB — carga y edición de documentos desde APEX

Base de conocimiento **global** de Atención al Cliente (Hasel). Los archivos viven en OCI Object Storage; en Oracle queda metadata + chunks/embeddings.

## Flujo de carga

1. Formulario APEX (File Browse) permite PDF / DOCX / TXT / MD.
2. Process PL/SQL llama a `PKG_AOX_ATC_KB.pr_ingest_document`.
3. El paquete:
   - inserta `ATC_KB_DOCUMENT` (`PENDING`)
   - sube al bucket vía `PKG_AOX_BUCKET.pr_upload_atc_kb_document` → path `platform/atc-kb/{id}/{filename}`
   - extrae texto, genera chunks y embeddings (Azure `text-embedding-3-small`, 1536-d)
   - deja el documento en `READY` o `ERROR`

## API para el process de carga

```sql
DECLARE
    l_blob   BLOB;
    l_name   VARCHAR2(255);
    l_mime   VARCHAR2(150);
    l_doc_id NUMBER;
BEGIN
    SELECT blob_content, filename, mime_type
      INTO l_blob, l_name, l_mime
      FROM apex_application_temp_files
     WHERE name = :PXX_FILE; -- item File Browse

    pkg_aox_atc_kb.pr_ingest_document(
        pi_filename    => l_name,
        pi_mime_type   => l_mime,
        pi_blob        => l_blob,
        po_document_id => l_doc_id
    );
END;
```

## Editar contenido (Textarea APEX)

No se edita el PDF/DOCX binario. Se edita `EXTRACTED_TEXT` (lo que usa la IA).

Al guardar, `pr_set_text_and_process`:

1. Actualiza `EXTRACTED_TEXT`
2. Regenera chunks/embeddings
3. **Sincroniza el bucket:** borra el objeto anterior y sube el texto editado como `.txt` UTF-8 (`text/plain`), para que BD y OCI no queden desfasados

### Items sugeridos

| Item | Tipo | Uso |
|------|------|-----|
| `PXX_ID_DOCUMENT` | Hidden | PK |
| `PXX_FILE_NAME` | Display Only | Nombre actual |
| `PXX_EXTRACTED_TEXT` | Textarea / CLOB | Contenido editable |
| Botón Guardar | Process PL/SQL | Ver abajo |

Poblar el textarea desde `ATC_KB_DOCUMENT.EXTRACTED_TEXT` (Before Header / Form).

### Process Guardar

```sql
BEGIN
  pkg_aox_atc_kb.pr_set_text_and_process(
    pi_document_id => :PXX_ID_DOCUMENT,
    pi_text        => :PXX_EXTRACTED_TEXT
  );
END;
```

Confirmación sugerida: *Se actualizará el contenido, se regenerarán los embeddings y se sincronizará el archivo en el bucket. ¿Continuar?*

### Otras operaciones

| Acción | Llamada |
|--------|---------|
| Listar | `pkg_aox_atc_kb.fn_list_documents` → JSON array |
| Reprocesar desde bucket | `pkg_aox_atc_kb.pr_reprocess_document(pi_document_id)` |
| Editar texto + sync bucket | `pkg_aox_atc_kb.pr_set_text_and_process(id, texto)` |
| Borrar (BD + bucket) | `pkg_aox_atc_kb.pr_delete_document(pi_document_id)` |

## Extracción de texto (carga inicial)

| Tipo | Cómo |
|------|------|
| TXT / MD | conversión BLOB → CLOB |
| DOCX | `APEX_ZIP` → `word/document.xml` |
| PDF | Azure Document Intelligence (`AZURE_DI_ENDPOINT`, `AZURE_DI_API_KEY`, opcional `AZURE_DI_API_VERSION`) |

Si no hay DI configurado, usá `pr_set_text_and_process` con el texto pegado/extraído a mano (también deja el `.txt` en el bucket).

## Tablas

- `ATC_KB_DOCUMENT` — metadata + `storage_url` / `object_key` (sin BLOB persistente)
- `ATC_KB_CHUNK` — texto + `VECTOR(1536)`

## Consulta desde bookmate

`POST /ords/aoxdev/ai/atc/ask` → `PKG_AOX_ATC_CHAT_API.pr_ask` (JWT). Body: `{ "message": "..." }`.
