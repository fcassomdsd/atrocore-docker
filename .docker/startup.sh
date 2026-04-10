#!/bin/sh

set -e

configure_domain() {
	domain="$1"

	if [ -z "$domain" ]; then
		return 0
	fi

	cat > "/etc/apache2/sites-available/${domain}.conf" <<EOF
<VirtualHost *:80>
	ServerName ${domain}
	DocumentRoot /var/www/${domain}/public
	<Directory /var/www/${domain}/public/>
		AllowOverride All
	</Directory>

	ErrorLog "|/usr/bin/rotatelogs /var/log/apache2/${domain}/error_%Y.%m.%d.log 5M"
	CustomLog "|/usr/bin/rotatelogs /var/log/apache2/${domain}/access_%Y.%m.%d.log 5M" combined
</VirtualHost>
EOF

	mkdir -p "/var/log/apache2/${domain}"
	chown -R www-data:www-data "/var/log/apache2/${domain}"
	a2ensite "${domain}" >/dev/null

	touch /var/spool/cron/crontabs/www-data
	chown root /var/spool/cron/crontabs/www-data
	tmpfile="$(mktemp)"
	grep -v "/var/www/${domain}/.*\.php cron" /var/spool/cron/crontabs/www-data > "$tmpfile" || true
	cat "$tmpfile" > /var/spool/cron/crontabs/www-data
	rm -f "$tmpfile"
	echo "* * * * * /usr/local/bin/php /var/www/${domain}/console.php cron" >> /var/spool/cron/crontabs/www-data
	chown www-data /var/spool/cron/crontabs/www-data
	chmod 600 /var/spool/cron/crontabs/www-data
}

configure_domain "${PRODUCTION_DOMAIN:-localhost}"
configure_domain "${TESTING_DOMAIN:-}"

cron

apache2-foreground