# Base sur Debian bookworm (12) et non trixie (13).
# Trixie ne fournit qu'ImageMagick 7.1.1-43, dont identifyFormat('%[exif:...]') déclenche
# une assertion native (MagickCore exception.c:1117 -> SIGABRT) qui tue le worker php-fpm
# à chaque upload de photo contenant de l'EXIF (-> 502 Bad Gateway).
# Bookworm fournit ImageMagick 6.9.11, soit la même branche 6.9 que la prod (6.9.12), qui fonctionne.
FROM php:8.4-fpm-bookworm
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
	&& docker-php-ext-configure gd --with-freetype --with-jpeg \
	&& docker-php-ext-install -j$(nproc) gd \
    && docker-php-ext-install exif \
    && docker-php-ext-install bcmath

# Chromium headless — épinglé à 147.
# La 150.0.7871.46 (bookworm-security) crashe (SIGTRAP, exit 133) sur TOUT print-to-pdf en arm64,
# ce qui casse tous les PDF comptables (grand-livre, bilan, résultat…) rendus via nodejs/pdf.js.
# Google Chrome n'ayant pas de build Linux arm64, on reste sur le chromium Debian mais figé sur la
# 147 (bookworm main, qui imprime), et on pose un pin apt pour que security ne réintroduise pas la 150.
ARG CHROMIUM_VERSION=147.0.7727.137-1~deb12u1
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
