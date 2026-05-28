# syntax=docker/dockerfile:1

# A standalone Rigor image — Ruby 4.0 plus the published rigortype
# gem, per ADR-27. Point it at a project mounted on /src:
#
#   docker run --rm -v "$PWD:/src" ghcr.io/rigortype/rigor check
#
FROM ruby:4.0-slim

# rigortype's runtime gems are prism and rbs (both ship C
# extensions) plus language_server-protocol. build-essential is
# installed only for the gem build and purged in the same layer so
# it does not bloat the final image.
ARG RIGOR_VERSION
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential; \
    gem install rigortype ${RIGOR_VERSION:+--version "$RIGOR_VERSION"} \
      || (sleep 60 && gem install rigortype ${RIGOR_VERSION:+--version "$RIGOR_VERSION"}); \
    apt-get purge -y --auto-remove build-essential; \
    rm -rf /var/lib/apt/lists/* /usr/local/lib/ruby/gems/*/cache

WORKDIR /src
ENTRYPOINT ["rigor"]
CMD ["check"]
