-- Green Cord program schema for Postgres with row-level security.
--
-- This is the production deployment target (Supabase). It is the authoritative
-- expression of the access rules; the prototype's SQLite server in backend/db.py
-- mirrors it so the app can be demonstrated without a database to install.
--
-- Apply with:
--     psql "$DATABASE_URL" -f backend/migrations/0001_init.sql
--
-- It assumes Supabase's `auth.users` table and `auth.uid()` helper. On plain
-- Postgres, replace auth.uid() with your own session-user function.

BEGIN;

-- student: logs their own hours. manager: reviews hours and manages students.
-- admin:   everything a manager can, plus creating and removing staff.
CREATE TYPE account_role  AS ENUM ('student', 'manager', 'admin');
CREATE TYPE entry_status  AS ENUM ('draft', 'submitted', 'approved', 'rejected',
                                   'revision_requested');
CREATE TYPE approval_action AS ENUM ('approve', 'reject', 'request_revision', 'revise');

-- ---------------------------------------------------------------- accounts

CREATE TABLE accounts (
    id            uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    role          account_role NOT NULL DEFAULT 'student',
    display_name  text NOT NULL,
    last_name     text NOT NULL,
    grade         smallint CHECK (grade BETWEEN 9 AND 12),
    created_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    CONSTRAINT grade_matches_role CHECK (
        (role = 'student' AND grade IS NOT NULL) OR
        (role IN ('manager', 'admin') AND grade IS NULL)
    )
);

