// Add a permanent public number without changing internal relationship keys.
export const accountSchema = `
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('remotescreen:account-number-migration', 0));
ALTER TABLE users ADD COLUMN IF NOT EXISTS account_id TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_account_id ON users(account_id);
CREATE OR REPLACE FUNCTION allocate_account_id() RETURNS TEXT AS $$
DECLARE candidate TEXT;
BEGIN
  -- Serialize allocations until the enclosing INSERT/UPDATE commits.
  PERFORM pg_advisory_xact_lock(hashtextextended('remotescreen:account-number-allocation', 0));
  FOR attempt IN 1..200 LOOP
    candidate := (100000 + floor(random() * 900000)::INTEGER)::TEXT;
    IF NOT EXISTS (SELECT 1 FROM users WHERE account_id = candidate) THEN
      RETURN candidate;
    END IF;
  END LOOP;
  RAISE EXCEPTION 'Account number allocation exhausted';
END;
$$ LANGUAGE plpgsql VOLATILE;
DO $$
DECLARE existing RECORD;
BEGIN
  FOR existing IN SELECT id FROM users WHERE account_id IS NULL LOOP
    UPDATE users SET account_id = allocate_account_id() WHERE id = existing.id;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'users'::regclass AND conname = 'users_account_id_format') THEN
    ALTER TABLE users ADD CONSTRAINT users_account_id_format CHECK (account_id ~ '^[1-9][0-9]{5}$');
  END IF;
END;
$$;
ALTER TABLE users ALTER COLUMN account_id SET DEFAULT allocate_account_id();
ALTER TABLE users ALTER COLUMN account_id SET NOT NULL;
COMMIT;
`;
