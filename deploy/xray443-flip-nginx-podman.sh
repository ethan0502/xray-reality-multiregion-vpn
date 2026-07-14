#!/usr/bin/env bash
#
# Blue-green daily flip, podman variant (e.g. a host where Docker isn't the
# container runtime). Backends are systemd units wrapping `podman run`, so
# the standby is refreshed with `systemctl restart` instead of `docker
# restart` -- otherwise identical to the Docker variant.
#
set -euo pipefail

SNI=example-cdn-jp.com            # this node's own REALITY camouflage target
VARDIR=/etc/nginx/stream-variants
LINK=/etc/nginx/stream.d/00-active-upstream.conf
LOG=/var/log/xray443-flip.log

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

probe() {
    echo | timeout 8 openssl s_client -connect "$1" -servername "$SNI" -tls1_3 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | grep -qi "$SNI"
}

cur=$(readlink -f "$LINK")
case "$cur" in
    *upstream-a-primary.conf)
        standby_unit=xray-b.service; standby_addr=127.0.0.1:2443; next="$VARDIR/upstream-b-primary.conf" ;;
    *upstream-b-primary.conf)
        standby_unit=xray-a.service; standby_addr=127.0.0.1:1443; next="$VARDIR/upstream-a-primary.conf" ;;
    *)
        log "ERROR: cannot determine active upstream from symlink target: $cur"; exit 1 ;;
esac

port_num=${standby_addr##*:}
est=$(ss -Htn state established "( sport = :$port_num )" 2>/dev/null | wc -l)
log "flip start: active=$(basename "$cur") standby=$standby_unit drained_sessions_pre_restart=$est"

systemctl restart "$standby_unit"
sleep 3

if ! probe "$standby_addr"; then
    log "ERROR: standby $standby_unit failed liveness probe after restart; NOT flipping"
    exit 1
fi

ln -sfn "$next" "$LINK"
if ! nginx -t >>"$LOG" 2>&1; then
    log "ERROR: nginx -t failed after symlink swap; reverting to $(basename "$cur")"
    ln -sfn "$cur" "$LINK"
    exit 1
fi

systemctl reload nginx

if probe 127.0.0.1:14443; then
    log "flip done: new active=$(basename "$next"); public passthrough healthy"
else
    log "WARN: flip done (active=$(basename "$next")) but health-port probe failed; check manually"
fi
