# schema-validator

A self-hosted SHACL validator for the author-geo content model.

## Why this exists

`validator.schema.org` (Google-fronted) bot-walls our shared egress IP with
an HTTP 302 to `/sorry/`. That makes it useless as an automated CI/build
gate. This project stands up our OWN, offline, ownable SHACL validation
service instead: same validation semantics (SHACL shapes over RDF/JSON-LD),
but reproducible and under our control.

It builds a derived image on top of the EU Interoperability Test Bed's
generic [`isaitb/shacl-validator`](https://hub.docker.com/r/isaitb/shacl-validator)
core, baked with OUR domain configuration and SHACL shapes, and exposes it
on `localhost:4738`.

## What's in here

```
docker-compose.yml           # builds + runs the derived image, host port 4738
Dockerfile                   # FROM isaitb/shacl-validator:1.12.2@sha256:... + our resources
resources/authorgeo/
  config.properties          # domain config: one validation type, "author_geo_page"
  shapes/author-geo.shacl.ttl# OUR shapes: Book, Person, WebSite, + DD-001 cross-ref rule
scripts/validate.sh          # thin REST client / CI gate: exits non-zero on violations
VERIFY.md                    # copy-pasteable LAN verification steps + test payloads
```

## Running it

```bash
docker compose up -d
# wait for it to report healthy / for localhost:4738 to answer, then:
curl -s http://localhost:4738/shacl/authorgeo/api/info | jq .
```

The validator listens on `localhost:4738` once up:

- Web UI: `http://localhost:4738/shacl/authorgeo/upload`
- REST API: `http://localhost:4738/shacl/authorgeo/api/validate`
  (Swagger UI at `http://localhost:4738/shacl/swagger-ui/index.html`)

## Validating a page

```bash
scripts/validate.sh path/to/built-page.html
# or, if you already have extracted JSON-LD:
scripts/validate.sh path/to/graph.jsonld
```

The script:
1. Extracts the `<script type="application/ld+json">` block if given HTML
   (or uses the file as-is if given `.jsonld`/`.json`).
2. POSTs it to the validator's REST API (`contentToValidate` as BASE64,
   `validationType=author_geo_page`, `reportSyntax=application/json`).
3. Prints the full SHACL report.
4. Exits non-zero if the report shows any violation — so it can gate a
   build/CI pipeline (`scripts/validate.sh out/index.html || exit 1`).

## How the shapes map to our content model

`resources/authorgeo/shapes/author-geo.shacl.ttl` currently covers exactly
what SLICE-01/02/03 of the author-geo content model exercise — **not** the
full eventual schema (more schema.org types will be added as the content
model grows):

| schema.org type | Rule |
|---|---|
| `Book` | requires `name`, `author`, `url`; `author` must resolve to a `Person` |
| `Person` | requires `name` |
| `WebSite` | `publisher` must resolve to a `Person` |

**DD-001 (cross-reference resolution)** — the rule that matters most: any
`@id` referenced by `author` or `publisher` must resolve to a node that is
actually *defined* somewhere in the graph (i.e. has at least one `rdf:type`
triple), not just a `{"@id": "..."}` pointer into thin air. A dangling
reference like this parses as perfectly valid JSON-LD and is exactly the
kind of silent failure this validator exists to catch. See the extensive
comments in the shapes file (`ag:DefinedNodeShape`) for the mechanics.

## Status

The **validator core + shapes round-trip is PROVEN** on the LAN (2026-07-21):
the operator stood up `isaitb/shacl-validator` with our `authorgeo` domain on
the shared network, and the orchestrator ran the round-trip from an in-network
box — a complete clean page validated `SUCCESS` (0 errors), and a page with a
dangling `#ghost-author` reference validated `FAILURE`, firing exactly the
DD-001 cross-reference rule. The gate catches the silent-failure class it
exists for.

This PR adds the **offline `@context` sidecar** (see "How it works" above),
which lets a page emitting the real `"@context": "https://schema.org"`
validate without any egress and without rewriting the emitted bytes. The
sidecar + cert-trust path itself has **not** yet been exercised end-to-end
(it needs `docker compose up --build` with Docker) — run the steps in
`VERIFY.md` on the LAN to prove it. Before this sidecar, a page with a remote
`@context` failed to load in the offline validator (`LOADING_DOCUMENT_FAILED`);
the acceptance test is that the same page now validates.

## How it works — offline `@context` resolution (the sidecar)

Our built pages emit `"@context": "https://schema.org"` (the real,
canonical, remote context URL — we deliberately do **not** rewrite it to a
local one, because the bytes you validate must be the bytes you ship).

But the validator container has **no egress**, so it cannot fetch
`https://schema.org` from Google. Without the context, the JSON-LD fails to
load (`LOADING_DOCUMENT_FAILED`) and *nothing* validates — an easy silent
failure.

The fix is a **sidecar** (`schemaorg-context`, an nginx serving the genuine
cached 211KB `schemaorg.jsonld`) plus a Docker **network alias**: on the
shared network, `schema.org` resolves to the sidecar. So when the validator
does `GET https://schema.org` to resolve a document's context, it reaches
the sidecar over the LAN and gets the real context bytes — no egress, and
the emitted page is never modified.

The one wrinkle: the validator GETs it over **HTTPS**, so the sidecar
presents a self-signed cert whose CN/SAN is `schema.org`, and the validator
image imports that cert's public half into its JVM truststore
(`keytool -importcert -cacerts`) so the TLS handshake succeeds. Empirically
confirmed against this validator: it does a **direct GET on the exact
`@context` URL** and expects the response body to *be* the context (it does
not follow a `Link: rel=alternate` header), so the sidecar serves the same
context bytes at every path.

## Security model — the committed TLS keypair

`tls/schemaorg.crt` **and** `tls/schemaorg.key` are committed to this repo
**on purpose**. This is a dedicated, self-signed keypair whose *only*
function is to let the sidecar and the validator agree on a cert for the
hostname `schema.org` on an **isolated internal Docker network**. It is:

- **not** a public-CA cert, and trusted by nothing except this validator's
  own baked-in truststore;
- valid only for the name `schema.org`, which only resolves to our sidecar
  inside this private network;
- worthless to anyone with the repo — possessing it grants no access to
  anything (there is no secret behind it; it protects nothing outside the
  net).

The keypair must be **shared and fixed** because two independently-built
images depend on it: the sidecar *serves* the cert, and the validator
*trusts* the matching one — they cannot each generate their own. That's why
it is committed rather than generated per-build. If you would rather not
track it, regenerate a pair locally (any CN/SAN `schema.org` self-signed
cert works), drop it in `tls/`, and rebuild both images; `.gitignore` has a
commented `tls/*.key` line for that path.

## Reaching it from inside the shared Docker network

`localhost:4738` is the **host** mapping (for a human on the Docker host).
Other containers on `confluence-sandbox-egress` (build boxes, agent
sandboxes) reach the validator by **service name on its internal port**:
`http://schema-validator:8080/shacl/authorgeo/api/validate` — *not* 4738.
The 4738 host-port mapping and the 8080 in-network port are the same
service; use whichever matches where you're calling from.
