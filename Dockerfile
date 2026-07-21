# Derived image for the author-geo SHACL validator.
#
# Base image pinned by TAG *and* DIGEST (the digest below is the multi-arch
# manifest-list digest for isaitb/shacl-validator:1.12.2, covering both
# linux/amd64 and linux/arm64 — Docker will pick the right per-arch manifest
# automatically). This is the same reproducibility discipline as a lockfile:
# `docker build` always gets exactly this image, never a moving `latest`.
#
# Verified against Docker Hub's tags API for isaitb/shacl-validator on
# 2026-07-21. If this image is ever re-pushed upstream the digest would
# change and this pin would simply fail to resolve (loud failure, not a
# silent drift onto different bits).
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
