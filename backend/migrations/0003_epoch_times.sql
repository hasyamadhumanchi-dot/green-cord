-- Align the time columns with what the system actually exchanges.
--
-- 0001 declared sixteen columns as timestamptz, which is the idiomatic Postgres
-- choice and the wrong one here. The server writes epoch seconds - nineteen
-- `time.time()` call sites - and the iOS models declare these fields as
-- `Double`:
--
--     struct InviteCode { var createdAt: Double; var expiresAt: Double; ... }
--
-- So epoch seconds are the contract between the app and the API, and the
-- database is the only part that disagreed. Changing the schema to match is
-- cheaper and less error-prone than converting at three boundaries, and it
-- keeps one representation of time across the whole system.
--
-- The cost is real and worth stating: these columns no longer carry timezone
-- information, and `select created_at from accounts` returns a number rather
-- than a readable date. Use `to_timestamp(created_at)` when reading by hand.
--
-- Apply after 0002:
--     psql "$DATABASE_URL" -f backend/migrations/0003_epoch_times.sql

BEGIN;

ALTER TABLE accounts
    ALTER COLUMN created_at DROP DEFAULT,
    ALTER COLUMN created_at TYPE double precision USING extract(epoch FROM created_at),
    ALTER COLUMN created_at SET DEFAULT extract(epoch FROM now()),
    ALTER COLUMN deleted_at TYPE double precision USING extract(epoch FROM deleted_at);

ALTER TABLE approvals
    ALTER COLUMN created_at DROP DEFAULT,
    ALTER COLUMN created_at TYPE double precision USING extract(epoch FROM created_at),
    ALTER COLUMN created_at SET DEFAULT extract(epoch FROM now());

ALTER TABLE audit_log
    ALTER COLUMN at DROP DEFAULT,
    ALTER COLUMN at TYPE double precision USING extract(epoch FROM at),
    ALTER COLUMN at SET DEFAULT extract(epoch FROM now());

ALTER TABLE checklist_state
    ALTER COLUMN updated_at DROP DEFAULT,
    ALTER COLUMN updated_at TYPE double precision USING extract(epoch FROM updated_at),
    ALTER COLUMN updated_at SET DEFAULT extract(epoch FROM now());

ALTER TABLE hour_entries
    ALTER COLUMN created_at DROP DEFAULT,
    ALTER COLUMN created_at TYPE double precision USING extract(epoch FROM created_at),
    ALTER COLUMN created_at SET DEFAULT extract(epoch FROM now()),
    ALTER COLUMN updated_at DROP DEFAULT,
    ALTER COLUMN updated_at TYPE double precision USING extract(epoch FROM updated_at),
    ALTER COLUMN updated_at SET DEFAULT extract(epoch FROM now()),
    ALTER COLUMN submitted_at TYPE double precision USING extract(epoch FROM submitted_at),
    ALTER COLUMN decided_at   TYPE double precision USING extract(epoch FROM decided_at);

ALTER TABLE invite_codes
    ALTER COLUMN created_at DROP DEFAULT,
    ALTER COLUMN created_at TYPE double precision USING extract(epoch FROM created_at),
    ALTER COLUMN created_at SET DEFAULT extract(epoch FROM now()),
    ALTER COLUMN expires_at  TYPE double precision USING extract(epoch FROM expires_at),
    ALTER COLUMN revoked_at  TYPE double precision USING extract(epoch FROM revoked_at),
    ALTER COLUMN redeemed_at TYPE double precision USING extract(epoch FROM redeemed_at);

ALTER TABLE password_resets
    ALTER COLUMN created_at DROP DEFAULT,
    ALTER COLUMN created_at TYPE double precision USING extract(epoch FROM created_at),
    ALTER COLUMN created_at SET DEFAULT extract(epoch FROM now()),
    ALTER COLUMN expires_at TYPE double precision USING extract(epoch FROM expires_at),
    ALTER COLUMN used_at    TYPE double precision USING extract(epoch FROM used_at);

-- redeem_invite_code compared expires_at against now(). Both sides are epoch
-- seconds now, and the account id is generated here rather than taken from a
-- JWT, exactly as 0002 established.
CREATE OR REPLACE FUNCTION redeem_invite_code(
    p_code text, p_username text, p_password_hash text, p_password_salt text
) RETURNS accounts AS $$
DECLARE
    v_code invite_codes%ROWTYPE;
    v_account accounts%ROWTYPE;
    v_id uuid := gen_random_uuid();
BEGIN
    UPDATE invite_codes
       SET redeemed_by = v_id, redeemed_at = extract(epoch FROM now())
     WHERE code = upper(p_code)
       AND redeemed_by IS NULL
       AND revoked_at IS NULL
       AND expires_at > extract(epoch FROM now())
    RETURNING * INTO v_code;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'invite code is not valid' USING ERRCODE = '22023';
    END IF;

    INSERT INTO accounts (id, role, display_name, last_name, grade,
                          username, password_hash, password_salt)
    VALUES (v_id, v_code.role,
            v_code.first_name || ' ' || v_code.last_name,
            v_code.last_name, v_code.grade,
            p_username, p_password_hash, p_password_salt)
    RETURNING * INTO v_account;

    RETURN v_account;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;

-- The columns were converted above, but two functions still assigned a
-- timestamptz into them. `entries_transition_guard()` sets updated_at on every
-- hour_entries UPDATE, so this surfaced as a 500 on submitting an entry.
--
-- `delete_my_account()` is 0001's Supabase-era deletion path and is unused by
-- the server, which anonymises accounts itself in `delete_me`. It is corrected
-- here rather than left as a trap.

BEGIN;

CREATE OR REPLACE FUNCTION entries_transition_guard() RETURNS trigger AS $$
BEGIN
    IF NEW.status <> OLD.status THEN
        IF NOT is_staff() THEN
            IF NOT (OLD.status IN ('draft', 'rejected', 'revision_requested')
                    AND NEW.status = 'submitted') THEN
                RAISE EXCEPTION 'illegal transition % -> %', OLD.status, NEW.status;
            END IF;
        ELSE
            IF NOT (OLD.status = 'submitted'
                    AND NEW.status IN ('approved', 'rejected', 'revision_requested')) THEN
                RAISE EXCEPTION 'illegal transition % -> %', OLD.status, NEW.status;
            END IF;
        END IF;
    END IF;
    NEW.updated_at := extract(epoch FROM now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION delete_my_account() RETURNS void AS $$
BEGIN
    UPDATE accounts
       SET display_name = 'Deleted account',
           last_name    = 'Deleted',
           deleted_at   = extract(epoch FROM now())
     WHERE id = app_uid();

    UPDATE hour_entries
       SET description      = '',
           organization     = 'Redacted',
           verifier_name    = '',
           verifier_contact = '',
           evidence_url     = NULL
     WHERE student_id = app_uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;

-- 0001 protected the audit log with rules that DO INSTEAD NOTHING. The rows are
-- safe either way, but a silent no-op is the wrong shape for this: tampering
-- should fail loudly, and the SQLite schema raises. Rules out, trigger in, so
-- both backends behave the same and `test_backend.py` can assert it.

BEGIN;

DROP RULE IF EXISTS audit_log_no_update ON audit_log;
DROP RULE IF EXISTS audit_log_no_delete ON audit_log;

CREATE OR REPLACE FUNCTION audit_log_immutable() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'the audit log is append-only';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS audit_log_immutable_trg ON audit_log;
CREATE TRIGGER audit_log_immutable_trg
BEFORE UPDATE OR DELETE ON audit_log
FOR EACH ROW EXECUTE FUNCTION audit_log_immutable();

COMMIT;
