# Obtiene Joomla 4.3 y sus scripts oficiales de arranque.
# Conserva la misma versión de Joomla que el despliegue actual.
FROM joomla:4.3 AS joomla

# Runtime actualizado: Apache + PHP 8.3.36.
FROM php:8.3.36-apache-bookworm

ENV JOOMLA_INSTALLATION_DISABLE_LOCALHOST_CHECK=1

# Dependencias y extensiones que trae la variante oficial Apache de Joomla.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ghostscript \
        libbz2-dev libgmp-dev libicu-dev libfreetype6-dev libjpeg-dev \
        libldap2-dev libmemcached-dev libmagickwand-dev libpq-dev libpng-dev \
        libwebp-dev libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-configure ldap --with-libdir="lib/$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
    docker-php-ext-install -j"$(nproc)" \
        bz2 bcmath exif gd gmp intl ldap mysqli pdo_mysql pdo_pgsql pgsql zip opcache; \
    pecl install imagick-3.8.0; \
    pecl install APCu-5.1.27; \
    pecl install memcached-3.4.0; \
    pecl install redis-6.3.0; \
    docker-php-ext-enable imagick apcu memcached redis; \
    a2enmod rewrite expires remoteip; \
    { \
        echo 'RemoteIPHeader X-Forwarded-For'; \
        echo 'RemoteIPInternalProxy 10.0.0.0/8'; \
        echo 'RemoteIPInternalProxy 172.16.0.0/12'; \
        echo 'RemoteIPInternalProxy 192.168.0.0/16'; \
        echo 'RemoteIPInternalProxy 169.254.0.0/16'; \
        echo 'RemoteIPInternalProxy 127.0.0.0/8'; \
    } > /etc/apache2/conf-available/remoteip.conf; \
    a2enconf remoteip; \
    rm -rf /tmp/pear /var/lib/apt/lists/*

# Copiamos Joomla 4.3 y su mecanismo oficial de inicialización.
# El entrypoint copia Joomla a /var/www/html en el primer arranque.
COPY --from=joomla /usr/src/joomla /usr/src/joomla
COPY --from=joomla /entrypoint.sh /entrypoint.sh
COPY --from=joomla /makedb.php /makedb.php

WORKDIR /var/www/html
VOLUME ["/var/www/html"]
EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]

