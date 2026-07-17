FROM dart:3.9 AS build

WORKDIR /app
COPY . .

# Resolve the whole pub workspace once from the root.
RUN dart pub get

# Activate Dart Frog CLI and build the server package.
RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

WORKDIR /app/apps/server
RUN dart_frog build

WORKDIR /app/apps/server/build
RUN dart pub get
RUN dart compile exe bin/server.dart -o server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/apps/server/build/server /app/server
COPY --from=build /app/apps/server/build/public /app/public

ENV PORT=8080
EXPOSE 8080
CMD ["/app/server"]