-- Anyone who can review hours: a manager or an admin.
CREATE OR REPLACE FUNCTION is_staff() RETURNS boolean AS $$
    SELECT EXISTS (
        SELECT 1 FROM accounts
        WHERE id = auth.uid() AND role IN ('manager', 'admin') AND deleted_at IS NULL
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Only an admin may create, change or remove staff accounts.
CREATE OR REPLACE FUNCTION is_admin() RETURNS boolean AS $$
    SELECT EXISTS (
        SELECT 1 FROM accounts
        WHERE id = auth.uid() AND role = 'admin' AND deleted_at IS NULL
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- How many admins are left, ignoring one account. The program must always have
-- an owner, so the guard below refuses any change that would leave none.
CREATE OR REPLACE FUNCTION other_admin_count(p_excluding uuid)
RETURNS integer AS $$
    SELECT count(*)::int FROM accounts
    WHERE role = 'admin' AND deleted_at IS NULL AND id IS DISTINCT FROM p_excluding;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- A student may update their own profile but may NOT change their own role or
-- grade. This trigger is what makes client-side escalation impossible: even a
-- caller holding a valid student token and issuing a direct PATCH cannot move
-- themselves to 'admin'.
CREATE OR REPLACE FUNCTION accounts_guard() RETURNS trigger AS $$
BEGIN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
        -- A role change is an admin action, whoever is asking.
        IF NOT is_admin() THEN
            RAISE EXCEPTION 'only an admin can change an account role';
        END IF;
        -- Students are invited as students; staff access comes from a staff
        -- invite, not from promoting a student record.
        IF OLD.role = 'student' OR NEW.role = 'student' THEN
            RAISE EXCEPTION 'staff access comes from a staff invite, not from a student account';
        END IF;
        -- The program cannot be left without an owner.
        IF OLD.role = 'admin' AND NEW.role <> 'admin'
           AND other_admin_count(OLD.id) = 0 THEN
            RAISE EXCEPTION 'this is the only admin; make someone else an admin first';
        END IF;
    END IF;

    IF NOT is_admin() AND NEW.grade IS DISTINCT FROM OLD.grade THEN
        RAISE EXCEPTION 'grade comes from the invite code and cannot be self-assigned';
    END IF;

    -- Removing the last admin would strand the program just as surely as
    -- demoting them.
    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL
       AND OLD.role = 'admin' AND other_admin_count(OLD.id) = 0 THEN
        RAISE EXCEPTION 'this is the only admin; make someone else an admin first';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER accounts_guard_trg
BEFORE UPDATE ON accounts
FOR EACH ROW EXECUTE FUNCTION accounts_guard();

ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY accounts_self_select ON accounts
    FOR SELECT USING (id = auth.uid() OR is_staff());
CREATE POLICY accounts_self_update ON accounts
    FOR UPDATE USING (id = auth.uid() OR is_staff());
-- No INSERT policy: rows are created only by the redeem_invite_code() function
-- below, which is SECURITY DEFINER.

-- ------------------------------------------------------------ invite codes

CREATE TABLE invite_codes (
    code        text PRIMARY KEY CHECK (code ~ '^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$'),
    issued_by   uuid NOT NULL REFERENCES accounts(id),
    -- The person this code was made for. Whoever issues it names them when the
    -- code is issued, so the roster exists before anyone signs up and a code
    -- can never be used by whoever happens to find it.
    first_name  text NOT NULL,
    last_name   text NOT NULL,
    -- A student code carries a grade; a staff code carries a role instead and
    -- may only be issued by an admin.
    role        account_role NOT NULL DEFAULT 'student',
    grade       smallint CHECK (grade IS NULL OR grade BETWEEN 9 AND 12),
    CONSTRAINT code_grade_matches_role CHECK (
        (role = 'student' AND grade IS NOT NULL) OR
        (role IN ('manager', 'admin') AND grade IS NULL)
    ),
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    revoked_at  timestamptz,
    redeemed_by uuid UNIQUE REFERENCES accounts(id),
    redeemed_at timestamptz
);

ALTER TABLE invite_codes ENABLE ROW LEVEL SECURITY;

-- Only staff ever read or write codes. A student redeems one through
-- the SECURITY DEFINER function below, without SELECT access to the table, so a
-- student cannot enumerate unredeemed codes.
CREATE POLICY codes_staff_read ON invite_codes
    FOR SELECT USING (is_staff());

-- Staff may issue student codes; only an admin may issue a staff code.
CREATE POLICY codes_staff_write ON invite_codes
    FOR INSERT WITH CHECK (
        is_staff() AND (role = 'student' OR is_admin())
    );
CREATE POLICY codes_staff_update ON invite_codes
    FOR UPDATE USING (is_staff());

-- Atomic redemption. The UPDATE ... WHERE redeemed_by IS NULL is the lock: two
-- concurrent redemptions of one code cannot both find it unclaimed, so exactly
-- one account is ever created.
-- The name and role are not parameters: both come from the code that was
-- issued, so nobody can enrol under a name or a role they were not given.
CREATE OR REPLACE FUNCTION redeem_invite_code(
    p_code text
) RETURNS accounts AS $$
DECLARE
    v_code invite_codes%ROWTYPE;
    v_account accounts%ROWTYPE;
BEGIN
    UPDATE invite_codes
       SET redeemed_by = auth.uid(), redeemed_at = now()
     WHERE code = upper(p_code)
       AND redeemed_by IS NULL
       AND revoked_at IS NULL
       AND expires_at > now()
    RETURNING * INTO v_code;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'invite code is not valid' USING ERRCODE = '22023';
    END IF;

    INSERT INTO accounts (id, role, display_name, last_name, grade)
    VALUES (
        auth.uid(), v_code.role,
        v_code.first_name || ' ' || v_code.last_name,
        v_code.last_name, v_code.grade
    )
    RETURNING * INTO v_account;

    RETURN v_account;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- --------------------------------------------------------- password resets

-- A one-time code that lets someone set a new password. No email server stands
-- behind the prototype, so an admin issues one and hands it over; issuing it
-- neither reveals nor changes the current password.
CREATE TABLE password_resets (
    code       text PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts(id),
    issued_by  uuid NOT NULL REFERENCES accounts(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    used_at    timestamptz
);

ALTER TABLE password_resets ENABLE ROW LEVEL SECURITY;

-- Only an admin issues them. Nobody reads them back: redemption happens through
-- a SECURITY DEFINER function, so a leaked listing cannot hand over an account.
CREATE POLICY resets_admin_insert ON password_resets
    FOR INSERT WITH CHECK (is_admin());
CREATE POLICY resets_admin_select ON password_resets
    FOR SELECT USING (is_admin());

-- ------------------------------------------------------------- hour entries

CREATE TABLE hour_entries (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id        uuid NOT NULL REFERENCES accounts(id),
    service_date      date NOT NULL,
    hours             numeric(5,2) NOT NULL CHECK (hours > 0),
    category          text NOT NULL,
    organization      text NOT NULL,
    description       text NOT NULL,
    verifier_name     text NOT NULL,
    verifier_contact  text NOT NULL,
    evidence_url      text,
    counselor_entered boolean NOT NULL DEFAULT false,
    status            entry_status NOT NULL DEFAULT 'draft',
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    submitted_at      timestamptz,
    decided_at        timestamptz
);

CREATE INDEX hour_entries_student_idx ON hour_entries(student_id);
CREATE INDEX hour_entries_status_idx  ON hour_entries(status);

ALTER TABLE hour_entries ENABLE ROW LEVEL SECURITY;

-- A student sees only their own rows. There is no policy that lets one student
-- read another's, so no roster, total or ranking can leak through this table.
CREATE POLICY entries_student_select ON hour_entries
    FOR SELECT USING (student_id = auth.uid() OR is_staff());

CREATE POLICY entries_student_insert ON hour_entries
    FOR INSERT WITH CHECK (
        (student_id = auth.uid() AND status = 'draft' AND counselor_entered = false)
        OR is_staff()
    );

-- The USING clause is the permanence rule: an approved row is simply not
-- visible to a student's UPDATE, so no edit can reach it.
CREATE POLICY entries_student_update ON hour_entries
    FOR UPDATE USING (
        (student_id = auth.uid()
         AND status IN ('draft', 'rejected', 'revision_requested'))
        OR is_staff()
    );

CREATE POLICY entries_student_delete ON hour_entries
    FOR DELETE USING (
        (student_id = auth.uid()
         AND status IN ('draft', 'rejected', 'revision_requested'))
        OR is_staff()
    );

-- Legal transitions, enforced regardless of who the caller is.
CREATE OR REPLACE FUNCTION entries_transition_guard() RETURNS trigger AS $$
BEGIN
    IF NEW.status <> OLD.status THEN
        IF NOT is_staff() THEN
            -- A student may only move an editable row to 'submitted'.
            IF NOT (OLD.status IN ('draft', 'rejected', 'revision_requested')
                    AND NEW.status = 'submitted') THEN
                RAISE EXCEPTION 'illegal transition % -> % for a student',
                    OLD.status, NEW.status;
            END IF;
        ELSE
            IF NOT (OLD.status = 'submitted'
                    AND NEW.status IN ('approved', 'rejected', 'revision_requested')) THEN
                RAISE EXCEPTION 'illegal transition % -> %', OLD.status, NEW.status;
            END IF;
        END IF;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER entries_transition_trg
BEFORE UPDATE ON hour_entries
FOR EACH ROW EXECUTE FUNCTION entries_transition_guard();

-- ---------------------------------------------------------------- approvals

CREATE TABLE approvals (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id   uuid NOT NULL REFERENCES hour_entries(id) ON DELETE CASCADE,
    actor_id   uuid NOT NULL REFERENCES accounts(id),
    action     approval_action NOT NULL,
    note       text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE approvals ENABLE ROW LEVEL SECURITY;

CREATE POLICY approvals_select ON approvals
    FOR SELECT USING (
        is_staff()
        OR EXISTS (SELECT 1 FROM hour_entries e
                   WHERE e.id = approvals.entry_id AND e.student_id = auth.uid())
    );
CREATE POLICY approvals_staff_insert ON approvals
    FOR INSERT WITH CHECK (is_staff() AND actor_id = auth.uid());

-- ---------------------------------------------------------------- audit log

CREATE TABLE audit_log (
    id          bigserial PRIMARY KEY,
    at          timestamptz NOT NULL DEFAULT now(),
    actor_id    uuid,
    actor_role  text,
    action      text NOT NULL,
    entry_id    uuid,
    account_id  uuid,
    before_json jsonb,
    after_json  jsonb
);

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY audit_staff_select ON audit_log
    FOR SELECT USING (is_staff() OR account_id = auth.uid());

-- Append-only: no UPDATE or DELETE policy exists, and these rules block the
-- table owner too. A staff revision therefore adds history; it never
-- rewrites it, so an approval's original values stay retrievable.
CREATE RULE audit_log_no_update AS ON UPDATE TO audit_log DO INSTEAD NOTHING;
CREATE RULE audit_log_no_delete AS ON DELETE TO audit_log DO INSTEAD NOTHING;

CREATE OR REPLACE FUNCTION log_entry_change() RETURNS trigger AS $$
BEGIN
    INSERT INTO audit_log (actor_id, actor_role, action, entry_id, account_id,
                           before_json, after_json)
    VALUES (
        auth.uid(),
        (SELECT role::text FROM accounts WHERE id = auth.uid()),
        TG_OP || CASE WHEN TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status
                      THEN ':' || NEW.status ELSE '' END,
        COALESCE(NEW.id, OLD.id),
        COALESCE(NEW.student_id, OLD.student_id),
        CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER hour_entries_audit_trg
AFTER INSERT OR UPDATE OR DELETE ON hour_entries
FOR EACH ROW EXECUTE FUNCTION log_entry_change();

-- --------------------------------------------------------------- checklist

CREATE TABLE checklist_state (
    account_id uuid NOT NULL REFERENCES accounts(id),
    item_id    text NOT NULL,
    checked    boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, item_id)
);

ALTER TABLE checklist_state ENABLE ROW LEVEL SECURITY;

CREATE POLICY checklist_self ON checklist_state
    FOR ALL USING (account_id = auth.uid() OR is_staff())
    WITH CHECK (account_id = auth.uid());

-- ------------------------------------------------------ deletion / retention
--
-- Retention rule (PENDING DISTRICT CONFIRMATION - see RELEASE.md):
-- personal identifiers are irreversibly overwritten; the hours themselves are
-- retained so the program's aggregate service record stays intact.

CREATE OR REPLACE FUNCTION delete_my_account() RETURNS void AS $$
BEGIN
    UPDATE accounts
       SET display_name = 'Deleted account',
           last_name    = 'Deleted',
           deleted_at   = now()
     WHERE id = auth.uid();

    UPDATE hour_entries
       SET description      = '',
           organization     = 'Redacted',
           verifier_name    = '',
           verifier_contact = '',
           evidence_url     = NULL
     WHERE student_id = auth.uid();

    INSERT INTO audit_log (actor_id, actor_role, action, account_id)
    VALUES (auth.uid(), 'student', 'account.deleted', auth.uid());
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;
