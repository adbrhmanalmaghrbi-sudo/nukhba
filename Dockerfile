FROM ghcr.io/cirruslabs/flutter:3.44.0 AS build

WORKDIR /app
COPY . .

RUN dart pub global activate dart_frog_cli
ENV PATH="$PATH:/root/.pub-cache/bin"

WORKDIR /app/apps/server
RUN dart_frog build

WORKDIR /app/apps/server/build
RUN dart pub get && \
    dart compile exe bin/server.dart -o server

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/apps/server/build/server ./server

ENV PORT=8080
EXPOSE 8080

CMD ["/app/server"]
