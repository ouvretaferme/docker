# Binaire composer récupéré depuis l'image officielle (pas de script curl+hash à maintenir,
# pas d'accès réseau à l'exécution du conteneur — composer ne sert qu'en dev, ponctuellement).
FROM composer:2 AS composer

# Base sur Debian bookworm (12) et non trixie (13).
# Trixie ne fournit qu'ImageMagick 7.1.1-43, dont identifyFormat('%[exif:...]') déclenche
# une assertion native (MagickCore exception.c:1117 -> SIGABRT) qui tue le worker php-fpm
# à chaque upload de photo contenant de l'EXIF (-> 502 Bad Gateway).
# Bookworm fournit ImageMagick 6.9.11, soit la même branche 6.9 que la prod (6.9.12), qui fonctionne.
FROM php:8.4-fpm-bookworm

COPY --from=composer /usr/bin/composer /usr/bin/composer
# Le conteneur tourne en root (cf. docker-compose.yml, user: 'root:users') : évite le warning composer.
ENV COMPOSER_ALLOW_SUPERUSER=1
RUN apt-get update && apt-get install -y \
		libfreetype-dev \
		libjpeg62-turbo-dev \
		libpng-dev \
        libcurl3-dev \
        libcurl4-openssl-dev \
        #xml
        libxml2-dev \
        #mbstring
        libonig-dev \
        #imap
        libyaml-dev \
        bash \
        vim \
        #composer
        unzip \
	&& docker-php-ext-configure gd --with-freetype --with-jpeg \
	&& docker-php-ext-install -j$(nproc) gd \
    && docker-php-ext-install exif \
    && docker-php-ext-install bcmath

# Chromium headless — épinglé à 150.0.7871.181.
# La 150.0.7871.46 (bookworm-security, ancienne) crashait (SIGTRAP, exit 133) sur TOUT print-to-pdf
# en arm64, ce qui cassait tous les PDF comptables (grand-livre, bilan, résultat…) rendus via
# nodejs/pdf.js. L'ancien pin sur la 147 (bookworm main) contournait ce crash, mais le mirror Debian
# ne garde pas les anciennes versions : la 147 a fini par disparaître du mirror (build cassé le 24/07).
# Retesté avec la 150.0.7871.181 (bookworm-security) le 24/07 : le crash SIGTRAP est corrigé
# (--print-to-pdf fonctionne, exit 0). On repasse donc sur une version 150 à jour, toujours épinglée
# pour rester reproductible et pour ne pas se refaire surprendre par un futur apt upgrade silencieux.
ARG CHROMIUM_VERSION=150.0.7871.181-1~deb12u1
RUN apt-get update && apt-get install -y --allow-downgrades \
        chromium=${CHROMIUM_VERSION} \
        chromium-common=${CHROMIUM_VERSION} \
        chromium-sandbox=${CHROMIUM_VERSION} \
    && printf 'Package: chromium*\nPin: version %s\nPin-Priority: 1001\n' "${CHROMIUM_VERSION}" > /etc/apt/preferences.d/chromium-pin
RUN ln -sf /usr/lib/chromium/chromium /usr/bin/google-chrome

RUN ln -sf /bin/bash /bin/sh

RUN pecl install -o -f redis \
    &&  rm -rf /tmp/pear \
    &&  docker-php-ext-enable redis

RUN pecl install yaml \
    && docker-php-ext-enable yaml

RUN pecl install oauth \
    && docker-php-ext-enable oauth

RUN apt-get update -yqq \
    && apt-get install -y libmagickwand-dev imagemagick

RUN docker-php-ext-install mysqli pdo pdo_mysql && docker-php-ext-enable pdo_mysql
RUN docker-php-ext-install curl

RUN apt-get update; \
    apt-get install -y libmagickwand-dev; \
    pecl install imagick; \
    docker-php-ext-enable imagick;

#RUN docker-php-ext-install dev # Passage à PHP 8.4 ?

RUN docker-php-ext-install intl
RUN docker-php-ext-install mbstring

RUN docker-php-ext-install xml

RUN sed -i 's/listen = /;listen = /' /usr/local/etc/php-fpm.d/www.conf

# Node for chromium
RUN apt-get update && apt-get install -y \
    npm \
    && npm update npm -g

WORKDIR /

CMD ["php-fpm"]
