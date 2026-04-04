# hfc-wp — homefinanceclub.com in Kubernetes

Single pod with three containers: nginx, php-fpm, mariadb.

## Manifests

| File                   | Creates                                      |
|------------------------|----------------------------------------------|
| `configmap-nginx.yaml` | ConfigMap with nginx.conf and site config    |
| `deployment.yaml`      | Deployment (1 replica, 3 containers in a pod)|
| `service.yaml`         | ClusterIP Service on port 80                 |

## Containers in the pod

| Container | Image              | Port | Purpose                            |
|-----------|--------------------|------|------------------------------------|
| nginx     | nginx:1.28         | 80   | Reverse proxy, cache, static files |
| php-fpm   | wordpress:6-fpm    | 9000 | PHP-FPM, WordPress                 |
| mariadb   | mariadb:10.11      | 3306 | Database                           |

All containers share a pod — they communicate via `127.0.0.1`.

## Data on the node

| Node path                    | Mounted at        | Container          | Description     |
|------------------------------|-------------------|--------------------|-----------------|
| `/data/lf-prod/hfc-wp/www`   | `/var/www/html`   | nginx (ro), php-fpm| WordPress files |
| `/data/lf-prod/hfc-wp/mysql` | `/var/lib/mysql`  | mariadb            | MariaDB data    |

## Cache

FastCGI cache is stored in an `emptyDir` volume — shared between nginx and php-fpm. Cache is cleared on pod restart.

The nginx-helper WordPress plugin purges cache files via `unlink()` on post updates. Both containers run as `www-data` (uid=33).

## SSL

SSL is not terminated in the pod — TLS termination is handled at the Ingress level.

nginx passes the HTTPS status from the `X-Forwarded-Proto` header to php-fpm via `fastcgi_param HTTPS`.

## wp-config.php

The file `/data/lf-prod/hfc-wp/www/wp-config.php` must contain:

```php
define('DB_HOST', '127.0.0.1');
define('RT_WP_NGINX_HELPER_CACHE_PATH', '/var/cache/nginx/fcgi/');
```

`DB_HOST` must be `127.0.0.1` (not `localhost` — PHP interprets `localhost` as a Unix socket).

## Secret

The `hfc-wp-mysql` secret in namespace `lf-prod` must contain:

| Key                    | Description              |
|------------------------|--------------------------|
| `MYSQL_ROOT_PASSWORD`  | MariaDB root password    |
| `MYSQL_DATABASE`       | Database name            |
| `MYSQL_USER`           | Application user         |
| `MYSQL_PASSWORD`       | Application user password|

## Access

The `hfc-wp` ClusterIP service is accessible inside the cluster on port 80. External access is configured via the Ingress rule for `host: homefinanceclub.com`.
