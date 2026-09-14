ARG RUBY_VERSION="3.4.9"
ARG DEBIAN_BASE="trixie"
# Add SBOM scan context for intermediate steps
ARG BUILDKIT_SBOM_SCAN_CONTEXT=true
ARG BUILDKIT_SBOM_SCAN_STAGE=true
FROM ruby:${RUBY_VERSION}-slim-trixie AS runtime-base
LABEL maintainer="operations@openproject.com"

ARG NODE_VERSION="22.22.1"
ARG BIM_SUPPORT=true
ENV USE_JEMALLOC=false
ENV DEBIAN_FRONTEND=noninteractive
ENV BUNDLE_JOBS=8
ENV BUNDLE_RETRY=3
ENV BUNDLE_WITHOUT="development:test"

# SYSTEM
ENV DOCKER=1
ENV APP_USER=app
ENV APP_PATH=/app
ENV APP_DATA_PATH=/var/openproject/assets
ENV BUNDLE_PATH="$APP_PATH/vendor/bundle"
ENV BUNDLE_APP_CONFIG="$APP_PATH/.bundle"
ENV PGVERSION="17"
ENV PGVERSION_CHOICES="13 15 17"
ENV PGBIN="/usr/lib/postgresql/$PGVERSION/bin"
ENV PGCONF_FILE="/etc/postgresql/$PGVERSION/main/postgresql.conf"
ENV PATH="$PGBIN:$PATH"
ENV BUNDLE_WITHOUT="development:test"

# RAILS
# Set a default key base, ensure to provide a secure value in production environments!
ENV SECRET_KEY_BASE=OVERWRITE_ME
ENV RAILS_ENV=production
ENV RAILS_LOG_TO_STDOUT=1
ENV RAILS_SERVE_STATIC_FILES=1

# OPENPROJECT
# Valid values are: standard,bim
ENV OPENPROJECT_EDITION=standard
ENV OPENPROJECT_INSTALLATION__TYPE=docker
ENV OPENPROJECT_ATTACHMENTS__STORAGE__PATH=$APP_DATA_PATH/files
ENV OPENPROJECT_RAILS__CACHE__STORE=file_store
ENV OPENPROJECT_ANGULAR_UGLIFY=true

# set the following to an empty string if you don't want to automatically use the bundled hocuspocus
# (or set an external hocuspocus directly - if empty you can set it in the UI)
ENV OPENPROJECT_COLLABORATIVE__EDITING__HOCUSPOCUS__URL=auto
ENV OPENPROJECT_COLLABORATIVE__EDITING__HOCUSPOCUS__SECRET=

RUN useradd -d /home/$APP_USER -m $APP_USER && \
  mkdir -p $APP_PATH && chown $APP_USER:$APP_USER $APP_PATH && \
  mkdir -p $APP_DATA_PATH && chown $APP_USER:$APP_USER $APP_DATA_PATH && chmod g+rwx $APP_DATA_PATH

WORKDIR $APP_PATH

# upgrade bundler
RUN gem install bundler --no-document

# system dependencies, nodejs
COPY ./docker/prod/setup/preinstall-common.sh /tmp/preinstall-common.sh
COPY ./docker/prod/setup/preinstall-alpine.sh /tmp/preinstall-alpine.sh
RUN apk add --no-cache bash 2>/dev/null || true; \
    if [ "$DEBIAN_BASE" = "alpine" ]; then \
      /tmp/preinstall-alpine.sh; \
    else \
      /tmp/preinstall-common.sh; \
    fi

