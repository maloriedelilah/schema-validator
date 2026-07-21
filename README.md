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

Scaffold + shapes only, committed via PR. **The container has not been
started or exercised in the build environment** (no Docker available there
by design — see `VERIFY.md`). The round-trip (build → up → validate clean
payload → PASS → validate dangled payload → FAIL) is unverified until the
operator runs the steps in `VERIFY.md` on the LAN.
