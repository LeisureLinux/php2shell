#!/bin/bash
# Provision the combined lab for both CVEs.
#
#   sudo bash 01_setup_lab.sh [PHP_VERSION] [PORT] [CHAIN]
#
# Defaults: PHP_VERSION=8.4  PORT=8080  CHAIN=109619
#
# CHAIN selects session.upload_progress.cleanup, which the two CVEs need
# in opposite states -- see the note in lab/php.ini.
#
# Both CVEs live in PHP's session machinery, so one setup serves both:
#
#   /upload/x.php    session.serialize_handler = php            (default)
#                    -- writer for CVE-2026-109619,
#                    -- OOM target for CVE-2026-109618.
#   /serialized/     session.serialize_handler = php_serialize
#                    -- the reader CVE-2026-109619 needs.
#
# The public webroot is left COMPLETELY EMPTY: neither chain ever writes a
# file there.
#
# Requires PHP below the fixed release: 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12
set -euo pipefail
export LC_ALL=C

PHPV="${1:-8.4}"
PORT="${2:-8080}"
CHAIN="${3:-109619}"
APP=/opt/php2shell-lab
WEBROOT=/srv/empty-webroot
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "[1] PHP version"
if ! command -v "php${PHPV}" >/dev/null 2>&1; then
    cat <<EOF
    php${PHPV} not found.  Install the distro packages, e.g.
      apt install php${PHPV}-common php${PHPV}-cli libapache2-mod-php${PHPV}
    A *vulnerable* build usually has to come from the distro pool, because the
    repo candidate is already patched.  On Debian:
      POOL=https://deb.debian.org/debian/pool/main/p/php${PHPV}
      (download the 5 packages at the version below the fixed one, then)
      dpkg -i --force-downgrade php${PHPV}-*.deb
      apt-mark hold php${PHPV}-common php${PHPV}-cli libapache2-mod-php${PHPV} \\
                    php${PHPV}-opcache php${PHPV}-readline
    The hold matters: a later 'apt-get -f install' silently upgrades it.
EOF
    exit 1
fi
php${PHPV} -v | head -1
echo "    fixed versions: 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12"

echo "[2] Certificates of the flow (layout outside the webroot)"
mkdir -p "${APP}/serialized" "${WEBROOT}"
install -m 0644 "${SRC}/lab/gadget.php"           "${APP}/gadget.php"
install -m 0644 "${SRC}/lab/bootstrap.php"        "${APP}/bootstrap.php"
install -m 0644 "${SRC}/lab/handler.php"          "${APP}/handler.php"
install -m 0644 "${SRC}/lab/serialized_index.php" "${APP}/serialized/index.php"

echo "[3] Apache"
a2dismod "php${PHPV}" >/dev/null 2>&1 || true
a2enmod  "php${PHPV}" >/dev/null 2>&1 || true
a2dismod mpm_event    >/dev/null 2>&1 || true
a2enmod  mpm_prefork  >/dev/null 2>&1 || true

sed -e "s|@PORT@|${PORT}|g" \
    -e "s|@APP@|${APP}|g" \
    -e "s|@WEBROOT@|${WEBROOT}|g" \
    "${SRC}/lab/apache.conf" > /etc/apache2/conf-available/zz-php2shell-lab.conf
a2dissite 000-default >/dev/null 2>&1 || true
a2enconf  zz-php2shell-lab >/dev/null 2>&1

echo "[4] PHP ini (chain=${CHAIN})"
INI="/etc/php/${PHPV}/apache2/conf.d/99-php2shell-lab.ini"
install -m 0644 "${SRC}/lab/php.ini" "$INI"
case "$CHAIN" in
    109618) CLEANUP=On  ;;   # stage 1 B needs END -> cleanup -> initialize
    109619) CLEANUP=Off ;;   # the payload name must survive until save
    *) echo "    unknown CHAIN '$CHAIN' (use 109618 or 109619)"; exit 1 ;;
esac
sed -i "s/^session.upload_progress.cleanup.*/session.upload_progress.cleanup = ${CLEANUP}/" "$INI"
echo "    cleanup = ${CLEANUP}"

apache2ctl configtest 2>&1 | tail -1
systemctl reset-failed apache2 >/dev/null 2>&1 || true
systemctl restart apache2
sleep 2

echo "[5] Self-check"
printf '<?php echo "ver=".PHP_VERSION." auto_start=".ini_get("session.auto_start")'\
'." sh=".ini_get("session.serialize_handler")." cleanup=".ini_get("session.upload_progress.cleanup")'\
'." prefix=[".ini_get("session.upload_progress.prefix")."] ob=".ini_get("output_buffering")'\
'." miv=".ini_get("max_input_vars")."\\n";' > "${APP}/probe.php"
printf 'Alias /probe.php %s/probe.php\n' "${APP}" \
    >> /etc/apache2/conf-available/zz-php2shell-lab.conf
systemctl reload apache2; sleep 1

echo -n "  /probe.php    : "; curl -s -m 5 "http://127.0.0.1:${PORT}/probe.php" || echo FAIL
echo -n "  /upload/x.php : "
curl -s -m 5 -o /dev/null -w "%{http_code}\n" -X POST \
     "http://127.0.0.1:${PORT}/upload/x.php" \
     -F "PHP_SESSION_UPLOAD_PROGRESS=x" -F "f=@/etc/hostname"
echo -n "  /serialized/  : "
curl -s -m 5 -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:${PORT}/serialized/"
echo "  webroot       : $(ls -A "${WEBROOT}" | wc -l) files (expected 0)"
echo
echo "OK -> http://<target-ip>:${PORT}"
echo
echo "NOTE: Apache usually runs with PrivateTmp=yes, so session files and any"
echo "      proof file written by a gadget land in the worker's private /tmp:"
echo "        /proc/<worker-pid>/root/tmp/"
