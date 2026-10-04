-- ============================================================================
-- Super Seller 360 — Add source tracking for automation vs manual entry
--
-- Direct response to a real product gap: Returns and RTOs had zero
-- automated ingestion — every single one was manual-entry-only, despite
-- marketplaces and couriers providing APIs/webhooks for exactly this data
-- in reality. Adding a `source` column so the UI can clearly distinguish
-- automated (webhook) entries from manual fallback entries.
-- ============================================================================
alter table returns add column source text not null default 'manual' check (source in ('manual', 'webhook'));
alter table rtos add column source text not null default 'manual' check (source in ('manual', 'webhook'));
