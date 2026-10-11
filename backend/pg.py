"""A SQLite-shaped interface over Postgres.

`backend/server.py` is written against `sqlite3`: `?` placeholders, rows indexed
by column name, `BEGIN IMMEDIATE`, `COLLATE NOCASE`. Rewriting those at every
call site would have meant touching nineteen places in a file whose correctness
is the point of the project, so the differences are translated here instead and
the server is left alone.

What is translated:

    ?                 ->  %s
    BEGIN IMMEDIATE   ->  BEGIN
    x COLLATE NOCASE  ->  lower(x)

Everything else - `ON CONFLICT (a, b) DO UPDATE SET`, `RETURNING`, `excluded.` -
is the same in both.

The server connects as the owning role, so row-level security does not apply to
it; the server's own checks are what enforce access, and the 55 tests in
`test_backend.py` are what prove them. The policies are defence in depth for
anything that reaches the database another way, and
`test_postgres_rls.py` proves those separately.
"""
import datetime
import re
import uuid
from decimal import Decimal

import psycopg
from psycopg.rows import dict_row

_COLLATE = re.compile(r"(\b[\w.]+\b)\s+COLLATE\s+NOCASE", re.IGNORECASE)


def translate(sql, has_params):
    """Rewrite SQLite SQL for Postgres.

    `has_params` matters: psycopg only treats `%` as a placeholder when
    parameters are passed, so a literal percent - `LIKE \'racer%\'` - has to be
    doubled in that case and left alone otherwise.
    """
    sql = _COLLATE.sub(r"lower(\1)", sql)
    sql = sql.replace("BEGIN IMMEDIATE", "BEGIN")
    if has_params:
        sql = sql.replace("%", "%%").replace("?", "%s")
    return sql


class Row(dict):
    """A dict that also answers to a column index, as sqlite3.Row does."""

    def __getitem__(self, key):
        if isinstance(key, int):
            return list(self.values())[key]
        return super().__getitem__(key)

    def keys(self):
        return list(super().keys())


def _plain(value):
    """Postgres types the server and the app do not speak.

    psycopg returns `uuid.UUID` for uuid columns and `Decimal` for numeric ones.
    Neither is JSON-serialisable, and the iOS models declare these fields as
    `String` and `Double`, so both are converted at the boundary rather than at
    every use.
    """
    if isinstance(value, uuid.UUID):
        return str(value)
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (datetime.date, datetime.datetime)):
        # service_date is a real date in Postgres and an ISO string everywhere
        # else - in the API, in the iOS models, and in SQLite.
        return value.isoformat()
    return value


def _row_factory(cursor):
    inner = dict_row(cursor)
    return lambda values: Row(
        (key, _plain(value)) for key, value in inner(values).items()
    )


class Connection:
    """Shaped like a sqlite3 connection, backed by psycopg."""

    def __init__(self, dsn):
        self._conn = psycopg.connect(
            dsn, autocommit=True, row_factory=_row_factory, connect_timeout=20
        )

    def execute(self, sql, params=()):
        cursor = self._conn.cursor()
        params = tuple(params)
        if params:
            cursor.execute(translate(sql, True), params)
        else:
            cursor.execute(translate(sql, False))
        return cursor

    def executescript(self, sql):
        # Migrations own the schema in Postgres; nothing here creates tables.
        return None

    def cursor(self):
        return self._conn.cursor()

    def set_account(self, account_id):
        """Tell the database who the current request belongs to.

        The server connects as the owning role and does its own authorisation,
        but the triggers in the schema also ask - `accounts_guard()` refuses a
        role change unless `is_admin()`, and `is_admin()` reads this. Without it
        the database second-guesses a decision the server already made correctly
        and refuses legitimate work.

        Session-scoped rather than transaction-scoped because the server shares
        one connection behind a lock and sets this on every authenticated
        request. A pooled, concurrent server must use SET LOCAL inside the
        request's transaction instead - otherwise one request answers as the
        previous user.
        """
        self.execute(
            "select set_config('greencord.account_id', ?, false)",
            (str(account_id or ""),),
        )

    def commit(self):
        pass

    def close(self):
        self._conn.close()

    def __getattr__(self, name):
        return getattr(self._conn, name)


def connect(dsn):
    return Connection(dsn)
