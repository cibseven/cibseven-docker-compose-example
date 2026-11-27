#!/bin/bash
# One-off job: seeds OpenLDAP with the OUs, the admin user and its group.
# Idempotent – entries that already exist are skipped (podman-compose may start this
# container a second time). Succeeds only if the admin user and its group exist afterwards.
set -euo pipefail

BIND_DN="cn=admin,${LDAP_BASE_DN}"
# Connection options go BEFORE the command's own arguments: the ldap tools of the Alpine based
# image don't accept options after positional arguments (e.g. the attribute list of ldapsearch).
ldap() { local cmd=$1; shift; "$cmd" -x -H "${LDAP_URL}" -D "${BIND_DN}" -w "${LDAP_ADMIN_PASSWORD}" "$@"; }

echo "Waiting for ${LDAP_URL} ..."
for _ in $(seq 1 60); do
  if ldap ldapsearch -b "${LDAP_BASE_DN}" -s base dn >/dev/null 2>&1; then break; fi
  sleep 2
done

if ldap ldapsearch -b "ou=people,${LDAP_BASE_DN}" -s base dn >/dev/null 2>&1; then
  echo "LDAP already seeded – nothing to do."
  exit 0
fi

ADMIN_HASH=$(slappasswd -h '{SSHA}' -s "${CIBSEVEN_ADMIN_PASSWORD}")

sed -e "s|@BASE_DN@|${LDAP_BASE_DN}|g" \
    -e "s|@ADMIN_ID@|${CIBSEVEN_ADMIN_USER}|g" \
    -e "s|@ADMIN_PASSWORD_HASH@|${ADMIN_HASH}|g" \
    /seed/seed.ldif.tmpl > /tmp/seed.ldif

# -c: continue on errors, so entries that already exist ("Already exists (68)") are skipped
ldap ldapadd -c -f /tmp/seed.ldif || true
rm -f /tmp/seed.ldif

for dn in "uid=${CIBSEVEN_ADMIN_USER},ou=people,${LDAP_BASE_DN}" "cn=camunda-admin,ou=groups,${LDAP_BASE_DN}"; do
  if ! ldap ldapsearch -b "$dn" -s base dn >/dev/null 2>&1; then
    echo "Seeding failed: $dn does not exist."
    exit 1
  fi
done
echo "LDAP seeded: user ${CIBSEVEN_ADMIN_USER} (group camunda-admin)."
