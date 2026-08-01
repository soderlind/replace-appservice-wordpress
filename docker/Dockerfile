# Digest-pinned so builds are reproducible; the tag stays so Dependabot knows which stream to
# follow and raises a PR when upstream publishes a php:8.4-apache patch.
FROM php:8.4-apache-bookworm@sha256:721cfc216f3a029c635ae55b3a43fb5c22ac271871a5453f940d392ed223675d

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        default-mysql-client \
        openssh-server \
        libfreetype6-dev \
        libicu-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" bcmath exif gd intl mysqli opcache pdo_mysql zip; \
    rm -rf /var/lib/apt/lists/*

# imagick and redis ship through PECL rather than with PHP. ImageMagick's runtime library is
# installed on its own line so --auto-remove keeps it once the headers and build toolchain are
# purged; the piped newlines accept pecl's defaults (ImageMagick prefix, redis serializers).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libmagickwand-6.q16-6; \
    apt-get install -y --no-install-recommends $PHPIZE_DEPS libmagickwand-dev; \
    printf '\n' | pecl install imagick-3.8.1; \
    yes '' | pecl install redis-6.3.0; \
    docker-php-ext-enable imagick redis; \
    pecl clear-cache; \
    apt-get purge -y --auto-remove $PHPIZE_DEPS libmagickwand-dev; \
    rm -rf /var/lib/apt/lists/*

# App Service's SSH contract: this fixed credential is only reachable through the
# platform's authenticated SCM tunnel, never from the network.
RUN set -eux; \
    echo 'root:Docker!' | chpasswd; \
    mkdir -p /run/sshd
COPY conf/sshd_config /etc/ssh/sshd_config
COPY conf/appservice-env.sh /etc/profile.d/appservice-env.sh

# Checksum pinned inline, not fetched alongside the download: a .sha512 retrieved from the
# same host it protects would still validate a tampered release.
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/wp \
        https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar; \
    echo 'be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832  /usr/local/bin/wp' \
        | sha512sum --check -; \
    chmod +x /usr/local/bin/wp

# The base image activates no php.ini, so display_errors defaults to On and warnings render
# into the page. conf.d is read after php.ini, so the overrides below still win.
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

COPY conf/zz-wordpress.ini /usr/local/etc/php/conf.d/zz-wordpress.ini
COPY conf/000-default.conf /etc/apache2/sites-available/000-default.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN set -eux; \
    a2enmod rewrite headers expires; \
    echo 'ServerName localhost' >> /etc/apache2/apache2.conf; \
    chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80 2222
WORKDIR /home/site/wwwroot
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]
