# ─────────────────────────────────────────────────────────
# Stage 1 — Build (Flutter + Dart Frog)
# ─────────────────────────────────────────────────────────
FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app
COPY . .

# 1. تفعيل دعم الويب (لو ناقص) + Dependencies
RUN cd apps/mobile && flutter create . --platforms web && flutter pub get

# 2. بناء Flutter Web
RUN cd apps/mobile && flutter build web \
      --release \
      --no-tree-shake-icons

# 3. نسخ output لـpublic/ قبل dart_frog build
RUN mkdir -p apps/server/public && \
    cp -r apps/mobile/build/web/. apps/server/public/

# 4. بناء Dart Frog
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

WORKDIR /app/apps/server
RUN dart_frog build

# 5. Compile الـserver binary
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
COPY --from=build /app/apps/server/public        ./public

ENV PORT=8080
EXPOSE 8080

CMD ["/app/server"]
