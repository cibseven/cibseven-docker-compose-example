#!/bin/bash
# One-off job: seeds OpenLDAP with the OUs, the admin user and its group.
# Idempotent – does nothing if ou=people already exists.
set -euo pipefail

BIND_DN="cn=admin,${LDAP_BASE_DN}"
ldap() { "$@" -x -H "${LDAP_URL}" -D "${BIND_DN}" -w "${LDAP_ADMIN_PASSWORD}"; }

echo "Waiting for ${LDAP_URL} ..."
for _ in $(seq 1 60); do
  if ldap ldapsearch -b "${LDAP_BASE_DN}" -s base dn >/dev/null 2>&1; then break; fi
  sleep 2
done

if ldap ldapsearch -b "ou=people,${LDAP_BASE_DN}" -s base dn >/dev/null 2>&1; then
  echo "LDAP already seeded – nothing to do."
  exit 0
fi

CIBADMIN_HASH=$(slappasswd -h '{SSHA}' -s "${LDAP_USER_CIBADMIN_PASSWORD}")

sed -e "s|@BASE_DN@|${LDAP_BASE_DN}|g" \
    -e "s|@CIBADMIN_PASSWORD_HASH@|${CIBADMIN_HASH}|g" \
    /seed/seed.ldif.tmpl > /tmp/seed.ldif

ldap ldapadd -f /tmp/seed.ldif
rm -f /tmp/seed.ldif
echo "LDAP seeded: user cibadmin (group camunda-admin)."
