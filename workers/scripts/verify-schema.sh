#!/usr/bin/env bash
# Applies the migrations and seed to a throwaway SQLite database, then proves the
# constraints actually reject bad data.
#
# D1 is SQLite, so local sqlite3 is a faithful check of schema, constraints and indexes.
# It runs in under a second and needs no network, so it belongs in the tight loop and in
# CI on every pull request.
#
#   workers/scripts/verify-schema.sh
set -uo pipefail

cd "$(dirname "$0")/.."
DB="$(mktemp -d)/verify.db"
PASS=0
FAIL=0

# Foreign keys are off by default in the sqlite3 CLI. D1 enforces them, so the local check
# must too or it would be checking a weaker schema than production.
PRAGMA="pragma foreign_keys = on;"

run_sql() { sqlite3 "$DB" "$PRAGMA $1" 2>&1; }

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$1" "${2:-}"; }

# Asserts a statement is REJECTED. A constraint nobody has tried to violate is a comment.
denies() {
  local label="$1" sql="$2" out
  out="$(run_sql "$sql")"
  if [[ $? -ne 0 ]]; then ok "$label"; else bad "$label" "statement was ACCEPTED but should have been rejected"; fi
}

# Asserts a query returns an exact value.
equals() {
  local label="$1" sql="$2" want="$3" got
  got="$(run_sql "$sql")"
  if [[ "$got" == "$want" ]]; then ok "$label"; else bad "$label" "expected [$want], got [$got]"; fi
}

