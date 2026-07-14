#!/usr/bin/env bash
#
# Blue-green daily flip for the two local Xray backends behind the nginx
# stream front door on public 443. Docker-backed variant.
#
#   - The container we restart is the CURRENT standby (drained ~24h).
#   - We only flip AFTER the freshly restarted standby passes a liveness probe.
#   - The flip is a symlink swap + nginx reload. Established sessions on the
#     old primary keep running on the old worker generation and drain until
#     the next flip.
#
set -euo pipefail

SNI=example-cdn.com               # this node's REALITY camouflage target
VARDIR=/etc/nginx/stream-variants
LINK=/etc/nginx/stream.d/00-active-upstream.conf
LOG=/var/log/xray443-flip.log

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# Liveness probe: an unauthorized TLS client is forwarded by REALITY to its
# dest, so a healthy backend returns the borrowed certificate for $SNI.
probe() {
    echo | timeout 8 openssl s_client -connect "$1" -servername "$SNI" -tls1_3 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | grep -qi "$SNI"
}

cur=$(readlink -f "$LINK")
case "$cur" in
    *upstream-a-primary.conf)
        standby_cont=xray-b; standby_addr=127.0.0.1:2443; next="$VARDIR/upstream-b-primary.conf" ;;
    *upstream-b-primary.conf)
        standby_cont=xray-a; standby_addr=127.0.0.1:1443; next="$VARDIR/upstream-a-primary.conf" ;;
    *)
        log "ERROR: cannot determine active upstream from symlink target: $cur"; exit 1 ;;
esac

port_num=${standby_addr##*:}
est=$(ss -Htn state established "( sport = :$port_num )" 2>/dev/null | wc -l)
log "flip start: active=$(basename "$cur") standby=$standby_cont drained_sessions_pre_restart=$est"

docker restart "$standby_cont" >/dev/null
sleep 2

if ! probe "$standby_addr"; then
    log "ERROR: standby $standby_cont failed liveness probe after restart; NOT flipping"
    exit 1
fi

ln -sfn "$next" "$LINK"
if ! nginx -t >>"$LOG" 2>&1; then
    log "ERROR: nginx -t failed after symlink swap; reverting to $(basename "$cur")"
    ln -sfn "$cur" "$LINK"
    exit 1
fi

systemctl reload nginx

# Confirm public passthrough still healthy via the loopback health port.
if probe 127.0.0.1:14443; then
    log "flip done: new active=$(basename "$next"); public passthrough healthy"
else
    log "WARN: flip done (active=$(basename "$next")) but health-port probe failed; check manually"
fi
