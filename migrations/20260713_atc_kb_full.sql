-- Combined ATC KB migration: tables + packages + ORDS.
-- Prefer applying individual files; this documents the deploy order.

PROMPT === ATC KB tables ===
@@20260713_atc_kb_tables.sql

PROMPT === Packages (apply from repo root packages/) ===
-- @@../packages/PKG_AOX_BUCKET.pls
-- @@../packages/PKG_AOX_ATC_KB.pls
-- @@../packages/PKG_AOX_ATC_CHAT.pls
-- @@../packages/PKG_AOX_ATC_CHAT_API.pls

PROMPT === ORDS ===
@@20260713_atc_ords.sql
