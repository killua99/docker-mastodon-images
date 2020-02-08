FROM node:10-alpine AS build-base

ARG MASTODON_VERSION=2.9.3

# some of ruby's build scripts are written in ruby
# we purge system ruby later to make sure our final image uses what we just built
# readline-dev vs libedit-dev: https://bugs.ruby-lang.org/issues/11869 and https://github.com/docker-library/ruby/issues/75
RUN set -eux; \
    \
    apk add --no-cache \
        ca-certificates \
        build-base \
        gmp-dev \
        git \
        yarn \
        python \
        icu-dev \
        protobuf-dev \
        imagemagick \
        ffmpeg \
        libidn-dev \
        yaml-dev \
        postgresql-dev \
        tini \
        wget; \
    \
    apk add --no-cache --virtual .build-deps \
        autoconf \
        bison \
        bzip2 \
        bzip2-dev \
        ca-certificates \
        coreutils \
        dpkg-dev dpkg \
        gcc \
        gdbm-dev \
        glib-dev \
        libc-dev \
        libffi-dev \
        libxml2-dev \
        libxslt-dev \
        linux-headers \
        make \
        ncurses-dev \
        openssl \
        openssl-dev \
        procps \
        readline-dev \
        ruby \
        tar \
        xz \
        zlib-dev && \
    mkdir -p /usr/local/etc; \
    { \
        echo 'install: --no-document'; \
        echo 'update: --no-document'; \
    } >> /usr/local/etc/gemrc

ENV RUBY_MAJOR 2.6
ENV RUBY_VERSION 2.6.5
ENV RUBY_DOWNLOAD_SHA256 d5d6da717fd48524596f9b78ac5a2eeb9691753da5c06923a6c31190abe01a62
ENV CPPFLAGS -I/opt/jemalloc/include
ENV LDFLAGS -L/opt/jemalloc/lib/

RUN set -eux; \
    \
    wget -O ruby.tar.xz "https://cache.ruby-lang.org/pub/ruby/${RUBY_MAJOR%-rc}/ruby-$RUBY_VERSION.tar.xz"; \
    echo "$RUBY_DOWNLOAD_SHA256 *ruby.tar.xz" | sha256sum --check --strict; \
    \
    mkdir -p /usr/src/ruby; \
    tar -xJf ruby.tar.xz -C /usr/src/ruby --strip-components=1; \
    rm ruby.tar.xz; \
    \
    cd /usr/src/ruby; \
    \
# https://github.com/docker-library/ruby/issues/196
# https://bugs.ruby-lang.org/issues/14387#note-13 (patch source)
# https://bugs.ruby-lang.org/issues/14387#note-16 ("Therefore ncopa's patch looks good for me in general." -- only breaks glibc which doesn't matter here)
    wget -O 'thread-stack-fix.patch' 'https://bugs.ruby-lang.org/attachments/download/7081/0001-thread_pthread.c-make-get_main_stack-portable-on-lin.patch'; \
    echo '3ab628a51d92fdf0d2b5835e93564857aea73e0c1de00313864a94a6255cb645 *thread-stack-fix.patch' | sha256sum --check --strict; \
    patch -p1 -i thread-stack-fix.patch; \
    rm thread-stack-fix.patch; \
    \
# hack in "ENABLE_PATH_CHECK" disabling to suppress:
#   warning: Insecure world writable dir
    { \
        echo '#define ENABLE_PATH_CHECK 0'; \
        echo; \
        cat file.c; \
    } > file.c.new; \
    mv file.c.new file.c; \
    \
    autoconf; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
# the configure script does not detect isnan/isinf as macros
    export ac_cv_func_isnan=yes ac_cv_func_isinf=yes; \
    ./configure \
        --build="$gnuArch" \
        --disable-install-doc \
        --enable-shared \
    ; \
    make -j "$(nproc)"; \
    make install; \
    \
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
            | tr ',' '\n' \
            | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-network --virtual .ruby-rundeps \
        $runDeps \
        bzip2 \
        ca-certificates \
        libffi-dev \
        procps \
        yaml-dev \
        zlib-dev \
    ; \
    \
    cd /; \
    rm -r /usr/src/ruby; \
