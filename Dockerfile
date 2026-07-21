# Derived image for the author-geo SHACL validator.
#
# Base image pinned by TAG *and* DIGEST (the digest below is the multi-arch
# manifest-list digest for isaitb/shacl-validator:1.12.2, covering both
# linux/amd64 and linux/arm64 — Docker will pick the right per-arch manifest
# automatically). This is the same reproducibility discipline as a lockfile:
# `docker build` always gets exactly this image, never a moving `latest`.
#
# This digest pin was carried over from the initial scaffold (PR #1); it was
# NOT re-verified against Docker Hub in this environment (no registry egress
# from the build sandbox). If it is stale or wrong the build FAILS LOUDLY at
# pull time (never a silent drift onto different bits) -- re-pin then.
FROM isaitb/shacl-validator:1.12.2@sha256:04bbd422d3bbd081390d72c2a31548d860b153d09a6a8a151a6446d3816e81ca

# Layer in OUR domain configuration + SHACL shapes. The generic image is just
# a core engine; everything under resources/<domain>/ is what turns it into
# an "author-geo validator" instance.
COPY resources /validator/resources/

# Tell the validator where its resource root lives inside the image.
# (Property-with-dots ENV keys are unusual but this is exactly the syntax
# documented by the upstream ITB "Setting up an RDF validator" guide.)
ENV validator.resourceRoot /validator/resources/

# Pin explicitly which domain folder(s) under resourceRoot to load, and the
# name presented to users/API callers for it. Not strictly required (the
# validator auto-discovers domain folders that contain a config.properties)
# but being explicit means an accidental extra folder under resources/ can
# never silently become a second, unintended domain.
ENV validator.domain authorgeo
ENV validator.domainName.authorgeo authorgeo

# --- Trust the local schema.org context sidecar -------------------------
# The sidecar (schemaorg-context service) serves the cached schema.org
# JSON-LD context over HTTPS under the hostname schema.org (Docker network
# alias). For the validator's JSON-LD processor to fetch it over https
# WITHOUT a TLS error, this JVM must trust the sidecar's self-signed cert.
# We import ONLY the public certificate (never the private key) into the
# JDK's default truststore (cacerts, default password `changeit`; `-cacerts`
# targets $JAVA_HOME/lib/security/cacerts on JDK 9+).
#
# If a future base image uses a JRE whose cacerts is elsewhere or whose
# keytool lacks `-cacerts`, this RUN will FAIL LOUDLY at build (good) — fix
# the path here rather than letting an untrusted fetch silently fall back.
COPY tls/schemaorg.crt /tmp/schemaorg.crt
RUN keytool -importcert -noprompt -trustcacerts \
        -alias schemaorg-local \
        -file /tmp/schemaorg.crt \
        -cacerts -storepass changeit \
    && rm -f /tmp/schemaorg.crt
