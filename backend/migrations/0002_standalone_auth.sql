-- Option A from DEPLOY.md: the application server owns identity.
--
-- 0001 delegates identity to Supabase: accounts.id references auth.users(id)
-- and every policy is written against auth.uid(). That is a clean design, but
-- it is not the design `backend/server.py` implements - the server stores a
-- username and a password hash on the account itself and checks them. The two
-- cannot both be true, and the Postgres accounts table has no username column,
-- so the existing server fails at sign-in against 0001 alone.
--
-- This migration reconciles them in the server's favour, which keeps the 55
-- backend tests meaningful and leaves the invite-code model - an admin names a
-- student, the code carries their identity - exactly as built.
--
-- The trade: Supabase's own authentication is unused. The database still
-- enforces every access rule; it just learns who is asking from a session
-- setting the server sets on each connection rather than from a JWT.
--
--     SET LOCAL greencord.account_id = '<the signed-in account id>';
--
-- Set it with SET LOCAL inside the transaction serving one request, never
-- globally: a pooled connection that keeps the setting would answer the next
-- request as the previous user.
--
-- Apply after 0001:
--     psql "$DATABASE_URL" -f backend/migrations/0002_standalone_auth.sql

BEGIN;

-- ------------------------------------------------------- identity on accounts

ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_id_fkey;
ALTER TABLE accounts ALTER COLUMN id SET DEFAULT gen_random_uuid();

ALTER TABLE accounts ADD COLUMN IF NOT EXISTS username      text;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS password_hash text NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS password_salt text NOT NULL DEFAULT '';

CREATE UNIQUE INDEX IF NOT EXISTS accounts_username_key
    ON accounts (lower(username)) WHERE username IS NOT NULL;

-- ------------------------------------------------------------ who is asking

-- The server sets this per request. `true` as the second argument means an
-- unset value returns NULL rather than raising, so an unauthenticated
-- connection simply matches nothing.
CREATE OR REPLACE FUNCTION app_uid() RETURNS uuid AS $$
    SELECT NULLIF(current_setting('greencord.account_id', true), '')::uuid;
$$ LANGUAGE sql STABLE;

-- Redefined to read app_uid() instead of auth.uid(). Policies that only call
-- these two - every invite_codes and password_resets policy - need no further
-- change; they pick up the new body.
CREATE OR REPLACE FUNCTION is_staff() RETURNS boolean AS $$
    SELECT EXISTS (
        SELECT 1 FROM accounts
        WHERE id = app_uid() AND role IN ('manager', 'admin') AND deleted_at IS NULL
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_admin() RETURNS boolean AS $$
    SELECT EXISTS (
        SELECT 1 FROM accounts
        WHERE id = app_uid() AND role = 'admin' AND deleted_at IS NULL
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- -------------------------------------- policies that named auth.uid() directly

DROP POLICY IF EXISTS accounts_self_select ON accounts;
CREATE POLICY accounts_self_select ON accounts
    FOR SELECT USING (id = app_uid() OR is_staff());

DROP POLICY IF EXISTS accounts_self_update ON accounts;
CREATE POLICY accounts_self_update ON accounts
    FOR UPDATE USING (id = app_uid() OR is_staff());

DROP POLICY IF EXISTS entries_student_select ON hour_entries;
CREATE POLICY entries_student_select ON hour_entries
    FOR SELECT USING (student_id = app_uid() OR is_staff());

DROP POLICY IF EXISTS entries_student_insert ON hour_entries;
CREATE POLICY entries_student_insert ON hour_entries
    FOR INSERT WITH CHECK (
        (student_id = app_uid() AND status = 'draft' AND counselor_entered = false)
        OR is_staff()
    );

-- The permanence rule: an approved row is not visible to a student's UPDATE,
-- so an edit has nothing to act on.
DROP POLICY IF EXISTS entries_student_update ON hour_entries;
CREATE POLICY entries_student_update ON hour_entries
    FOR UPDATE USING (
        (student_id = app_uid()
         AND status IN ('draft', 'rejected', 'revision_requested'))
        OR is_staff()
    );

DROP POLICY IF EXISTS entries_student_delete ON hour_entries;
CREATE POLICY entries_student_delete ON hour_entries
    FOR DELETE USING (
        (student_id = app_uid()
         AND status IN ('draft', 'rejected', 'revision_requested'))
        OR is_staff()
    );

DROP POLICY IF EXISTS approvals_select ON approvals;
CREATE POLICY approvals_select ON approvals
    FOR SELECT USING (
        is_staff() OR EXISTS (
            SELECT 1 FROM hour_entries e
            WHERE e.id = approvals.entry_id AND e.student_id = app_uid()
        )
    );

DROP POLICY IF EXISTS approvals_staff_insert ON approvals;
CREATE POLICY approvals_staff_insert ON approvals
    FOR INSERT WITH CHECK (is_staff() AND actor_id = app_uid());

DROP POLICY IF EXISTS audit_staff_select ON audit_log;
CREATE POLICY audit_staff_select ON audit_log
    FOR SELECT USING (is_staff() OR account_id = app_uid());

DROP POLICY IF EXISTS checklist_self ON checklist_state;
CREATE POLICY checklist_self ON checklist_state
    FOR ALL USING (account_id = app_uid() OR is_staff())
    WITH CHECK (account_id = app_uid());

-- ---------------------------------------------------------------- sessions

-- 0001 had no sessions table: Supabase issued the tokens. With the server
-- owning identity it issues its own, so it needs somewhere to keep them.
CREATE TABLE IF NOT EXISTS sessions (
    token      text PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts(id),
    created_at double precision NOT NULL,
    expires_at double precision NOT NULL
);

ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
-- No policy at all: only the server, connecting as the owning role, touches
-- this table. Nothing holding the public key should ever read a session token.

-- -------------------------------------------------------------- redemption

-- 0001's redeem_invite_code() creates the account as auth.uid(). With the
-- server owning identity there is no such caller, so the account id is
-- generated here and returned for the server to issue a session against.
CREATE OR REPLACE FUNCTION redeem_invite_code(
    p_code text, p_username text, p_password_hash text, p_password_salt text
) RETURNS accounts AS $$
DECLARE
    v_code invite_codes%ROWTYPE;
    v_account accounts%ROWTYPE;
    v_id uuid := gen_random_uuid();
BEGIN
    UPDATE invite_codes
       SET redeemed_by = v_id, redeemed_at = now()
     WHERE code = upper(p_code)
       AND redeemed_by IS NULL
       AND revoked_at IS NULL
       AND expires_at > now()
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