echo
echo "Applying migrations"
for migration in migrations/*.sql; do
  if out="$(sqlite3 "$DB" ".read $migration" 2>&1)"; then
    echo "  applied $migration"
  else
    echo "  FAILED $migration"; echo "$out"; exit 1
  fi
done

echo "Applying seed"
# `.read` is a dot-command and must stand on its own line, so this goes through stdin
# rather than being concatenated with the pragma.
if out="$(sqlite3 "$DB" 2>&1 <<'SQL'
pragma foreign_keys = on;
.read seed.sql
SQL
)"; then
  echo "  applied seed.sql"
else
  echo "  FAILED seed.sql"; echo "$out"; exit 1
fi

echo
echo "Integrity"
equals "integrity_check clean"    "pragma integrity_check;"    "ok"
equals "no foreign key violations" "select count(*) from pragma_foreign_key_check;" "0"
equals "every table is STRICT" \
  "select count(*) from pragma_table_list where schema='main' and type='table' and name not like 'sqlite_%' and strict=0;" "0"

echo
echo "Anonymity (rules 8 and 9)"
equals "posts has no author column" \
  "select count(*) from pragma_table_info('posts') where name in ('author_id','owner_id','account_id','is_anonymous');" "0"
equals "the anonymous prayer shows no profile" \
  "select coalesce(display_profile_id,'NULL') from posts where id='01930000-0000-7000-8000-00000000c002';" "NULL"
equals "but the platform still knows the author" \
  "select owner_id from post_authorship where post_id='01930000-0000-7000-8000-00000000c002';" \
  "01930000-0000-7000-8000-00000000b001"

echo
echo "Content constraints"
denies "unknown post type" \
  "insert into posts (id,type,body,visibility,status,display_profile_id,created_at,updated_at) values ('t1','sermon','x','public','active','01930000-0000-7000-8000-00000000a001',1,1);"
denies "unknown visibility" \
  "insert into posts (id,type,body,visibility,status,display_profile_id,created_at,updated_at) values ('t2','prayer','x','friends','active','01930000-0000-7000-8000-00000000a001',1,1);"
denies "empty body" \
  "insert into posts (id,type,body,visibility,status,display_profile_id,created_at,updated_at) values ('t3','prayer','','public','active','01930000-0000-7000-8000-00000000a001',1,1);"
denies "anonymous private post" \
  "insert into posts (id,type,body,visibility,status,display_profile_id,created_at,updated_at) values ('t4','prayer','x','private','active',null,1,1);"
denies "a miracle marked answered" \
  "insert into posts (id,type,body,visibility,status,display_profile_id,created_at,updated_at,answered_at) values ('t5','miracle','x','public','answered','01930000-0000-7000-8000-00000000a001',1,1,1);"
denies "answered without a timestamp" \
  "insert into posts (id,type,body,visibility,status,display_profile_id,created_at,updated_at) values ('t6','prayer','x','public','answered','01930000-0000-7000-8000-00000000a001',1,1);"
denies "negative counter" \
  "update posts set prayer_response_count=-1 where id='01930000-0000-7000-8000-00000000c001';"
denies "STRICT rejects text in an integer column" \
  "insert into posts (id,type,body,visibility,status,display_profile_id,created_at,updated_at) values ('t7','prayer','x','public','active','01930000-0000-7000-8000-00000000a001','yesterday',1);"
denies "authorship for an account that does not exist" \
  "insert into post_authorship (post_id,owner_id,created_at) values ('01930000-0000-7000-8000-00000000c001','ghost',1);"

echo
echo "The core loop"
denies "praying twice for the same post" \
  "insert into prayer_responses (post_id,account_id,created_at) values ('01930000-0000-7000-8000-00000000c004','01930000-0000-7000-8000-00000000b001',1);"
denies "answering the same prayer twice" \
  "insert into answered_links (prayer_post_id,miracle_post_id,created_at) values ('01930000-0000-7000-8000-00000000c004','01930000-0000-7000-8000-00000000c001',1);"
denies "two prayers claiming one miracle" \
  "insert into answered_links (prayer_post_id,miracle_post_id,created_at) values ('01930000-0000-7000-8000-00000000c002','01930000-0000-7000-8000-00000000c005',1);"
denies "a prayer answered by itself" \
  "insert into answered_links (prayer_post_id,miracle_post_id,created_at) values ('01930000-0000-7000-8000-00000000c001','01930000-0000-7000-8000-00000000c001',1);"
equals "prayer resolves to its miracle" \
  "select miracle_post_id from answered_links where prayer_post_id='01930000-0000-7000-8000-00000000c004';" \
  "01930000-0000-7000-8000-00000000c005"
equals "and the miracle back to its prayer" \
  "select prayer_post_id from answered_links where miracle_post_id='01930000-0000-7000-8000-00000000c005';" \
  "01930000-0000-7000-8000-00000000c004"

echo
echo "Identity and social graph"
denies "duplicate username"        "insert into profiles (account_id,username,display_name,created_at,updated_at) values ('01930000-0000-7000-8000-00000000b001','connor','X',1,1);"
denies "uppercase username"        "update profiles set username='Connor' where username='gabi';"
denies "username with punctuation" "update profiles set username='ga.bi' where username='gabi';"
denies "two-character username"    "update profiles set username='ga' where username='gabi';"
denies "following yourself"        "insert into follows (follower_id,followee_id,created_at,updated_at) values ('01930000-0000-7000-8000-00000000a001','01930000-0000-7000-8000-00000000a001',1,1);"
denies "blocking yourself"         "insert into blocks (blocker_id,blocked_id,created_at) values ('01930000-0000-7000-8000-00000000a001','01930000-0000-7000-8000-00000000a001',1);"
denies "one Apple subject, two accounts" \
  "insert into auth_identities (id,account_id,provider,provider_subject,created_at) values ('x','01930000-0000-7000-8000-00000000a001','apple','000123.seedgabi.0002',1);"
denies "one APNs token, two accounts" \
  "insert into devices (id,account_id,apns_token,environment,created_at,last_seen_at) values ('d1','01930000-0000-7000-8000-00000000a001','tok-1','sandbox',1,1), ('d2','01930000-0000-7000-8000-00000000b001','tok-1','sandbox',1,1);"

echo
echo "Safety"
denies "reporting the same post twice" \
  "insert into reports (id,reporter_id,subject_type,subject_id,category,created_at) values ('r1','01930000-0000-7000-8000-00000000a001','post','01930000-0000-7000-8000-00000000c002','spam',1), ('r2','01930000-0000-7000-8000-00000000a001','post','01930000-0000-7000-8000-00000000c002','harassment',1);"
denies "two open cases for one subject" \
  "insert into moderation_cases (id,subject_type,subject_id,created_at,updated_at) values ('m1','post','01930000-0000-7000-8000-00000000c002',1,1), ('m2','post','01930000-0000-7000-8000-00000000c002',1,1);"
denies "two pending deletion requests" \
  "insert into deletion_requests (id,account_id,requested_at,scheduled_for) values ('x1','01930000-0000-7000-8000-00000000a001',1,2), ('x2','01930000-0000-7000-8000-00000000a001',1,2);"
denies "unknown report category" \
  "insert into reports (id,reporter_id,subject_type,subject_id,category,created_at) values ('r3','01930000-0000-7000-8000-00000000a001','post','01930000-0000-7000-8000-00000000c001','vibes',1);"

echo
echo "Query paths"
equals "Connor's journal holds 4 entries" \
  "select count(*) from post_authorship where owner_id='01930000-0000-7000-8000-00000000a001';" "4"
equals "the private entry is Connor's alone" \
  "select count(*) from posts p join post_authorship a on a.post_id=p.id where p.visibility='private' and a.owner_id='01930000-0000-7000-8000-00000000a001';" "1"
equals "public feed excludes private entries" \
  "select count(*) from posts where visibility='public' and status in ('active','answered');" "4"
equals "Gabi is owed closure on a prayer she joined" \
  "select count(*) from notification_events where recipient_id='01930000-0000-7000-8000-00000000b001' and type='answered' and state='pending';" "1"
equals "the journal timeline uses its covering index" \
  "select 1 from (select * from pragma_index_list('post_authorship')) where name='post_authorship_journal';" "1"

echo
echo "Cascade behaviour"
equals "deleting an account erases its authorship rows" \
  "delete from accounts where id='01930000-0000-7000-8000-00000000b001'; select count(*) from post_authorship where owner_id='01930000-0000-7000-8000-00000000b001';" "0"
equals "and orphans nothing" "select count(*) from pragma_foreign_key_check;" "0"

echo
TABLES="$(sqlite3 "$DB" "select count(*) from sqlite_master where type='table' and name not like 'sqlite_%';")"
INDEXES="$(sqlite3 "$DB" "select count(*) from sqlite_master where type='index' and name not like 'sqlite_%';")"
echo "Schema: $TABLES tables, $INDEXES explicit indexes"
echo "Checks: $PASS passed, $FAIL failed"
rm -rf "$(dirname "$DB")"
[[ $FAIL -eq 0 ]] || exit 1
