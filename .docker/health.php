<?php
/**
 * health.php — the atro-web liveness endpoint, served at /health.
 *
 * Lives at /opt/atrocore-health/ in the image, NOT under /var/www, because
 * docker-compose.yaml bind-mounts ./web-data over /var/www and a bind mount
 * hides whatever the image put at that path. Anything shipped under /var/www
 * is invisible at runtime; /opt survives.
 *
 * WHAT IT CHECKS, AND WHAT IT DELIBERATELY DOES NOT
 * -------------------------------------------------
 * It answers two questions, both by reading the local filesystem:
 *
 *   installed  — is the AtroCore application present at all?
 *   configured — has the install wizard written data/config.php?
 *
 * "installed" is the one that drives the HTTP status, because it is the exact
 * failure this stack actually produces on a clean clone: ./web-data is empty,
 * Apache's DocumentRoot points at a directory that does not exist, and every
 * request answers 404 from a container that Docker happily reports as running.
 * The runbook documents that trap because it has cost people time; a health
 * check that could not see it would not be worth adding. So: 200 when the
 * application is there, 503 when it is not.
 *
 * "configured" is reported but does NOT affect the status. Between bootstrap
 * and the install wizard there is a legitimate window where the application is
 * installed and unconfigured, and a container that flips to unhealthy during
 * its own provisioning would be wrong about itself. Whether a system has been
 * provisioned is a deployment fact, not a liveness fact.
 *
 * It does NOT touch PostgreSQL, and that is deliberate rather than lazy. A
 * probe that opens a database connection can block on a wedged or
 * connection-saturated server for as long as the driver's timeout allows, and
 * a liveness probe that hangs is worse than no probe: Docker reports
 * `starting` forever, the restart policy never fires, and the silence looks
 * exactly like health. Database reachability is a readiness question and
 * belongs in Prometheus, which can time out independently of the thing it is
 * measuring. Every check below is a stat() on a local path.
 */

header('Content-Type: application/json');
header('Cache-Control: no-store');

$domain = getenv('PRODUCTION_DOMAIN') ?: 'localhost';
$root   = '/var/www/' . $domain;

$installed  = is_readable($root . '/public/index.php');
$configured = is_readable($root . '/data/config.php');

http_response_code($installed ? 200 : 503);

echo json_encode([
    'status'     => $installed ? 'ok' : 'not_installed',
    'service'    => 'atrocore',
    'domain'     => $domain,
    'installed'  => $installed,
    'configured' => $configured,
    'checked'    => 'apache/php process and the on-disk application; the database is not probed',
    'hint'       => $installed ? null : 'run scripts/bootstrap-web-data.sh - ./web-data is empty, so Apache has no DocumentRoot',
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT) . "\n";
