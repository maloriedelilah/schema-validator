# VERIFY.md — LAN verification steps (operator-run)

This project was built in a sandbox with **no Docker available**, so the
round-trip below has **not** been run or observed by the agent that wrote
it. Everything here is copy-pasteable so you (the operator) can prove it
end-to-end on the LAN. Nothing about a successful validation run has been
fabricated or implied anywhere else in this repo — this file is where that
proof is supposed to actually happen.

## 1. Build and start the validator

```bash
cd schema-validator
docker compose up -d --build
```

Wait for it to come up, then confirm the domain is loaded:

```bash
curl -s --max-time 30 http://localhost:4738/shacl/authorgeo/api/info | jq .
```

You should see `author_geo_page` listed as a validation type. If this
call fails or times out, the container isn't ready yet (or didn't start
at all — check `docker compose logs schema-validator`) and nothing below
will work.

## 2. The two test payloads

Both are minimal JSON-LD graphs combining a `WebSite`, a `Person`, and a
`Book`, mirroring the SLICE-01/02/03 content-model split (WebSite in one
place, Person+Book together). They differ in exactly one place: the
`Book.author` reference.

### 2a. CLEAN payload — must PASS

Save as `clean.jsonld`:

```json
{
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "WebSite",
      "@id": "https://example.com/",
      "publisher": { "@id": "https://example.com/about#author" }
    },
    {
      "@type": "Person",
      "@id": "https://example.com/about#author",
      "name": "Malorie Cooper"
    },
    {
      "@type": "Book",
      "@id": "https://example.com/books/aeon-14-vol-1",
      "name": "Aeon 14: The Vol 1",
      "url": "https://example.com/books/aeon-14-vol-1",
      "author": { "@id": "https://example.com/about#author" }
    }
  ]
}
```

Every `@id` referenced by `author`/`publisher` (`.../about#author`) is
defined elsewhere in the SAME graph, as a `Person` node with a `name` —
so DD-001 and the type checks should all be satisfied.

Run:

```bash
scripts/validate.sh clean.jsonld
echo "exit code: $?"
```

**Expected: prints a report with no violations, prints `PASS: ...`,
exits 0.**

### 2b. DANGLED payload — must FAIL

Save as `dangled.jsonld`. Identical to the clean payload EXCEPT
`Book.author.@id` now points to `#ghost-author`, which is never defined
anywhere in the graph (no node anywhere declares it, so it has no
`rdf:type`):

```json
{
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "WebSite",
      "@id": "https://example.com/",
      "publisher": { "@id": "https://example.com/about#author" }
    },
    {
      "@type": "Person",
      "@id": "https://example.com/about#author",
      "name": "Malorie Cooper"
    },
    {
      "@type": "Book",
      "@id": "https://example.com/books/aeon-14-vol-1",
      "name": "Aeon 14: The Vol 1",
      "url": "https://example.com/books/aeon-14-vol-1",
      "author": { "@id": "https://example.com/about#ghost-author" }
    }
  ]
}
```

Run:

```bash
scripts/validate.sh dangled.jsonld
echo "exit code: $?"
```

**Expected: the report shows a violation on `Book.author`
(the `ag:DefinedNodeShape` / `sh:class schema:Person` constraint failing
because `#ghost-author` has no `rdf:type` anywhere in the graph — this is
DD-001 catching a dangling cross-reference), prints `FAIL: ...`, exits 1.**

## 3. If the results don't match

If step 2a fails, or step 2b unexpectedly passes, do NOT assume the shapes
are wrong first — check in this order:

1. `curl .../api/info` (step 1) actually shows `author_geo_page` loaded.
2. The raw JSON report (`scripts/validate.sh` prints it before the
   pass/fail summary) — read the actual `result` / `counters` / findings
   fields. `scripts/validate.sh` was written by reasoning from the ITB
   docs and a real (different) live ITB validator's documented response
   shape, NOT by observing a response from THIS validator, because Docker
   wasn't available in the build sandbox. If the live field names differ
   from what `scripts/validate.sh` expects (search for the comment above
   the `RESULT=`/`NR_ERRORS=` lines), fix the `jq` paths there — that is
   a plumbing bug, not a shapes bug.
3. Only after 1–2 check out, treat it as a shapes bug in
   `resources/authorgeo/shapes/author-geo.shacl.ttl`.

## 4. Tear down

```bash
docker compose down
```
