# CIB seven Run 3.0.0 EE – Docker Compose setups (Keycloak & OpenLDAP)

Two self-contained Docker Compose setups for **CIB seven 3.0.0 enterprise edition** in
**production configuration**, including the **invoice example**:

- **`keycloak/`**: Keycloak as the OAuth2 / OIDC identity provider (SSO for the webclient, JWT-secured engine REST API), users and groups read-only via the cibseven-keycloak plugin
- **`openldap/`**: OpenLDAP as the user and group directory (engine LDAP identity provider plugin)

Each setup comes in two variants:

- **Run** (`docker-compose.yml`): CIB seven Run, `enterprise.artifacts.cibseven.org/cibseven:run-3.0.0-ee`
- **WildFly** (`docker-compose.wildfly.yml`): CIB seven on WildFly, built from
  `enterprise.artifacts.cibseven.org/cibseven:wildfly-3.0.0-ee`. See [WildFly variant](#wildfly-variant)

The **AI agent connector** is switched on in both setups. Each setup has exactly **one user**,
the admin `cibadmin`.

There are no secrets in the repository. All passwords, client secrets and the LLM API key come
from a local `.env` file, which is git-ignored.

> **This is a test environment.** The [security section](#security) separates two things:
> **explicit decisions for this environment**, i.e. things deliberately kept or switched on here,
> and **general production hardening** that any real production system needs on top. Work
> through both lists before using any part of this setup beyond a local test.

```
cibseven-compose/
├── README.md                        this document
├── .gitignore                       excludes .env and downloaded plugin jars
├── keycloak/                        Setup A: OAuth2 / SSO with Keycloak
│   ├── docker-compose.yml           Run variant
│   ├── docker-compose.wildfly.yml   WildFly variant
│   ├── env.example                  template for .env (shared by both variants)
│   ├── cibseven/application.yaml    Run: CIB seven overrides (OAuth2, SSO, Keycloak plugin, example)
│   ├── cibseven/cibseven-webclient-wildfly.yaml  WildFly: webclient SSO configuration
│   ├── keycloak/realm-cibseven.json realm, clients, admin group, admin user
│   └── plugin/fetch-plugin.sh       Run: downloads the cibseven-keycloak plugin jar
├── openldap/                        Setup B: LDAP with OpenLDAP
│   ├── docker-compose.yml           Run variant
│   ├── docker-compose.wildfly.yml   WildFly variant
│   ├── env.example                  template for .env (shared by both variants)
│   ├── cibseven/application.yaml    Run: CIB seven overrides (LDAP plugin, example)
│   ├── cibseven/cibseven-webclient-wildfly.yaml  WildFly: webclient configuration
│   └── ldap/seed.sh, seed.ldif.tmpl admin user and admin group
└── wildfly/                         WildFly image build, shared by both setups
    ├── Dockerfile                   production changes on top of the EE WildFly image
    ├── cli/*.cli                    standalone.xml changes (engine, LDAP / Keycloak plugin)
    ├── keycloak-module.xml          WildFly module for the Keycloak plugin
    └── create-default-filter.sh     one-off job: task filter "All tasks"
```

All variants use port 8080, so run only one at a time (or change `CIBSEVEN_PORT`).

---

## What "production configuration" means here

| Topic | Implementation |
|---|---|
| `production.yml` instead of `default.yml` | Started with `--production`: no `demo/demo` admin from the config, authorization enabled, password policy, deserialization type validation, WADL disabled |
| Invoice example | Kept: `--example` plus `camunda.bpm.run.example.enabled: true` (the production config does not enable it on its own). See [The invoice example](#the-invoice-example) |
| Default task filter | `camunda.bpm.filter.create: All tasks` creates the filter "All tasks" on first start (`production.yml` doesn't). See [Default task filter](#default-task-filter) |
| Database | PostgreSQL 17 instead of H2 (separate database per service, persistent volumes) |
| Secrets | Only via `.env` / environment variables; config files contain `${...}` placeholders only |
| Users and admin permissions | One user, `cibadmin`, managed in Keycloak or LDAP (read-only in CIB seven). Group `camunda-admin` gets all permissions via `camunda.bpm.run.admin-auth` |
| Engine REST API | Keycloak: only valid Keycloak JWTs (signature, issuer and audience checked). LDAP: webclient JWT or HTTP Basic, checked against LDAP |
| AI agent | **On** (`AI_AGENT_ENABLED=true`; `--production` alone would switch it off). LLM API key only in `.env` (`OPENAI_API_KEY`), never in BPMN. See [AI agent](#ai-agent) |
| MCP REST API (`/mcp`) | Off (`MCP_ENABLED=false`) |
| Webclient modeler | **On** in both variants. Run: `cibseven.webclient.modeler.enabled: true` plus the element template paths in `cibseven/application.yaml` (`production.yml` leaves it off). WildFly: on by default in the webclient's own configuration |
| Keycloak | Production mode `start` with PostgreSQL (not `start-dev`) |
| Health checks | On every service. CIB seven only starts once its database and identity provider are ready |

---

## Prerequisites

- Docker with Compose v2 (`docker compose`) or Podman with `podman-compose` ≥ 1.1
- Access to the CIB seven enterprise registry:

```bash
docker login enterprise.artifacts.cibseven.org
```

- Free ports: 8080 (CIB seven), 8180 (Keycloak) or 1389 (LDAP, optional)
- About 3 GB RAM for the Keycloak setup

Images: `enterprise.artifacts.cibseven.org/cibseven:run-3.0.0-ee` (override with `CIBSEVEN_IMAGE` in `.env`),
`enterprise.artifacts.cibseven.org/cibseven:wildfly-3.0.0-ee` (WildFly variant, `CIBSEVEN_WILDFLY_IMAGE`),
`quay.io/keycloak/keycloak:26.7.5`, `postgres:17-alpine`, `osixia/openldap:2.6.15`.

The sections below describe the Run variant; the [WildFly variant](#wildfly-variant) section lists what differs.

---

## Setup A – Keycloak (OAuth2 / OIDC)

### Architecture

```
Browser ──(1) /webapp ──────────────────────────────▶ cibseven :8080
   │                                                     │
   └─(2) login redirect ─▶ keycloak :8180 (public URL)    │ (3) code exchange, userinfo, JWKS
                                                         └──▶ keycloak:8080 (internal URL)
cibseven webclient ──(4) Keycloak access token ──▶ /engine-rest (Spring Security resource server)
engine ──(5) cibseven-keycloak plugin, service account ──▶ keycloak:8080 admin API (read users/groups)
```

- **Webclient** (`/webapp`): `OAuth2UserProvider`, authorization code flow with the confidential
  client `cibseven-webclient`.
- **Engine REST API** (`/engine-rest`): `--oauth2` turns it into an OAuth2 resource server. The
  webclient forwards the user's Keycloak token (`accessTokenToEngineRest: true`). Signature (JWKS),
  issuer and audience `cibseven-engine-rest` are validated.
- **Identity**: the [cibseven-keycloak plugin](https://github.com/cibseven-community-hub/cibseven-keycloak)
  (`cibseven-keycloak-run`), a **read-only** identity provider. The engine reads users and groups
  live from the Keycloak admin API, using the service account client `cibseven-identity`. That
  client only has the realm-management roles `query-users`, `view-users` and `query-groups`.
  User id = Keycloak username (`useUsernameAsCamundaUserId`), group id = group path without the
  leading `/`, e.g. `camunda-admin` (`useGroupPathAsCamundaGroupId`). The built-in OAuth2 identity
  provider is switched off (`camunda.bpm.oauth2.identity-provider.enabled: false`); it would be
  writable, because it is backed by the engine's own user tables.
- **Realm `cibseven`**: clients `cibseven-webclient` (login) and `cibseven-identity` (plugin), group
  `camunda-admin`, user `cibadmin`. No client allows the password grant.
- **Two Keycloak URLs**: the browser uses `KEYCLOAK_PUBLIC_URL` (`http://localhost:8180`), the
  container uses `http://keycloak:8080`. Keycloak runs with `KC_HOSTNAME=<public URL>`, so the
  issuer is the same in every token, whichever way it was fetched.

### Start

```bash
cd keycloak
cp env.example .env
```

Replace every `change-me` in `.env` with your own value (e.g. `openssl rand -base64 24`).

Download the plugin jar into `plugin/` (from Maven Central, SHA-1 is checked). The compose file
mounts it into `/camunda/configuration/userlib/`:

```bash
./plugin/fetch-plugin.sh
```

Then start:

```bash
docker compose up -d
```

```bash
docker compose ps
```

The first start takes 1–2 minutes: Keycloak builds itself in production mode, then imports the
realm. The stack is ready when every service is `healthy`.

### Test

| What | URL / login |
|---|---|
| CIB seven webclient | http://localhost:8080/webapp/ (redirects to Keycloak) |
| Admin user | `cibadmin` / `KC_USER_CIBADMIN_PASSWORD`, group `camunda-admin`, all permissions |
| Keycloak admin console | http://localhost:8180/admin/, `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` |

Log in to the webclient as `cibadmin`. Expected: *Admin → Users* lists `cibadmin`, *Admin → Groups*
lists `camunda-admin`, and the invoice processes are deployed. The engine REST API rejects requests
without a Keycloak token:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/engine-rest/user
```

Expected: `401`.

### Notes and limitations

- **Plugin version:** there is no cibseven-keycloak release built for CIB seven 3.0 yet. The setup
  uses **2.2.1**, the latest release (built against CIB seven 2.2), which works with 3.0.0. Switch
  to a 3.0 release once available: set `KEYCLOAK_PLUGIN_VERSION` in `.env` and run
  `./plugin/fetch-plugin.sh <version>`.
- **Users and groups are read-only** in CIB seven. Manage them in Keycloak. *Admin → Users/Groups*
  in the webclient lists all of them.
- The plugin caches query results for 5 minutes (`cacheExpirationTimeoutMin`), so group changes in
  Keycloak can take that long to show up in CIB seven.
- The realm is only imported if it does not exist yet. Changes to `realm-cibseven.json` take
  effect after `docker compose down -v` (deletes all data) or by editing the realm in the admin console.

---

## Setup B – OpenLDAP

### Architecture

```
Browser ─▶ cibseven :8080 /webapp ── login ─▶ engine identity service ─▶ LDAP plugin ─▶ openldap:3890
REST client ─▶ /engine-rest (HTTP Basic, password checked by an LDAP bind)
```

- **OpenLDAP 2.6** (`osixia/openldap:2.6.15`). The image only accepts pre-hashed passwords, so the
  container's start command hashes the plain passwords from `.env` (`{SSHA}`) and hands them to
  the image's bootstrap. The bootstrap only runs once, on empty volumes. It creates the root DN
  `cn=admin,dc=cibseven,dc=local` and the read-only account `cn=readonly,dc=cibseven,dc=local`.
- **Engine LDAP identity provider plugin** (`camunda.bpm.run.ldap`), read-only. CIB seven searches
  as `cn=readonly,dc=cibseven,dc=local` (read access only) and checks passwords by binding as the
  user's DN.
- **Webclient**: default `SevenUserProvider`. Logins go through the engine and therefore through LDAP.
- **Engine REST API**: `composite` authentication from `production.yml` (webclient JWT or HTTP Basic).
- **Directory layout** (created by the one-off job `ldap-seed` as `cn=admin`; passwords stored as SSHA hashes):

```
dc=cibseven,dc=local
├── ou=people   uid=cibadmin                       (inetOrgPerson)
└── ou=groups   cn=camunda-admin  member: cibadmin   (groupOfNames)
```

### Start

```bash
cd openldap
cp env.example .env
```

Replace every `change-me` in `.env`, then:

```bash
docker compose up -d
```

```bash
docker compose ps
```

`ldap-seed` ends with `Exited (0)`; every other service is `healthy`.

Coming from the earlier `osixia/openldap:1.5.0` version of this setup? The v2 image can't use the
old LDAP volumes (different paths and format). Start fresh with `docker compose down -v`.

### Test

| What | URL / login |
|---|---|
| CIB seven webclient | http://localhost:8080/webapp/ (login form) |
| Admin user | `cibadmin` / `LDAP_USER_CIBADMIN_PASSWORD`, group `camunda-admin`, all permissions |
| LDAP from the host | `ldap://localhost:1389` (container port 3890), bind DN `cn=admin,dc=cibseven,dc=local` / `LDAP_ADMIN_PASSWORD` |

```bash
source .env
curl -s -u "cibadmin:$LDAP_USER_CIBADMIN_PASSWORD" http://localhost:8080/engine-rest/user
curl -s -u "cibadmin:$LDAP_USER_CIBADMIN_PASSWORD" "http://localhost:8080/engine-rest/process-definition?key=invoice"
```

Expected: the LDAP user `cibadmin` and the invoice process definitions. A missing or wrong
password returns `401`, and `demo/demo` does not exist.

Query LDAP directly from inside the container:

```bash
docker compose exec openldap ldapsearch -x -H ldap://localhost:3890 -D cn=readonly,dc=cibseven,dc=local -w "$LDAP_READONLY_PASSWORD" -b dc=cibseven,dc=local "(objectClass=inetOrgPerson)" uid mail
```

### Notes and limitations

- Users and groups are **read-only** in CIB seven. Manage them in LDAP (e.g. Apache Directory Studio on port 1389).
- More users: extend `ldap/seed.ldif.tmpl` and recreate with `docker compose down -v`, or add
  them directly with `ldapadd` as `cn=admin`.
- The `LDAP_ADMIN_PASSWORD`, `LDAP_CONFIG_PASSWORD` and `LDAP_READONLY_PASSWORD` values are only
  applied by the first bootstrap. Changing them in `.env` later has no effect until `docker compose down -v`.
- Connecting your own LDAP / Active Directory: change `LDAP_URL`, `LDAP_BASE_DN` and
  `LDAP_MANAGER_DN` in `docker-compose.yml` and the search/attribute settings in
  `cibseven/application.yaml` (AD: e.g. `user-id-attribute: sAMAccountName`,
  `user-search-filter: (objectclass=person)`).

---

## WildFly variant

Both setups also run on **CIB seven WildFly EE**. Keycloak, the realm, OpenLDAP, the seed job,
the database and `.env` are the same; only the `cibseven` service differs.

```bash
docker compose -f docker-compose.wildfly.yml up -d --build
```

Run it from `keycloak/` or `openldap/`. Every `docker compose` command for this variant needs
`-f docker-compose.wildfly.yml` (e.g. `logs`, `down -v`). The variant has its **own project name**
(`cibseven-keycloak-wildfly`, `cibseven-openldap-wildfly`), so its containers and volumes are
separate from the Run variant: the Keycloak realm and LDAP are bootstrapped again, and the engine
database doesn't mix Run and WildFly deployments. Stop the Run variant first, because both use the
same ports. Keycloak and LDAP service definitions are taken over from `docker-compose.yml` via
`extends`, so changes there apply to both variants.

### What is different from Run

WildFly has no Spring Boot. None of the Run configuration (`--production`, `application.yaml`)
applies, so the image is built from `wildfly/Dockerfile` on top of the EE WildFly image:

| Topic | Run | WildFly |
|---|---|---|
| Production settings | `--production` (`production.yml`) | `standalone.xml`, set at build time by `wildfly/cli/common.cli`: authorization (already on), password policy, deserialization type validation |
| Engine REST API | Keycloak JWTs (Keycloak setup) / webclient token or HTTP Basic (LDAP setup) | **Webclient tokens only**, in both setups. The stock image ships `PseudoAuthenticationProvider` (user name taken from a request header, "not for production"). The build replaces it with `JwtTokenAuthenticationProvider` in the `web.xml` of `engine-rest`, which is deployed exploded for that. No HTTP Basic, no Keycloak tokens: WildFly has no Spring Security resource server |
| Webclient | `application.yaml` | `cibseven/cibseven-webclient-wildfly.yaml`, mounted as `cibseven-webclient.yaml` into the global WildFly module `org.cibseven.config`. Keycloak setup: SSO as in Run, but `accessTokenToEngineRest: false`: the webclient talks to the REST API with its own token |
| Identity provider | `camunda.bpm.run.ldap` / plugin jar in `userlib` | Engine plugin in `standalone.xml` (`wildfly/cli/ldap.cli`, `keycloak.cli`). The Keycloak plugin is installed as WildFly module `org.cibseven.bpm.identity.cibseven-identity-keycloak` from `cibseven-keycloak-all` (Maven Central, SHA-1 checked at build time, version `KEYCLOAK_PLUGIN_VERSION`) |
| Secrets | `${...}` in `application.yaml` | `${env.*}` expressions in `standalone.xml`, resolved by WildFly at runtime. **Nothing secret is baked into the image** |
| Admin permissions (incl. user id `mary`) | `camunda.bpm.run.admin-auth` | `AdministratorAuthorizationPlugin` in `standalone.xml` |
| Invoice example | `--example` | Deployed by default (WAR in the image), same behaviour |
| Default task filter | `camunda.bpm.filter.create` | Not available outside Spring Boot. The one-off job `default-filter` inserts the same row (task filter "All tasks", empty query) into `act_ru_filter` once the engine has created its tables, if it doesn't exist yet (`wildfly/create-default-filter.sh`) |
| Welcome app | – | Removed |
| AI agent | `AI_AGENT_ENABLED`, `OPENAI_*` | Same environment variables |

Rebuild the image after changing anything in `wildfly/`:

```bash
docker compose -f docker-compose.wildfly.yml build cibseven
```

### Test

The URLs and the `cibadmin` login are the same as for Run. Differences:

- The REST API only accepts webclient tokens, so the `curl -u cibadmin:...` examples of the LDAP
  setup return `401` here. That is intended. Test through the webclient.
- `docker compose -f docker-compose.wildfly.yml ps` shows `default-filter` as `Exited (0)` once
  the filter exists.

---

## The invoice example

The example (`--example`) does the following on first start:

- **Deploys the invoice process twice, on purpose.** It demonstrates versioning: a first
  deployment with `invoice.v1.bpmn`, the decision table `invoiceBusinessDecisions.dmn` and
  `reviewInvoice.bpmn`, then its process application deployment with `invoice.v2.bpmn` and the
  decision table again. So you see "Invoice Receipt" in versions 1 and 2, and the decision table
  in versions 1 and 2. Restarts don't add versions, because unchanged resources are not redeployed.
- **Starts 3 instances per version** (6 in total), and moves some of them on, as described below.
- **Task permissions:** the engine automatically grants the candidate groups of the created user
  tasks (`accounting`, `sales`) read and update permissions on those tasks. These groups don't exist
  in Keycloak or LDAP here.
- **No demo users, groups, filters or group permissions.** The example only creates those
  (`demo/demo`, `john`, `mary`, `peter`, ...) when the identity service is writable. Keycloak (via the
  plugin) and LDAP are read-only in both setups, so that step is skipped.
- Serves static example resources under `/camunda-invoice/` and `/forms/`.

**The user id `mary`.** While starting the instances, the example completes one demo task as
user id `mary`, with no groups attached. That only works if `mary` has a permission on tasks
granted to her personally. The example normally creates it in its demo-data step, which is skipped
here. Without it, CIB seven fails at startup with a `NullPointerException` in `@PostDeploy`.
Therefore `admin-auth` grants all permissions to the user id `mary`
(`administrator-user-name: mary` in `cibseven/application.yaml`). **There is no user `mary`** in
Keycloak or LDAP, so nobody can log in with it (decision E3).

---

## Default task filter

Both setups create the task filter **"All tasks"** on engine start, unless a filter with that name
already exists:

```yaml
camunda:
  bpm:
    filter:
      create: All tasks
```

- The filter has no criteria: each user sees **every task they are allowed to read**. Task
  permissions still apply; the filter itself grants none.
- **Who sees the filter:** with authorization enabled, a filter is only listed for users with
  `READ` on it. `camunda-admin` has all permissions through `admin-auth`. Nobody else sees it until
  you grant access. The invoice example's own filters ("My Tasks", "Accounting", ...) are not
  created, see [The invoice example](#the-invoice-example).
- Renaming it later (`create: <other name>`) creates an additional filter; the old one stays.

When you add more users, grant them read access to this filter once, as `cibadmin`. Use the
webclient under *Admin → Authorizations → Filter* (both setups), or the REST API in the LDAP setup:

```bash
source .env
AUTH="cibadmin:$LDAP_USER_CIBADMIN_PASSWORD"
FILTER_ID=$(curl -s -u "$AUTH" "http://localhost:8080/engine-rest/filter?name=All%20tasks" | jq -r '.[0].id')
curl -s -u "$AUTH" -X POST http://localhost:8080/engine-rest/authorization/create \
  -H 'Content-Type: application/json' \
  -d "{\"type\":0,\"permissions\":[\"READ\"],\"userId\":\"*\",\"resourceType\":5,\"resourceId\":\"$FILTER_ID\"}"
```

`type 0` = global (all users), `resourceType 5` = filter. To limit it to a group, use `type 1` with
`"groupId":"<group>"` instead of `"userId":"*"`. The authorization is stored in the engine
database, so it survives restarts and works with read-only LDAP/Keycloak.

---

## AI agent

Both setups switch on the AI agent connector (BPMN element templates "AI Agent", "AI Agent (ad hoc
sub process)" and "Knowledge Ingestor" in the webclient modeler) with `AI_AGENT_ENABLED=true`.
The connector talks to any **OpenAI-compatible** API. It is configured only through `.env`:

| `.env` variable | Passed to CIB seven as | Meaning |
|---|---|---|
| `OPENAI_API_KEY` | `OPENAI_API_KEY` | API key of the LLM provider. **Required**; the stack won't start without it |
| `OPENAI_BASE_URL` | `OPENAI_BASE_URL` | Endpoint, default `https://api.openai.com/v1`. E.g. `https://openrouter.ai/api/v1`, or Ollama on the host: `http://host.containers.internal:11434/v1` (Podman) / `http://host.docker.internal:11434/v1` (Docker) |
| `AI_DEFAULT_MODEL` | `CIBSEVEN_CONNECT_AI_AGENT_DEFAULT_MODEL` | Model used when a task leaves "Model" empty (default `gpt-6-luna`) |

In the BPMN, leave the **API key** field of the AI agent task **empty**: the connector then uses
the server key from `.env`. Anything typed into that field is stored in plain text in the deployed
BPMN XML. The server key is only sent to `OPENAI_BASE_URL`. A task that points to a different
endpoint needs its own key.

After changing a value in `.env`, recreate the container (a plain restart keeps the old environment):

```bash
docker compose up -d cibseven
```

The MCP REST API (`/mcp`, exposes the engine REST API as MCP tools) stays off. To switch it on, set
`MCP_ENABLED: "true"` in `docker-compose.yml`. Read the MCP
[security notes](https://docs.cibseven.org/manual/latest/user-guide/mcp-restapi/#security) first.

---

## Security

### Explicit decisions for this environment

Things deliberately kept, switched on or simplified **for this environment**. Revisit each one
before reusing the setup elsewhere.

| # | Decision | Where | Risk | How to change |
|---|---|---|---|---|
| E1 | **Invoice example enabled** (`--example`, `camunda.bpm.run.example.enabled: true`) | `docker-compose.yml`, `cibseven/application.yaml` | Demo processes, decision tables and 6 instances with demo data; task permissions for the candidate groups `accounting`/`sales`; static resources under `/camunda-invoice/` and `/forms/`. Needs E3 | Remove `--example` and `camunda.bpm.run.example`, together with E3 |
| E2 | **AI agent switched on** (`AI_AGENT_ENABLED=true`, off by default under `--production`) | `docker-compose.yml` | Process data (variables, documents, prompts) is sent to an external LLM provider. Agents can call tools, e.g. start processes or ad hoc activities, with the engine permissions of the process | Set `AI_AGENT_ENABLED: "false"`; otherwise use an approved provider/endpoint and restrict which processes use agents |
| E3 | **All permissions for the user id `mary`** (`admin-auth.administrator-user-name: mary`), only so the invoice example can start (see [The invoice example](#the-invoice-example)). No such user exists | `cibseven/application.yaml` | If a user with the id `mary` is ever created in Keycloak or LDAP, they are a full admin immediately | Remove the line together with E1, then delete the `mary` entries under *Admin → Authorizations* (they stay in the DB) |
| E4 | **Single admin user `cibadmin`**, created by the realm import (Keycloak) or `ldap-seed` (LDAP), password from `.env` | `realm-cibseven.json`, `ldap/seed.ldif.tmpl` | A known account with full admin rights | Replace with real users and groups from your directory |
| E5 | **Webclient JWT secret generated per container start** (image default, not configured) | image default | Sessions are lost on every container restart; doesn't work with several CIB seven nodes | Set a fixed `cibseven.webclient.authentication.jwtSecret` from a secret store |
| E6 | **Swagger UI / OpenAPI of the webclient left on** (production default) | `/webapp/swagger-ui`, `/webapp/v3/api-docs` | Exposes the API description | `springdoc.api-docs.enabled=false`, `springdoc.swagger-ui.enabled=false` |
| E7 | **No container hardening** (default capabilities, writable root filesystem, no resource limits) | `docker-compose.yml` | Larger impact if a container is compromised; no protection against resource exhaustion | `read_only`, `cap_drop: [ALL]`, `security_opt: no-new-privileges`, memory/CPU limits |
| E8 | Keycloak: **no password policy in the realm** (the realm import fails if a password from `.env` violates it) | `realm-cibseven.json` | Weak passwords are accepted | Set a policy in the admin console (Authentication → Policies), e.g. `length(12) and notUsername and notEmail` |
| E9 | Keycloak: **admin console on the public port**, using the bootstrap admin from `.env` | `keycloak` service | Admin UI reachable from the network; Keycloak treats the bootstrap admin as temporary | Create a permanent admin, delete the bootstrap admin, restrict `/admin` at the proxy or use `KC_HOSTNAME_ADMIN` on a separate host |
| E10 | LDAP (Run): **HTTP Basic on the engine REST API** (`composite` auth from `production.yml`) | `production.yml` | Every REST call carries an LDAP password; without TLS (P1) in clear text | Prefer tokens for technical clients; TLS is mandatory (P1). The WildFly variant has no HTTP Basic |
| E11 | WildFly: **REST API accepts webclient tokens only** (patched `engine-rest` `web.xml`) | `wildfly/Dockerfile` | External REST clients (scripts, workers) can't authenticate; anyone holding the webclient JWT secret could issue tokens | Add an authentication scheme for technical clients if needed; keep the JWT secret secret (E5) |
| E12 | WildFly: **default filter written directly into the engine database** by the `default-filter` job | `wildfly/create-default-filter.sh` | Bypasses the engine API; relies on the `act_ru_filter` table layout of CIB seven 3.0 | Create filters through the webclient or REST API instead; check the job after engine upgrades |

### General production hardening

What any real production system needs on top, independent of the decisions above.

| # | Item | Where | Risk | Production fix |
|---|---|---|---|---|
| P1 | **No TLS for CIB seven.** Webclient and REST API are served over plain HTTP | `docker-compose.yml` (port 8080) | Tokens, session JWTs and (LDAP setup) Basic-auth passwords travel in clear text | Put a TLS-terminating reverse proxy in front, or set `server.ssl.*` |
| P2 | **Ports published on all host interfaces** (`0.0.0.0`) | `ports:` in `docker-compose.yml` | Anyone who can reach the host can reach CIB seven, Keycloak (incl. admin console) and LDAP | Bind to `127.0.0.1:` or publish only through the reverse proxy |
| P3 | **Database account is the PostgreSQL superuser.** `POSTGRES_USER` creates a superuser, and CIB seven/Keycloak use it | `cibseven-db`, `keycloak-db` | A compromised application owns the whole DB server | Separate owner and app accounts with minimal rights |
| P4 | **No TLS to PostgreSQL** | `DB_URL`, `KC_DB_URL` | Clear-text DB traffic (only on the internal Docker network here) | `sslmode=require/verify-full` on a managed or TLS-enabled DB |
| P5 | **Secrets in a plain `.env` file** | `.env` | Readable by anyone with access to the host directory; visible via `docker inspect` | Docker/Kubernetes secrets or a vault |
| P6 | **LLM API key as a plain environment variable** (`OPENAI_API_KEY`) | `.env`, `docker-compose.yml` | Visible via `docker inspect`. Readable by **every deployed process** (e.g. a Groovy script task can read `System.getenv`) | Secret store; a dedicated key with spending limits; only deploy trusted processes |
| P7 | **AI chat log and memory stored as process variables** (connector default) | engine DB / history | Prompts and LLM answers are kept in the database and visible in Cockpit to everyone with read access | `CIBSEVEN_CONNECT_AI_AGENT_REDACT_CONTENT=true` and/or `CIBSEVEN_CONNECT_AI_AGENT_CHAT_LOG_VARIABLE_ENABLED=false`; history cleanup |
| P8 | Keycloak: **plain HTTP** (`KC_HTTP_ENABLED=true`) | `keycloak` service | Login credentials, codes and tokens in clear text | TLS at Keycloak (`KC_HTTPS_*`) or a proxy (`KC_PROXY_HEADERS=xforwarded`), remove `KC_HTTP_ENABLED` |
| P9 | Keycloak: **realm `sslRequired: external`** | `realm-cibseven.json` | Allows HTTP from localhost and private IP ranges | `"sslRequired": "all"` |
| P10 | Keycloak: **identity plugin release built for CIB seven 2.2** (cibseven-keycloak-run 2.2.1) | `plugin/`, `KEYCLOAK_PLUGIN_VERSION` | Not maintained against 3.0; future 3.x changes or fixes are not covered | Use a plugin release built for CIB seven 3.0 as soon as one is available |
| P11 | Keycloak: **service account secret** of `cibseven-identity` in `.env` | `.env` | Anyone with the secret can read all users and groups of the realm | Secret store; rotate regularly; or use a signed-JWT client assertion |
| P12 | Keycloak: **no PKCE** on `cibseven-webclient` (the 3.0.0 webclient doesn't send a code challenge) | `realm-cibseven.json` | Less protection against intercepted authorization codes (mitigated by the confidential client secret) | Enable PKCE once the webclient supports it |
| P13 | LDAP: **no TLS** (`OPENLDAP_BOOTSTRAP_TLS=false`, `ldap://`) | `openldap` service, `LDAP_URL` | Bind passwords (read-only account and every user login) in clear text | `OPENLDAP_BOOTSTRAP_TLS=true` with a trusted certificate, `ldaps://…:6360` (`accept-untrusted-certificates` stays `false`) |
| P14 | LDAP: **port 1389 published** for debugging | `openldap` service | Directory reachable from the host network | Remove the `ports:` entry |
| P15 | LDAP: **no password policy / lockout** (ppolicy overlay off) | `openldap` service | No minimum length, lockout or expiry for LDAP passwords | `OPENLDAP_BOOTSTRAP_PPOLICY=true` and the `OPENLDAP_BOOTSTRAP_PPOLICY_DEFAULT_*` settings |
| P16 | WildFly: **management interface bound to all container interfaces** (stock start script), no management user | image default | Port 9990 is not published here; anyone inside the container network could reach it | Bind it to `127.0.0.1` (`-Djboss.bind.address.management`) or secure it with a management user |
| P17 | WildFly: **secrets as `${env.*}` expressions** in `standalone.xml` | `wildfly/cli/*.cli` | Values come from plain environment variables (see P5) | WildFly Elytron credential store or a vault |

---

## Accessing the setup from Windows (WSL2)

When Docker/Podman runs inside WSL2, Windows normally reaches the published ports through
`localhost` automatically (WSL "localhost forwarding"). Check that first in PowerShell on Windows:

```powershell
curl.exe -s http://localhost:8080/actuator/health
```

If that returns `{"status":"UP",...}`, open http://localhost:8080/webapp/ in the Windows browser.
No further steps are needed.

**If it does not work**, forward the ports manually. Run in an **elevated PowerShell** (Run as administrator):

```powershell
$wslIp = (wsl hostname -I).Trim().Split(" ")[0]
foreach ($port in 8080, 8180, 1389) {
  netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=$port connectaddress=$wslIp connectport=$port
}
netsh interface portproxy show v4tov4
```

- `listenaddress=127.0.0.1` makes the ports reachable from this Windows machine only, so no
  firewall rule is needed.
- The WSL IP changes after `wsl --shutdown` or a reboot. Remove the old rules and run the block again:

```powershell
foreach ($port in 8080, 8180, 1389) { netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$port }
```

- `portproxy` needs the Windows service "IP Helper" (`iphlpsvc`) to be running.
- Alternative (Windows 11 22H2+): mirrored networking. Add the following to
  `%UserProfile%\.wslconfig`, then run `wsl --shutdown`:

```ini
[wsl2]
networkingMode=mirrored
```

**Keycloak setup:** use exactly the URLs from `.env` in the browser (`http://localhost:8080` and
`http://localhost:8180`). If you open CIB seven by another host name or IP, set `CIBSEVEN_PUBLIC_URL`
and `KEYCLOAK_PUBLIC_URL` to those values *before the first start* (or run `docker compose down -v`).
Otherwise Keycloak rejects the redirect URI, or the engine rejects the token issuer.

Access from other machines on the network needs `listenaddress=0.0.0.0`, a Windows firewall rule
for the ports, and the public URLs set to the Windows host name. Don't do that without fixing the
TLS items (P1, P8, P13) first.

---

## Operations

```bash
docker compose logs -f cibseven
```

```bash
docker compose down
```

`docker compose down -v` also deletes all volumes (databases, LDAP data, Keycloak realm).

To change the configuration, edit `cibseven/application.yaml` and run `docker compose restart cibseven`.
The file is loaded via `SPRING_CONFIG_ADDITIONAL_LOCATION` on top of
`/camunda/configuration/production.yml` and overrides its values.

To get a first-start experience for CIB seven only (keeps Keycloak/LDAP), empty the engine database:

```bash
docker compose stop cibseven
```

```bash
docker compose exec cibseven-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"'
```

```bash
docker compose start cibseven
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `... missing in .env` on start | `.env` is missing or a variable is empty. Run `cp env.example .env` and fill it in |
| `OPENAI_API_KEY missing in .env` | AI agent is on and needs a key. Add `OPENAI_API_KEY` (see `env.example`) |
| AI agent task fails with 401/404 from the LLM | Wrong key, `OPENAI_BASE_URL` or model name. Changes in `.env` need `docker compose up -d cibseven` |
| Image pull fails with `unauthorized` | Run `docker login enterprise.artifacts.cibseven.org` (credentials expire) |
| Keycloak keeps restarting | `docker compose logs keycloak`. The realm import fails if a placeholder from `.env` is missing or a value is invalid |
| Keycloak: "Invalid parameter: redirect_uri" | `CIBSEVEN_PUBLIC_URL` doesn't match the browser URL. Re-import the realm (`down -v`) or fix the redirect URI in the admin console |
| Login OK, then 401 on `/engine-rest` | Issuer mismatch: `KEYCLOAK_PUBLIC_URL` must exactly match the browser URL, port included |
| Webclient shows no menus / "no permissions" | The user is not in `camunda-admin` and has no authorizations |
| CIB seven exits with `NullPointerException` in `@PostDeploy` | `administrator-user-name: mary` is missing under `admin-auth` (see [The invoice example](#the-invoice-example)). Then start again: `docker compose up -d` |
| Keycloak setup: `cibseven` fails to start, mount error for `cibseven-keycloak-run-….jar` | Plugin jar not downloaded. Run `./plugin/fetch-plugin.sh` |
| Keycloak setup: engine fails with errors from `org.cibseven.community.keycloak` | `cibseven-identity` lacks the roles `query-users`, `view-users`, `query-groups`, or its secret differs from `.env`; or the plugin version doesn't match CIB seven |
| Keycloak setup: realm changes (e.g. new client) missing | The realm is only imported once. Run `docker compose down -v` to re-import |
| LDAP: `openldap` doesn't get healthy after switching from 1.5.0 | Old volumes from the v1 image. Run `docker compose down -v` |
| LDAP login fails | Check `docker compose logs ldap-seed`. Changed an LDAP password in `.env` after the first start? The bootstrap only runs once, so run `down -v` |
| Port already in use | Change `CIBSEVEN_PORT`, `KEYCLOAK_PORT`, `LDAP_PORT` in `.env` (for Keycloak, also the `*_PUBLIC_URL` values). Is the other variant (Run / WildFly) still running? |
| Podman: `up` fails with `container name "…" is already in use` | podman-compose tries to recreate containers of a project that already exists. Run `docker compose down` first (keeps the volumes; add `-f docker-compose.wildfly.yml` for the WildFly variant), then `up -d` again. If only dependency containers are listed while the service you named was started, it is harmless |
| WildFly: image build fails pulling the base image | Run `docker login enterprise.artifacts.cibseven.org` |
| WildFly: build fails at "Patching engine-rest web.xml failed" | The base image's `web.xml` changed (other CIB seven version). Adjust the `sed` expressions in `wildfly/Dockerfile` |
| WildFly: webclient login works, but pages show 401 errors | The REST API didn't get the JWT patch, or the webclient forwards Keycloak tokens. Rebuild (`build cibseven`) and check `accessTokenToEngineRest: false` in `cibseven-webclient-wildfly.yaml` |
| WildFly: `default-filter` exits with an error | It waits up to 15 minutes for the engine tables. Check `docker compose -f docker-compose.wildfly.yml logs cibseven`, then run the job again: `docker compose -f docker-compose.wildfly.yml up default-filter` |

## References

- CIB seven Run: https://docs.cibseven.org/manual/latest/user-guide/cibseven-run/
- LDAP plugin properties: https://docs.cibseven.org/manual/latest/user-guide/process-engine/identity-service/#configuration-properties-of-the-ldap-plugin
- Security guide: https://docs.cibseven.org/manual/latest/user-guide/security/
- cibseven-keycloak plugin: https://github.com/cibseven-community-hub/cibseven-keycloak
- osixia/openldap v2: https://github.com/osixia/container-openldap
- Keycloak realm import with placeholders: https://www.keycloak.org/server/importExport
- WSL networking: https://learn.microsoft.com/windows/wsl/networking
