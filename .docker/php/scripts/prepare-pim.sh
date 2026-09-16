#!/bin/bash

set -e

cd /var/www

# Composer drives the install and doubles as the marker PostUpdate uses to find the project root
# (the skeleton no longer ships one). Pinned with the checksum published alongside the phar.
COMPOSER_VERSION="2.8.12"
COMPOSER_SHA256="f446ea719708bb85fcbf4ef18def5d0515f1f9b4d703f6d820c9c1656e10a2f2"

OPTIONAL=1

# Parse options
while [[ "$1" == --* ]]; do
  case "$1" in
    --optional)
      OPTIONAL=0
      shift
      ;;
    *)
      echo "Unknown flag: $1"
      exit 1
      ;;
  esac
done

if [ -z "$3" ]; then
  echo "Instance domain is not defined, stopping..."
  exit $OPTIONAL
fi

/bin/bash ./scripts/skeleton-check.sh "$1" "$2"

# Each skeleton repository has a moving HEAD and no tags, and they move independently: on
# 2026-08-07 both `skeleton-atrocore` and `skeleton-pim-no-demo` renamed composer.phar to
# atrocore-installer.phar, which broke this build for anyone cloning after it. Pin the revision
# per variant so an upstream rename or constraint bump cannot silently change — or break — the
# image. Bump deliberately, and re-run the fresh-install check.
case "$1" in
  atrocore)    SKELETON_COMMIT="af441640b338a231efd54a6f523823375c6cc564" ;;
  pim-no-demo) SKELETON_COMMIT="b350ca391700f29f2274deff81421e76f9bb6dcd" ;;
  *)           SKELETON_COMMIT="" ;;
esac

tee "/etc/apache2/sites-available/$3.conf" > /dev/null << EOL
<VirtualHost *:80>
  ServerName $3
  DocumentRoot /var/www/$3/public
  <Directory /var/www/$3/public/>
    AllowOverride All
  </Directory>

  ErrorLog "|/usr/bin/rotatelogs /var/log/apache2/$3/error_%Y.%m.%d.log 5M"
  CustomLog "|/usr/bin/rotatelogs /var/log/apache2/$3/access_%Y.%m.%d.log 5M" combined
</VirtualHost>
EOL

mkdir -p "/var/log/apache2/$3"
chown -R www-data:www-data "/var/log/apache2/$3"
a2ensite "$3"

if [[ -d "$3" ]]; then
    echo "Directory $3 already exists, skipping..."
    exit 0;
fi

#git clone "https://gitlab.atrocore.com/atrocore/skeleton-$1.git" "$3"
git clone "https://github.com/atrocore/skeleton-$1.git" "$3"

cd "/var/www/$3"

# Pin the skeleton revision (see the variant map above): HEAD moved on 2026-08-07 and renamed
# composer.phar to atrocore-installer.phar, which broke this build for anyone cloning after it.
if [[ -n "${SKELETON_COMMIT}" ]]; then
  git checkout --quiet "${SKELETON_COMMIT}"
fi

# PostUpdate::getRootPath() locates the project root by walking up from vendor/atrocore/core/…
# looking for a directory that contains `composer.phar`. The rename above removed that file, so a
# build with the pinned revision dies with "Can't find root directory." We therefore provide
# Composer ourselves, pinned and checksum-verified — it is required as that marker (and is a handy
# fallback), even though the install itself is driven by the AtroCore installer below.
curl -fsSL -o composer.phar "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar"
echo "${COMPOSER_SHA256}  composer.phar" | sha256sum -c -

# Pin the dependency set. The skeleton's own composer.json floats (atrocore/core ">=2.3.12",
# export/import "*") and `update` re-resolves at every build, so the installed application — and
# therefore the database schema — used to change with wall-clock time. That is exactly how
# extensible_enum.multilingual drifted: the model was authored against 1.1.11 (which has the
# field), while a fresh build pulled >=2.2.30 (which removed it) and the vocabulary seed failed.
# composer.pinned.json pins the set verified against the model, at the top of the range this
# project already declared (atrocore/core >=2.0.23 <=2.1.6).
cp /var/www/scripts/composer.pinned.json composer.json

if grep -q '"minimum-stability"' composer.json; then
  sed -i "s/\"minimum-stability\": *\"[^\"]*\"/\"minimum-stability\": \"$2\"/" composer.json
fi

# PostUpdate::uploadDemoData() downloads and extracts whatever first_update.log points at
# (AtroCore's own demo dataset). This project ships its own synthetic dataset, so drop the file.
rm -f first_update.log

# `update` is what runs composer.json's post-update-cmd (\Atro\Composer\PostUpdate), which
# scaffolds the application (root files, modules, migrations, cache), and the install is pinned by
# the exact constraints in composer.pinned.json.
#
# The AtroCore installer drives it, not plain Composer: the public package listing
# (packagist.atrocore.com/packages.json, 53 packages) carries atrocore/core, export and import but
# omits atrocore/atrocore-legacy and atrocore/slim, which core requires — the installer
# supplements the repository and resolves them. Plain `composer update` fails with
# "atrocore/atrocore-legacy … could not be found in any version".
#
# The builder also resolves repo.packagist.org to IPv6 and then cannot route it (curl error 28,
# connect timeout); pin Composer's HTTP client to IPv4.
export COMPOSER_IPRESOLVE=4
php atrocore-installer.phar update --no-dev --no-interaction

cp /var/www/scripts/prepare-pim.php . && php prepare-pim.php "$4" "$5" "$6" && rm prepare-pim.php

echo "Setting up files permissions..."
find . -type d -exec chmod 755 {} + && find . -type f -exec chmod 644 {} +;
find client data upload -type d -exec chmod 775 {} + && find client data upload -type f -exec chmod 664 {} +
chown -R www-data:www-data "/var/www/$3"

echo "Configuring cron job..."
echo "* * * * * /usr/local/bin/php /var/www/$3/console.php cron" >> /var/spool/cron/crontabs/www-data

echo "PIM instance for $3 is ready to install."