# Generate en_US.UTF-8 locale for PostgreSQL compatibility (pgdata may have been initialized with this locale)
# locales-all provides pre-compiled locale binaries for all supported locales
RUN apt-get update -qq && apt-get install -yq --no-install-recommends locales-all && \
  rm -rf /var/lib/apt/lists/*

FROM runtime-base AS build-base
ARG NODE_VERSION="22.22.3"

# build-only dependencies
COPY ./docker/prod/setup/preinstall-build.sh ./docker/prod/setup/preinstall-build.sh
RUN ./docker/prod/setup/preinstall-build.sh

FROM build-base AS app-build

# stuff required for gems
COPY Gemfile Gemfile.* .ruby-version ./
COPY modules ./modules
# Add vendor for saas-openproject plugins
COPY vendor ./vendor
# Add lib in case a plugin tries to load VERSION file under lib
COPY lib ./lib

COPY ./docker/prod/setup/bundle-install.sh ./vendor/bundle* ./vendor/
RUN bash vendor/bundle-install.sh && rm vendor/bundle-install.sh

COPY . .

# Copy logo files to public/assets for direct serving in production
RUN mkdir -p /app/public/assets && \
  cp /app/app/assets/images/logo_yojana.png /app/public/assets/ && \
  cp /app/app/assets/images/logo_yojana_white_big.png /app/public/assets/ && \
  cp /app/app/assets/images/logo_openproject.png /app/public/assets/ && \
  cp /app/app/assets/images/logo_openproject_white_big.png /app/public/assets/ 2>/dev/null || true

# Copy lock file again as the updated version was overriden by COPY just now
RUN cp Gemfile.lock.bak Gemfile.lock && rm Gemfile.lock.bak && \
  ./docker/prod/setup/postinstall-common.sh && \
  cp ./config/database.production.yml config/database.yml && \
  ln -s $APP_PATH/docker/prod/setup/.irbrc /home/$APP_USER/

# Precompile assets on first run (not during build to avoid OOM)
RUN mkdir -p /app/tmp/assets-precompiled

# -------------------------------------
# app-runtime (intermediate, not published)
# -------------------------------------
FROM runtime-base AS app-runtime

COPY --chown=$APP_USER:$APP_USER --from=app-build /app /app

RUN ./docker/prod/setup/postinstall-common.sh && \
  cp ./config/database.production.yml config/database.yml && \
  ln -s $APP_PATH/docker/prod/setup/.irbrc /home/$APP_USER/

# Precompile assets on first run (not during build to avoid OOM)
RUN mkdir -p /app/tmp/assets-precompiled

# -------------------------------------
# app-runtime-slim (intermediate, not published)
# -------------------------------------
FROM runtime-base AS app-runtime-slim

COPY --chown=$APP_USER:$APP_USER --from=app-build /app /app

RUN ./docker/prod/setup/postinstall-common.sh && \
  cp ./config/database.production.yml config/database.yml && \
  ln -s $APP_PATH/docker/prod/setup/.irbrc /home/$APP_USER/

# Precompile assets on first run (not during build to avoid OOM)
RUN mkdir -p /app/tmp/assets-precompiled

# -------------------------------------
# slim (public)
# -------------------------------------
FROM app-runtime-slim AS slim

USER $APP_USER
EXPOSE 8080
CMD ["./docker/prod/web"]
ENTRYPOINT ["./docker/prod/entrypoint-slim.sh"]
VOLUME ["$APP_DATA_PATH"]

# -------------------------------------
# slim-bim (public)
# same as slim but with BIM support enabled
# -------------------------------------
FROM app-runtime-slim AS slim-bim

USER $APP_USER
EXPOSE 8080
CMD ["./docker/prod/web"]
ENTRYPOINT ["./docker/prod/entrypoint-slim.sh"]
VOLUME ["$APP_DATA_PATH"]
ENV OPENPROJECT_EDITION=bim
# -------------------------------------
# all-in-one (public)
# -------------------------------------
FROM app-runtime AS all-in-one

ENV OPENPROJECT_RAILS__CACHE__STORE=memcache
ENV DATABASE_URL=postgres://openproject:openproject@127.0.0.1/openproject
ENV PGDATA=/var/openproject/pgdata

ADD https://github.com/tianon/gosu/releases/download/1.17/gosu-amd64 /usr/local/bin/gosu
RUN chmod +x /usr/local/bin/gosu && gosu nobody true

COPY --from=openproject/hocuspocus:17.5.1 --chown=$APP_USER:$APP_USER /app /opt/hocuspocus
# Keep node/npm in all-in-one for bundled hocuspocus even when BIM support is disabled.
COPY --from=build-base /usr/local/bin/node /usr/local/bin/node
COPY --from=build-base /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ./docker/prod/setup/postinstall-onprem.sh && \
  ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
  ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
  ln -sf ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack && \
  ln -s /app/docker/prod/setup/.irbrc /root/

# Install Node.js 22.22.3 for asset compilation (frontend requires ^22.22.3)
RUN curl -sL https://nodejs.org/dist/v22.22.3/node-v22.22.3-linux-x64.tar.gz | tar xzf - -C /usr/local --strip-components=1 && \
  npm install -g npm@11

# Fix symlinks for linked plugins (point to /app/modules instead of local dev paths)
RUN mkdir -p /app/frontend/src/app/features/plugins/linked && \
  cd /app/frontend/src/app/features/plugins/linked && \
  for link in *; do \
    if [ -L "$link" ]; then \
      target=$(readlink "$link"); \
      newtarget=$(echo "$target" | \
        sed -e 's|/home/dev/openproject/modules|/app/modules|g' \
            -e 's|/Users/admin/yojana/modules|/app/modules|g' \
            -e 's|/Users/[^/]*/yojana/modules|/app/modules|g' \
            -e 's|/app/frontend/src/app/features/plugins/linked/../[^/]*|/app/modules|g'); \
      rm -f "$link" && ln -s "$newtarget" "$link"; \
    fi; \
  done

# Build frontend assets
# linked/ and linked-plugins.{module.ts,styles.sass} are gitignored in a clean
# checkout, so regenerate them via the node script before the angular build.
# Locale JSON files (frontend/src/locales/*.json) are also gitignored and must be
# exported from the Rails I18n backend before the Angular build.
RUN cd /app && npm install && \
  cd /app/frontend && npm install && \
  npm run ci:plugins:register_frontend && \
  DATABASE_URL=nulldb://db bundle exec rake assets:export_locales && \
  npm run build

# Create symlinks for main assets (Angular outputs hashed filenames)
# This allows direct file access at logical names (e.g., styles.css -> styles-XXXX.css)
RUN cd /app/public/assets/frontend && \
  ln -sf main-*.js main.js 2>/dev/null || true && \
  ln -sf polyfills-*.js polyfills.js 2>/dev/null || true && \
  ln -sf styles-*.css styles.css 2>/dev/null || true

# Rebuild the frontend assets manifest (maps logical names to hashed filenames)
RUN cd /app && ruby -e 'require "json"; require "pathname"; a=Pathname.new("public/assets/frontend/"); m=a.glob("**/*").select(&:file?).filter_map{|f|n=f.basename(f.extname).to_s;e=f.extname;if n=~/\A(.+?)[-\.][A-Z0-9]{8}\z/;[Pathname.new($1+e).to_s,f.relative_path_from(a).to_s]else;nil;end}.to_h;Pathname.new("config/frontend_assets.manifest.json").write(m.to_json);puts "Frontend manifest: #{m.length} entries"'

# Expose ports for apache and postgres
EXPOSE 80

# Expose the postgres data directory and OpenProject data directory as volumes
VOLUME ["$PGDATA", "$APP_DATA_PATH"]

# Set a custom entrypoint to allow for privilege dropping and one-off commands
ENTRYPOINT ["./docker/prod/entrypoint.sh"]

# Set default command to launch the all-in-one configuration supervised by supervisord
CMD ["./docker/prod/supervisord"]
