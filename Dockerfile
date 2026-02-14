FROM 84codes/crystal:latest-alpine AS build
WORKDIR /app

# Create a non-privileged user, defaults are appuser:10001
ARG IMAGE_UID="10001"
ENV UID=$IMAGE_UID
ENV USER=appuser

# See https://stackoverflow.com/a/55757473/12429735
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

RUN apk add \
  --update \
  --no-cache \
    gcc \
    make \
    autoconf \
    automake \
    libtool \
    patch \
    ca-certificates \
    yaml-dev \
    yaml-static \
    git \
    bash \
    iputils \
    libelf \
    gmp-dev \
    gmp \
    gmp-static \
    libxml2-dev \
    musl-dev \
    pcre-dev \
    zlib-dev \
    zlib-static \
    libunwind-dev \
    libunwind-static \
    libevent-dev \
    libevent-static \
    libssh2-static \
    lz4-dev \
    lz4-static \
    tzdata \
    build-base \
    curl

RUN update-ca-certificates

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.lock shard.lock
RUN shards install --production --ignore-crystal-version --skip-postinstall --skip-executables

# Add src
COPY ./src /app/src

RUN shards build --production --release --error-trace --static
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Extract binary dependencies (uncomment if not compiling a static build)
# RUN for binary in /app/bin/*; do \
#        ldd "$binary" | \
#        tr -s '[:blank:]' '\n' | \
#        grep '^/' | \
#        xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'; \
#    done

# Create data directory with proper permissions
RUN mkdir -p /app/data && chmod 1777 /app/data
RUN mkdir -p /app/certs

# Build a minimal docker image
FROM scratch
WORKDIR /
ENV PATH=$PATH:/

# Copy the user information over
COPY --from=build etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group

# These are required for communicating with external services
COPY --from=build /etc/hosts /etc/hosts

# These provide certificate chain validation where communicating with external services over TLS
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# This is required for Timezone support
COPY --from=build /usr/share/zoneinfo/ /usr/share/zoneinfo/

# This is your application
# COPY --from=build /app/deps /
COPY --from=build /app/bin /
COPY --from=build /app/data /data
COPY --from=build /app/certs /certs

# chmod for setting permissions on /data
COPY --from=build /bin /bin
COPY --from=build /lib/ld-musl-* /lib/
RUN chmod -R a+rwX /data
# hadolint ignore=SC2114,DL3059
RUN rm -rf /bin /lib

# Use an unprivileged user.
USER appuser:appuser

# Run the app binding on port 3000
EXPOSE 3000
CMD ["/oven"]
