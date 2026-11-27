#!/bin/sh
# One-off job for the internal setup (Run and WildFly): protects the demo users of the invoice
# example. With CIB seven's own (writable) user management the example creates demo/demo,
# john/john, mary/mary and peter/peter – password = user name, demo is in camunda-admin.
#
# Runs in a postgres container against the engine database (PG* environment variables),
# after cibseven is healthy (the example has created its data by then). It
#   - replaces the password of each demo user that still has its default password with a
#     random one that is never stored or shown (the account can't be used until an admin sets
#     a new password in the webclient),
#   - removes demo from the group camunda-admin.
# The users themselves stay: deleting demo would make the example recreate all of them on the
# next start. Passwords that were already changed are left alone. Safe to run repeatedly.
set -eu

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

psql -v ON_ERROR_STOP=1 -tA <<'SQL'
BEGIN;

-- Demo users that still have password = user id (same hash scheme as the engine:
-- "{SHA-512}" + Base64(SHA-512(password + salt)))
WITH d AS (
  SELECT id_,
         encode(uuid_send(gen_random_uuid()), 'base64') AS salt,
         encode(uuid_send(gen_random_uuid()), 'hex') || encode(uuid_send(gen_random_uuid()), 'hex') AS pw
  FROM act_id_user
  WHERE id_ IN ('demo', 'john', 'mary', 'peter')
    AND pwd_ = '{SHA-512}' || replace(encode(sha512(convert_to(id_ || coalesce(salt_, ''), 'UTF8')), 'base64'), E'\n', '')
)
UPDATE act_id_user u
SET salt_ = d.salt,
    pwd_  = '{SHA-512}' || replace(encode(sha512(convert_to(d.pw || d.salt, 'UTF8')), 'base64'), E'\n', ''),
    rev_  = u.rev_ + 1
FROM d
WHERE u.id_ = d.id_;

DELETE FROM act_id_membership WHERE user_id_ = 'demo' AND group_id_ = 'camunda-admin';

COMMIT;
SQL
echo "Demo users protected: default passwords replaced, demo is no member of camunda-admin."
