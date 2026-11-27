# =============================================================================
# CIB seven 3.0.0 EE on WildFly – production configuration
#
# Built by keycloak/docker-compose.wildfly.yml and openldap/docker-compose.wildfly.yml.
#   IDENTITY_PROVIDER=ldap      LDAP identity provider plugin (module ships with the image)
#   IDENTITY_PROVIDER=keycloak  cibseven-keycloak plugin, installed as a WildFly module
#   IDENTITY_PROVIDER=internal  CIB seven's own user management (engine database), no plugin
#
# What the build changes compared to the stock image:
#   1. Engine REST API: pseudo authentication (user name from a request header, "not for
#      production") replaced by webclient tokens only (JwtTokenAuthenticationProvider).
#      engine-rest is deployed exploded for that, with its web.xml patched.
#   2. Welcome app removed.
#   3. standalone.xml: password policy, deserialization type validation, admin permissions
#      for camunda-admin, identity provider plugin (ldap/keycloak). Secrets are ${env.*} expressions that
#      WildFly resolves at runtime – nothing secret is baked into the image.
#
# Base image needs: docker login enterprise.artifacts.cibseven.org
# =============================================================================
ARG CIBSEVEN_WILDFLY_IMAGE=enterprise.artifacts.cibseven.org/cibseven:wildfly-3.0.0-ee
FROM ${CIBSEVEN_WILDFLY_IMAGE}

ARG IDENTITY_PROVIDER
ARG KEYCLOAK_PLUGIN_VERSION=2.2.1

COPY --chown=camunda:camunda cli/ /tmp/cli/
COPY --chown=camunda:camunda keycloak-module.xml /tmp/keycloak-module.xml

WORKDIR /camunda

RUN set -eu; \
    case "${IDENTITY_PROVIDER:-}" in ldap|keycloak|internal) ;; \
      *) echo "Build arg IDENTITY_PROVIDER must be 'ldap', 'keycloak' or 'internal'"; exit 1 ;; esac; \
    \
    # --- 1. Engine REST API: webclient tokens only ----------------------------------
    WAR=$(ls standalone/deployments/cibseven-engine-rest-*.war); \
    mkdir /tmp/engine-rest; unzip -q "$WAR" -d /tmp/engine-rest; rm "$WAR"; mv /tmp/engine-rest "$WAR"; \
    WEBXML="$WAR/WEB-INF/web.xml"; \
    sed -i \
      -e 's|org.cibseven.bpm.engine.rest.security.auth.impl.PseudoAuthenticationProvider|org.cibseven.bpm.engine.rest.security.auth.impl.JwtTokenAuthenticationProvider|' \
      -e 's|cibseven-pseudo-auth|cibseven-jwt-auth|g' \
      -e 's|Pseudo Authentication Filter through custom header (not for production)|JWT authentication: only tokens issued by the CIB seven webclient (patched by wildfly/Dockerfile)|' \
      "$WEBXML"; \
    if grep -q 'PseudoAuthenticationProvider' "$WEBXML" || ! grep -q 'impl.JwtTokenAuthenticationProvider' "$WEBXML"; then \
      echo "Patching engine-rest web.xml failed"; exit 1; fi; \
    touch "$WAR.dodeploy"; \
    \
    # --- 2. No welcome app ---------------------------------------------------------
    # (cibseven-welcome.war is an exploded directory in the image)
    rm -rf /camunda/standalone/deployments/cibseven-welcome.war /camunda/standalone/deployments/cibseven-welcome.war.dodeploy; \
    \
    # --- 3. Keycloak plugin module (keycloak only) ----------------------------------
    if [ "$IDENTITY_PROVIDER" = keycloak ]; then \
      MOD=modules/org/cibseven/bpm/identity/cibseven-identity-keycloak/main; \
      JAR="cibseven-keycloak-all-${KEYCLOAK_PLUGIN_VERSION}.jar"; \
      URL="https://repo1.maven.org/maven2/org/cibseven/community/keycloak/cibseven-keycloak-all/${KEYCLOAK_PLUGIN_VERSION}/${JAR}"; \
      mkdir -p "$MOD"; \
      curl -fsSL -o "$MOD/$JAR" "$URL"; \
      echo "$(curl -fsSL "$URL.sha1" | cut -d' ' -f1)  $MOD/$JAR" | sha1sum -c -; \
      sed "s|@VERSION@|${KEYCLOAK_PLUGIN_VERSION}|" /tmp/keycloak-module.xml > "$MOD/module.xml"; \
      SUB=modules/org/cibseven/bpm/wildfly/cibseven-wildfly-subsystem/main/module.xml; \
      sed -i '/name="org.cibseven.bpm.identity.cibseven-identity-ldap"/a\    <module name="org.cibseven.bpm.identity.cibseven-identity-keycloak" />' "$SUB"; \
      grep -q 'cibseven-identity-keycloak' "$SUB" || { echo "Adding the keycloak module dependency failed"; exit 1; }; \
    fi; \
    \
    # --- 4. standalone.xml ----------------------------------------------------------
    bin/jboss-cli.sh --file=/tmp/cli/common.cli; \
    if [ "$IDENTITY_PROVIDER" != internal ]; then bin/jboss-cli.sh --file="/tmp/cli/${IDENTITY_PROVIDER}.cli"; fi; \
    rm -rf standalone/configuration/standalone_xml_history/current/* /tmp/cli /tmp/keycloak-module.xml
