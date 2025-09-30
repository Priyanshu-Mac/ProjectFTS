-- Migration: add password_hash to users table (idempotent)
BEGIN;

ALTER TABLE IF EXISTS public.users
  ADD COLUMN IF NOT EXISTS password_hash text;

-- Add an email column for user contact / lookups (idempotent)
ALTER TABLE IF EXISTS public.users
  ADD COLUMN IF NOT EXISTS email text;

-- Optional: create an index for lookups
CREATE INDEX IF NOT EXISTS idx_users_username ON public.users USING btree (username);
-- Optional: index on email to speed lookups (non-unique to avoid migration failure if duplicates exist)
CREATE INDEX IF NOT EXISTS idx_users_email ON public.users USING btree (email);

COMMIT;
