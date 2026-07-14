#!/usr/bin/env bash
#
# Blue-green daily flip, HAProxy variant -- used on hosts where the
# nginx build available in the package repos has no compatible stream
# module (see docs/architecture.md). Same drain-gate -> restart -> probe ->
# flip -> reload shape as the nginx variants, adapted to HAProxy's config
# validation (`haproxy -c`) instead of `nginx -t`.
#
set -euo pipefail

ACTIVE_CFG="/etc/haproxy/haproxy.cfg"
VARIANT_DIR="/etc/haproxy/xray443-variants"
LOG="/var/log/xray443-flip.log"
SNI="example-cdn.com"

log() {
  printf '%s %s\n' "$(date '+%F %T %z')" "$*" | tee -a "$LOG"
}

active_target="$(readlink -f "$ACTIVE_CFG" || true)"
case "$active_target" in
  *haproxy-a-primary.cfg)
    next="b"
    standby="b"
    standby_port="2443"
    next_cfg="$VARIANT_DIR/haproxy-b-primary.cfg"
    ;;
  *haproxy-b-primary.cfg)
    next="a"
    standby="a"
    standby_port="1443"
    next_cfg="$VARIANT_DIR/haproxy-a-primary.cfg"
    ;;
  *)
    log "ERROR: cannot determine active HAProxy variant from $active_target"
    exit 1
    ;;
esac

drain_count="$(ss -Htn state established "( sport = :$standby_port )" | wc -l | tr -d ' ')"
log "standby xray-$standby port $standby_port established_sessions=$drain_count"

systemctl restart "xray-$standby.service"
sleep 1
/usr/local/bin/xray -test -config "/etc/xray-docker/backends/xray-$standby.json" >/dev/null
ss -lntp | grep -q "127.0.0.1:$standby_port"
subject="$(openssl s_client -connect "127.0.0.1:$standby_port" -servername "$SNI" -tls1_3 </dev/null 2>/dev/null | openssl x509 -noout -subject || true)"
case "$subject" in
  *"$SNI"*) ;;
  *)
    log "ERROR: probe for xray-$standby did not return $SNI certificate: $subject"
    exit 1
    ;;
esac

ln -sfn "$next_cfg" "$ACTIVE_CFG"
haproxy -f "$ACTIVE_CFG" -f /etc/haproxy/conf.d -c -q
systemctl reload haproxy.service
log "flipped active backend to xray-$next"
