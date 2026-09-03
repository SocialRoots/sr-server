#!/usr/bin/env bash
# Copyright (C) 2020-2026 Wicked Co-op LCA
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# backfill-response-participation.sh
#
# Idempotent backfill that builds the RESPONSES `response_participation` index
# (one row per (noteKey, userKey)) and points every existing event row
# (reactions, replies, emojis) at its `part_key`.
#
# Why a script and not a migration: the mapping (note_participants.link ->
# noteKey/userKey) lives in the NOTES database, which is a SEPARATE physical DB
# from RESPONSES. Plain postgres cannot join across databases, so we pull the
# NOTES map out to a temp file and load it into a staging table in RESPONSES.
#
# Idempotency: each run only touches rows whose `part_key` is still NULL, so it
# is safe to re-run until the old endpoints that do not set `part_key` are
# retired. Run it repeatedly from cron if desired.
#
# Usage (env from repo .env):
#   source .env && ./bin/backfill-response-participation.sh

set -euo pipefail

# ---- config (from env) ----
: "${POSTGRES_USER:?}"
: "${POSTGRES_PASSWORD:?}"
: "${POSTGRES_HOST:=localhost}"
: "${POSTGRES_PORT:=5432}"
: "${DB_NAME_NOTES:?}"
: "${DB_NAME_RESPONSES:?}"

export PGPASSWORD="$POSTGRES_PASSWORD"
TMP_CSV="${TMPDIR:-/tmp}/sr_notes_participation_map.csv"

PSQL_N="psql -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $DB_NAME_NOTES -X -v ON_ERROR_STOP=1 -tA"
PSQL_R="psql -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $DB_NAME_RESPONSES -X -v ON_ERROR_STOP=1"

echo "== [1/4] Dump NOTES participation map =="
# part_link = note_participants.link (per-(note,user) cap); email lets us
# disambiguate the note_key-addressed orphan events (addr by notes.link).
$PSQL_N -c "\copy (SELECT np.link, n.id, n.link, p.user_key, np.participant_group_key, p.email FROM note_participants np JOIN participants p ON p.id = np.participant_id JOIN notes n ON n.id = np.note_id WHERE p.user_key <> '') TO '$TMP_CSV' WITH CSV"
echo "   wrote $(wc -l < "$TMP_CSV") rows"

echo "== [2/4] Load map into RESPONSES staging =="
$PSQL_R -c "DROP TABLE IF EXISTS _sr_part_staging"
$PSQL_R <<'SQL'
CREATE TABLE _sr_part_staging (
    part_link   text PRIMARY KEY,
    note_id     bigint,
    note_key    text,
    user_key    text,
    group_key   text,
    email       text
);
SQL
$PSQL_R -c "\\copy _sr_part_staging (part_link, note_id, note_key, user_key, group_key, email) FROM '$TMP_CSV' WITH CSV"

echo "== [3/4] Build response_participation (fresh part_key per (note,user)) =="
$PSQL_R <<'SQL'
INSERT INTO response_participation (part_key, note_key, user_key)
SELECT DISTINCT ON (note_key, user_key)
       replace(gen_random_uuid()::text, '-', ''),
       note_key, user_key
FROM _sr_part_staging
WHERE user_key <> ''
ON CONFLICT (note_key, user_key) DO NOTHING;
SQL
echo "   response_participation rows: $($PSQL_R -tA -c 'SELECT count(*) FROM response_participation')"

echo "== [4/4] Point event rows at part_key =="

echo "  -- reactions (by part_link) --"
$PSQL_R <<'SQL'
UPDATE response_reactions rr
SET part_key = rp.part_key
FROM _sr_part_staging s
JOIN response_participation rp
  ON rp.note_key = s.note_key AND rp.user_key = s.user_key
WHERE rr.part_key IS NULL AND rr.note_link = s.part_link;
SQL

# note_key-addressed reactions: note_link is a note_key, disambiguate by email.
echo "  -- reactions (by note_key + email) --"
$PSQL_R <<'SQL'
UPDATE response_reactions rr
SET part_key = rp.part_key
FROM _sr_part_staging s
JOIN response_participation rp
  ON rp.note_key = s.note_key AND rp.user_key = s.user_key
WHERE rr.part_key IS NULL
  AND rr.note_link = s.note_key
  AND rr.linked_email = s.email;
SQL

echo "  -- replies (by note_key: note_link) --"
$PSQL_R <<'SQL'
UPDATE response_replies rr
SET part_key = rp.part_key
FROM _sr_part_staging s
JOIN response_participation rp
  ON rp.note_key = s.note_key AND rp.user_key = s.user_key
WHERE rr.part_key IS NULL AND rr.note_link = s.part_link;
SQL
# note_key + email case
$PSQL_R <<'SQL'
UPDATE response_replies rr
SET part_key = rp.part_key
FROM _sr_part_staging s
JOIN response_participation rp
  ON rp.note_key = s.note_key AND rp.user_key = s.user_key
WHERE rr.part_key IS NULL
  AND rr.note_link = s.note_key
  AND rr.reply_email = s.email;
SQL

echo "  -- emojis (reply-held: up key from replies) --"
$PSQL_R <<'SQL'
UPDATE response_emojis em
SET part_key = rr.part_key
FROM response_replies rr
WHERE em.part_key IS NULL AND em.reply_id > 0 AND em.reply_id = rr.id;
SQL

echo "  -- emojis (note-level, no reply_id: via note_id + user_key) --"
$PSQL_R <<'SQL'
UPDATE response_emojis em
SET part_key = rp.part_key
FROM _sr_part_staging s
JOIN response_participation rp
  ON rp.note_key = s.note_key AND rp.user_key = s.user_key
WHERE em.part_key IS NULL AND em.reply_id = 0
  AND em.note_id = s.note_id AND em.user_key = s.user_key;
SQL

echo "== summary =="
echo "  reactions with part_key: $($PSQL_R -tA -c 'SELECT count(*) FROM response_reactions WHERE part_key IS NOT NULL')"
echo "  replies   with part_key: $($PSQL_R -tA -c 'SELECT count(*) FROM response_replies   WHERE part_key IS NOT NULL')"
echo "  emojis    with part_key: $($PSQL_R -tA -c 'SELECT count(*) FROM response_emojis    WHERE part_key IS NOT NULL')"

echo "== unresolved (still NULL) =="
echo "  reactions: $($PSQL_R -tA -c 'SELECT count(*) FROM response_reactions WHERE part_key IS NULL')"
echo "  replies:   $($PSQL_R -tA -c 'SELECT count(*) FROM response_replies   WHERE part_key IS NULL')"
echo "  emojis:    $($PSQL_R -tA -c 'SELECT count(*) FROM response_emojis    WHERE part_key IS NULL')"

$PSQL_R -c "DROP TABLE IF EXISTS _sr_part_staging"
echo "done."