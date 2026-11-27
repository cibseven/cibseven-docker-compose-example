#!/bin/sh
# One-off job for the WildFly variant with internal user management: creates the initial
# admin user – the equivalent of camunda.bpm.admin-user of CIB seven Run, which only exists
# in the Spring Boot distribution.
#
# Runs in a postgres container against the engine database (PG* environment variables),
# after cibseven is healthy (so the engine and the invoice example have finished their own
# setup). Creates – each only if missing – the group camunda-admin (its permissions come from
# the AdministratorAuthorizationPlugin in standalone.xml), the user and the membership.
#
# The password is stored exactly like the engine does it: "{SHA-512}" + Base64(SHA-512(
# password + salt)), salt = Base64 of 16 random bytes. The engine's password policy is NOT
# checked here – choose a strong password. An existing user is never changed.
set -eu

: "${ADMIN_ID:?ADMIN_ID missing}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD missing}"

echo "Waiting for the engine table act_id_user ..."
i=0
until [ "$(psql -tAc "select to_regclass('public.act_id_user') is not null" 2>/dev/null)" = "t" ]; do
  i=$((i + 1))
  if [ "$i" -gt 180 ]; then
    echo "act_id_user did not appear within 15 minutes – is cibseven running?"
    exit 1
  fi
  sleep 5
done

psql -v ON_ERROR_STOP=1 \
  -v id="$ADMIN_ID" -v pw="$ADMIN_PASSWORD" \
  -v first="${ADMIN_FIRST_NAME:-CIB}" -v last="${ADMIN_LAST_NAME:-Admin}" \
  -v email="${ADMIN_EMAIL:-}" <<'SQL'
BEGIN;

INSERT INTO act_id_group (id_, rev_, name_, type_)
SELECT 'camunda-admin', 1, 'camunda BPM Administrators', 'SYSTEM'
WHERE NOT EXISTS (SELECT 1 FROM act_id_group WHERE id_ = 'camunda-admin');

WITH s AS (SELECT encode(uuid_send(gen_random_uuid()), 'base64') AS salt)
INSERT INTO act_id_user (id_, rev_, first_, last_, email_, pwd_, salt_, attempts_)
SELECT :'id', 1, :'first', :'last', NULLIF(:'email', ''),
       '{SHA-512}' || replace(encode(sha512(convert_to(:'pw' || s.salt, 'UTF8')), 'base64'), E'\n', ''),
       s.salt, 0
FROM s
WHERE NOT EXISTS (SELECT 1 FROM act_id_user WHERE id_ = :'id');

INSERT INTO act_id_membership (user_id_, group_id_)
SELECT :'id', 'camunda-admin'
WHERE NOT EXISTS (SELECT 1 FROM act_id_membership WHERE user_id_ = :'id' AND group_id_ = 'camunda-admin');

COMMIT;
SQL
echo "Admin user \"$ADMIN_ID\" present (group camunda-admin)."