# verify we have no "ruby" packages installed
    ! apk --no-network list --installed \
        | grep -v '^[.]ruby-rundeps' \
        | grep -i ruby \
    ; \
    [ "$(command -v ruby)" = '/usr/local/bin/ruby' ]; \
# rough smoke test
    ruby --version; \
    gem --version; \
    bundle --version

# install things globally, for great justice
# and don't create ".bundle" in all our apps
ENV GEM_HOME /usr/local/bundle
ENV BUNDLE_PATH="$GEM_HOME" \
    BUNDLE_SILENCE_ROOT_WARNING=1 \
    BUNDLE_APP_CONFIG="$GEM_HOME"
# path recommendation: https://github.com/bundler/bundler/pull/6469#issuecomment-383235438
ENV PATH $GEM_HOME/bin:$BUNDLE_PATH/gems/bin:$PATH
# adjust permissions of a few directories for running "gem install" as an arbitrary user
RUN mkdir -p "$GEM_HOME" && chmod 777 "$GEM_HOME" && \
    gem install bundler && \
    irb
# (BUNDLE_PATH = GEM_HOME, no need to mkdir/chown both)

# Install jemalloc
ENV JE_VER 5.1.0

RUN set -eux; \
    \
    wget https://github.com/jemalloc/jemalloc/archive/${JE_VER}.tar.gz && \
    tar xf ${JE_VER}.tar.gz && \
    cd jemalloc-${JE_VER} && \
    ./autogen.sh && \
    ./configure --prefix=/opt/jemalloc && \
    make -j$(nproc) > /dev/null && \
    make install_bin install_include install_lib && \
    apk del --no-network .build-deps

FROM build-base AS assets-compiled

COPY mastodon-upstream /tmp/mastodon-build

RUN set -eux; \
    \
    mkdir -p /opt/mastodon && \
    cp /tmp/mastodon-build/Gemfile* /opt/mastodon/ && \
    cp /tmp/mastodon-build/package.json /opt/mastodon/ && \
    cp /tmp/mastodon-build/yarn.lock /opt/mastodon/ && \
    cd /opt/mastodon && \
    bundle install -j$(nproc) --deployment --without development test && \
    yarn install --pure-lockfile && \
    yarn cache clean

FROM assets-compiled AS final

# Copy mastodon
COPY --chown=991:991 mastodon-upstream /opt/mastodon
COPY --from=assets-compiled --chown=991:991 /opt/mastodon /opt/mastodon
ADD --chown=991:991 https://raw.githubusercontent.com/eficode/wait-for/master/wait-for /wait-for

ARG UID=991
ARG GID=991

# Compiling assets.
RUN set -eux; \
    \
    chmod a+x /wait-for && \
    addgroup --gid ${GID} mastodon && \
    adduser -D -u ${UID} -G mastodon -h /opt/mastodon mastodon && \
    cd /opt/mastodon && \
    ln -s /opt/mastodon /mastodon

# Run mastodon services in prod mode
ENV RAILS_ENV="production"
ENV NODE_ENV="production"

# Tell rails to serve static files
ENV RAILS_SERVE_STATIC_FILES="true"
ENV BIND="0.0.0.0"
ENV PATH="${PATH}:/opt/mastodon/bin"

# Set the run user
USER mastodon

# Precompile assets
RUN set -eux; \
    \
    cd ~ \
    OTP_SECRET=precompile_placeholder SECRET_KEY_BASE=precompile_placeholder rails assets:precompile

# Set the work dir and the container entry point
WORKDIR /opt/mastodon

ENTRYPOINT [ "/sbin/tini", "--" ]
