# ─────────────────────────────────────────────────────────
# Stage 1 — Build (Dart Frog API only)
#
# The Flutter Web frontend is built and deployed separately via
# .github/workflows (GitHub Pages). This image no longer builds Flutter or
# copies a `public/` directory — see ADR-007 (hosting is separated from the
# app) and routes/_middleware.dart (CORS is now required precisely because
# the frontend lives on a different origin).
# ─────────────────────────────────────────────────────────
FROM dart:stable AS build

WORKDIR /app
COPY . .

RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

WORKDIR /app/apps/server
RUN dart_frog build

WORKDIR /app/apps/server/build
RUN dart pub get && \
    dart compile exe bin/server.dart -o server

# ─────────────────────────────────────────────────────────
# Stage 2 — Runtime (minimal)
# ─────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/apps/server/build/server ./server

ENV PORT=8080
EXPOSE 8080

CMD ["/app/server"]
