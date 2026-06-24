-- PRD-056 Phase 1 - new pack outcome `packed_transferred`.
-- pack_outcome is the enum `pack_outcome_enum` (labels: packed, partial, not_filled), NOT a CHECK.
-- Forward-only additive ADD VALUE (Article 12). Idempotent. Must commit before any code uses the label
-- (Postgres forbids using a freshly added enum value in the same transaction that adds it).
ALTER TYPE public.pack_outcome_enum ADD VALUE IF NOT EXISTS 'packed_transferred';
