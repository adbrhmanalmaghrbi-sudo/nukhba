FROM ghcr.io/cirruslabs/flutter:3.44.0 AS build

WORKDIR /app
COPY . .

RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

WORKDIR /app/apps/server
RUN dart_frog build

# dart_frog's generated build/bin/server.dart unconditionally wraps the
# handler in a static-file handler rooted at a `public/` directory next to
# the executable (dart_frog/src/create_static_file_handler.dart) — this is
# not optional, even for an API-only server. Without it, the compiled
# server throws `Invalid argument(s): A directory corresponding to
# filesystemPath "public" could not be found` and crashes on startup
# before binding to any port. An *empty* public/ directory is enough: it
# never matches a request, so every request still falls through to the
# route handlers below — no static assets are actually served.
RUN mkdir -p public

WORKDIR /app/apps/server/build
RUN dart pub get && \
    dart compile exe bin/server.dart -o server

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/apps/server/build/server ./server
COPY --from=build /app/apps/server/public        ./public

ENV PORT=8080
EXPOSE 8080

CMD ["/app/server"]
