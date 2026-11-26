#!/usr/bin/env bash
# Downloads the cibseven-keycloak identity provider plugin (Run variant) from Maven Central
# into this directory and verifies its SHA-1 checksum.
#   ./fetch-plugin.sh            -> version 2.2.1
#   ./fetch-plugin.sh 2.3.0      -> another version (also set KEYCLOAK_PLUGIN_VERSION in .env)
set -euo pipefail

VERSION="${1:-2.2.1}"
DIR="$(cd "$(dirname "$0")" && pwd)"
JAR="cibseven-keycloak-run-${VERSION}.jar"
URL="https://repo1.maven.org/maven2/org/cibseven/community/keycloak/cibseven-keycloak-run/${VERSION}/${JAR}"

echo "Downloading ${URL}"
curl -fsSL -o "${DIR}/${JAR}" "${URL}"
EXPECTED="$(curl -fsSL "${URL}.sha1" | cut -d' ' -f1)"
echo "${EXPECTED}  ${DIR}/${JAR}" | sha1sum -c -
