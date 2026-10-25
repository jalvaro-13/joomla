# syntax=docker/dockerfile:1
#
# Joomla 4.3 sobre PHP 8.3.36 (Apache, Debian bookworm).
# Sustituto directo de joomla:4.3: mismo código de Joomla, mismos scripts de
# arranque, mismo usuario, volumen y configuración de PHP/Apache; solo cambia
# el runtime de PHP (8.1 -> 8.3.36) y las versiones de las extensiones PECL.

# Imagen de la que se toman Joomla y sus scripts oficiales de arranque.
# Fíjala por digest para copiar exactamente la imagen que tienes desplegada:
#   docker inspect -f '{{index .RepoDigests 0}}' joomla:4.3
#   docker build --build-arg JOOMLA_IMAGE=joomla:4.3@sha256:... .
ARG JOOMLA_IMAGE=joomla:4.3
ARG PHP_IMAGE=php:8.3.36-apache-bookworm

FROM ${JOOMLA_IMAGE} AS joomla

# Runtime actualizado: Apache + PHP 8.3.36.
FROM ${PHP_IMAGE}

# Igual que la oficial: permite instalar contra una BD remota.
ENV JOOMLA_INSTALLATION_DISABLE_LOCALHOST_CHECK=1

# Dependencia de runtime (previsualización de PDF con imagick).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ghostscript; \
    rm -rf /var/lib/apt/lists/*

# Extensiones PHP de la variante oficial Apache de Joomla.
# Las -dev se instalan solo para compilar y luego se purgan. Antes se marcan
# como "manual" las librerías que los .so enlazan de verdad (ldd + dpkg-query);
# si no, el purge se llevaría también libMagickWand, libpq, etc.
RUN set -eux; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libbz2-dev libgmp-dev libicu-dev libfreetype6-dev libjpeg-dev \
        libldap2-dev libmemcached-dev libmagickwand-dev libpq-dev libpng-dev \
        libwebp-dev libzip-dev; \
    \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-configure ldap --with-libdir="lib/$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
    docker-php-ext-install -j"$(nproc)" \
        bz2 bcmath exif gd gmp intl ldap mysqli pdo_mysql pdo_pgsql pgsql zip; \
    \
    # pecl devuelve éxito aunque falle uno de varios paquetes: uno por llamada.
    pecl install imagick-3.8.0; \
    pecl install APCu-5.1.27; \
    pecl install memcached-3.4.0; \
    pecl install redis-6.3.0; \
    # opcache ya viene compilado en la imagen base: basta con activarlo.
    docker-php-ext-enable imagick apcu memcached redis opcache; \
    rm -rf /tmp/pear; \
    \
    extDir="$(php -r 'echo ini_get("extension_dir");')"; \
    [ -d "$extDir" ]; \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    ldd "$extDir"/*.so \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); print so }' \
        | sort -u \
        | xargs -r dpkg-query --search \
        | cut -d: -f1 \
        | sort -u \
        | xargs -rt apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*; \
    \
    # Fallar el build si falta alguna librería o alguna extensión no carga.
    ! { ldd "$extDir"/*.so | grep 'not found'; }; \
    out="$(php -r 'exit(0);')"; [ -z "$out" ]; \
    err="$(php --version 3>&1 1>&2 2>&3)"; [ -z "$err" ]

# Configuración de PHP igual que la oficial.
# - Sin este ini, PHP usa sus valores compilados: display_errors=1,
#   html_errors=1, log_errors=0 (errores en el HTML y nada en docker logs).
# - log_errors_max_len se omite: se eliminó en PHP 8.1.
# - No se añade opcache-recommended.ini: los valores por defecto de PHP 8.3
#   (128/8/10000/2) igualan o mejoran los de la oficial (128/8/4000/2).
RUN set -eux; \
    { \
        echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
        echo 'display_errors = Off'; \
        echo 'display_startup_errors = Off'; \
        echo 'log_errors = On'; \
        echo 'error_log = /dev/stderr'; \
        echo 'ignore_repeated_errors = On'; \
        echo 'ignore_repeated_source = Off'; \
        echo 'html_errors = Off'; \
    } > /usr/local/etc/php/conf.d/error-logging.ini

# Apache: módulos y remoteip igual que la oficial.
RUN set -eux; \
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
    # %h -> %a: que el access log registre la IP real del cliente, no la del proxy.
    find /etc/apache2 -type f -name '*.conf' -exec \
        sed -ri 's/([[:space:]]*LogFormat[[:space:]]+"[^"]*)%h([^"]*")/\1%a\2/g' '{}' +

# Mismo punto de montaje que la oficial (WORKDIR /var/www/html y EXPOSE 80
# vienen ya de la imagen base).
VOLUME /var/www/html

# Mismas variables que la oficial. El entrypoint no las usa, pero hay
# herramientas que las leen. Deben coincidir con la etapa joomla:
#   docker run --rm --entrypoint env joomla:4.3 | grep JOOMLA_
ENV JOOMLA_VERSION=4.3.4
ENV JOOMLA_SHA512=2efede3c3230d2fd849c46f84eea9aa1ef2bef6836e0ceec6451499bb6abf7e747d63f3996d0a5f7fc2d439c5ae0380e0e71f7c2823adfdda80e87a0bc377be1

# Joomla 4.3 y su mecanismo oficial de inicialización. El entrypoint copia
# /usr/src/joomla a /var/www/html solo si el volumen está vacío.
# --chown deja también el directorio raíz como www-data: sin él, BuildKit lo
# crea como root:root aunque conserve el propietario de su contenido.
COPY --from=joomla --chown=www-data:www-data /usr/src/joomla /usr/src/joomla
COPY --from=joomla /entrypoint.sh /entrypoint.sh
COPY --from=joomla /makedb.php /makedb.php

ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]