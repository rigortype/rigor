# ADR-29 WD5 — Fly.io deployment Dockerfile for the playground
# backend. Single-image multi-stage build; the runtime image
# carries only the production gems + the playground app, the
# parent `rigortype` source tree, and the `rigor-rbs-inline`
# plugin (both wired as `path:` deps in the playground's
# Gemfile).
#
# Build context MUST be the rigor repo root, not this directory,
# because the playground's Gemfile references `path: "../.."`
# (rigortype) and `path: "../../plugins/rigor-rbs-inline"`:
#
#   docker build -f playground/backend/Dockerfile -t rigor-playground .
#
# # Image tag pinning
#
# `ruby:4.0-slim` is the target base. Until the official Ruby
# Docker repo ships a 4.0 stable tag, build the image against
# the dev tag (`ruby:dev`) or compile Ruby from source in a
# separate build stage. The runtime expects Ruby 4.0 per
# `rigortype`'s gemspec `required_ruby_version`.

FROM ruby:4.0-slim AS builder

ENV BUNDLE_DEPLOYMENT=true \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_PATH=/usr/local/bundle \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Native-extension build deps (prism, rbs, puma). The runtime
# image (FROM `ruby:4.0-slim` below) keeps these out so the
# deployed image stays small.
RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y \
      build-essential \
      libffi-dev \
      libyaml-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Bundle the path-deps' source code into the image. The
# playground's Gemfile references `path: "../.."` (rigortype's
# gemspec at the repo root) and `path: "../../plugins/rigor-rbs-inline"`.
# Copy the rigortype gem source first; the playground
# Gemfile.lock resolves these at `bundle install` time.
COPY rigortype.gemspec Gemfile Gemfile.lock /app/
COPY lib /app/lib
COPY sig /app/sig
COPY exe /app/exe
COPY data /app/data
COPY README.md LICENSE /app/
COPY plugins/rigor-rbs-inline /app/plugins/rigor-rbs-inline
COPY playground/backend /app/playground/backend

WORKDIR /app/playground/backend
RUN bundle install --jobs=4 --retry=3

# ──────────────────────────────────────────────────────────
# Runtime stage — minimal image carrying only the installed
# gems, the app code, and a non-root user.
FROM ruby:4.0-slim AS runtime

ENV BUNDLE_DEPLOYMENT=true \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_PATH=/usr/local/bundle \
    RACK_ENV=production \
    PORT=8080 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# `ffi` runtime needs libffi; `puma` needs no extra deps once
# its native extensions are compiled in the builder stage.
RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y libffi8 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 1000 rigor \
 && useradd  --system --uid 1000 --gid rigor --create-home --shell /bin/false rigor

COPY --from=builder --chown=rigor:rigor /usr/local/bundle /usr/local/bundle
COPY --from=builder --chown=rigor:rigor /app /app

USER rigor
WORKDIR /app/playground/backend

EXPOSE 8080

# Single-process, single-thread per `puma.rb`. Fly.io's
# external proxy handles concurrency (ADR-29 WD5 caps it at
# 4 in-flight requests; rate limits to 50/min/IP).
CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
