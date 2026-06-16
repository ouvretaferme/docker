FROM php:8.4-fpm
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

# Chromium headless
RUN apt-get install -y chromium
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
