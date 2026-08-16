#!/bin/bash

set -e

cd /var/www

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

if grep -q '"minimum-stability"' composer.json; then
  sed -i "s/\"minimum-stability\": *\"[^\"]*\"/\"minimum-stability\": \"$2\"/" composer.json
fi

php composer.phar self-update && php composer.phar update

cp /var/www/scripts/prepare-pim.php . && php prepare-pim.php "$4" "$5" "$6" && rm prepare-pim.php

echo "Setting up files permissions..."
find . -type d -exec chmod 755 {} + && find . -type f -exec chmod 644 {} +;
find client data upload -type d -exec chmod 775 {} + && find client data upload -type f -exec chmod 664 {} +
chown -R www-data:www-data "/var/www/$3"

echo "Configuring cron job..."
echo "* * * * * /usr/local/bin/php /var/www/$3/console.php cron" >> /var/spool/cron/crontabs/www-data

echo "PIM instance for $3 is ready to install."
