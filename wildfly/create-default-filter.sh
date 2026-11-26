#!/bin/sh
# One-off job for the WildFly variants: creates the task filter "$FILTER_NAME" (default
# "All tasks") – the equivalent of camunda.bpm.filter.create of CIB seven Run, which only
# exists in the Spring Boot distribution.
#
# Runs in a postgres container against the engine database (PG* environment variables).
# Waits until the engine has created its tables on first start, then inserts the filter
# unless a task filter with that name already exists. Same row as Run creates: a task
# filter with an empty query ({}) and no owner.
set -eu

FILTER_NAME="${FILTER_NAME:-All tasks}"

echo "Waiting for the engine table act_ru_filter ..."
i=0
until [ "$(psql -tAc "select to_regclass('public.act_ru_filter') is not null" 2>/dev/null)" = "t" ]; do
  i=$((i + 1))
  if [ "$i" -gt 180 ]; then
    echo "act_ru_filter did not appear within 15 minutes – is cibseven running?"
    exit 1
  fi
  sleep 5
done

psql -v ON_ERROR_STOP=1 -v name="$FILTER_NAME" <<'SQL'
INSERT INTO act_ru_filter (id_, rev_, resource_type_, name_, owner_, query_, properties_)
SELECT gen_random_uuid()::text, 1, 'Task', :'name', NULL, '{}', '{}'
WHERE NOT EXISTS (
  SELECT 1 FROM act_ru_filter WHERE resource_type_ = 'Task' AND name_ = :'name'
);
SQL
echo "Task filter \"$FILTER_NAME\" present."
