# ─────────────────────────────────────────────────────────
# Stage 1 — Build (Flutter + Dart Frog)
# ─────────────────────────────────────────────────────────
FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app
COPY . .

# 1. تفعيل دعم الويب (لو ناقص) + Dependencies
RUN cd apps/mobile && flutter create . --platforms web && flutter pub get && dart run build_runner build --delete-conflicting-outputs

# 2. بناء Flutter Web
RUN cd apps/mobile && flutter build web \
      --release \
      --no-tree-shake-icons

# DEBUG: inject on-page error capture script
RUN sed -i 's|</head>|<style>#debug-log{position:fixed;top:0;left:0;right:0;background:#fff;color:red;font-family:monospace;font-size:12px;padding:10px;z-index:99999;max-height:100vh;overflow-y:auto;white-space:pre-wrap;word-break:break-all;}</style><script>window.__errors=[];function showDebug(m){window.__errors.push(m);var el=document.getElementById("debug-log");if(!el){el=document.createElement("div");el.id="debug-log";document.body.appendChild(el);}el.textContent=window.__errors.join("\\n---\\n");}window.onerror=function(msg,src,line,col,err){showDebug("ERROR: "+msg+" at "+src+":"+line+":"+col+(err\&\&err.stack?"\\n"+err.stack:""));};window.addEventListener("unhandledrejection",function(e){showDebug("PROMISE REJECTION: "+(e.reason\&\&e.reason.stack?e.reason.stack:e.reason));});showDebug("Debug script loaded. Waiting for Flutter...");</script></head>|' apps/mobile/build/web/index.html

# VERIFY: check if debug script was injected
RUN grep -c "debug-log" apps/mobile/build/web/index.html && echo "INJECTION SUCCESS" || echo "INJECTION FAILED"

# 3. نسخ output لـpublic/ قبل dart_frog build
RUN mkdir -p apps/server/public && \
    cp -r apps/mobile/build/web/. apps/server/public/
RUN echo '--- PUBLIC DIR CONTENT ---' && ls -la apps/server/public/ | head -20

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
