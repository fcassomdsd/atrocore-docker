FROM php:8.4-apache-bookworm AS base
LABEL maintainer="AtroCore GmbH <support@atrocore.com>"

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"  \
    && printf "post_max_size = 20M\nupload_max_filesize = 20M\nmax_execution_time = 180\nmax_input_time = 180\nmemory_limit = 256M" >> "$PHP_INI_DIR/php.ini" \
    && apt-get update && apt-get install -y \
        git \
        cron \
        postgresql-client \
        zip unzip \
        build-essential \
        locales \
        libcurl4 \
        libcurl4-openssl-dev \
        libsodium-dev \
		libfreetype-dev \
		libjpeg62-turbo-dev \
		libpng-dev \
        libpq-dev \
        libavif-dev \
        libattr1-dev \
        libonig-dev \
        libzip-dev \
        zlib1g-dev \
        libmagickwand-dev \
        libldap2-dev \
        libldap-common \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-avif \
    && docker-php-ext-install -j$(nproc) mbstring curl gd xml zip pdo_pgsql exif ftp ldap sockets \
    && pecl install xattr imagick \
    && docker-php-ext-enable xattr imagick \
    && a2enmod rewrite && a2dissite 000-default \
    && mkdir -p /var/spool/cron/crontabs/

WORKDIR /var/www

# AtroCore itself is installed at container bootstrap (scripts/bootstrap-web-data.sh, run
# against the bind-mounted ./web-data/), not baked into this image's build layers. AtroCore's
# core packages are GPL-3.0-only; installing them here at build time would mean any pre-built
# copy of this image carries GPL-3.0 source, which "distribution" obligations attach to. The
# install scripts still ship in the image (unchanged, only invoked later rather than here) so
# the bootstrap step can run the same sequence this Dockerfile used to run directly.
COPY php/scripts /var/www/scripts
RUN chmod +x scripts/*.sh

COPY startup.sh /startup.sh
RUN chmod +x /startup.sh

CMD ["/startup.sh"]



FROM base AS pdf

RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium \
        chromium-driver \
        libreoffice-core \
        libreoffice-writer \
        fonts-liberation \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/chromium /usr/bin/google-chrome