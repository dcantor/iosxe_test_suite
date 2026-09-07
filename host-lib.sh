# Resolves per-host settings (H1/H2/H3) plus its router's LAN facts.
host_vars() {
  local h="${1:?usage: host_vars H1|H2|H3}"
  case " $HOSTS " in *" $h "*) ;; *) echo "ERROR: unknown host '$h'" >&2; return 1 ;; esac
  local f v
  for f in NAME ROUTER IP SSH CONSOLE; do
    v="${h}_${f}"; printf -v "$f" '%s' "${!v}"
  done
  HOST="$h"
  v="${ROUTER}_LAN_IP";   printf -v GATEWAY  '%s' "${!v}"
  v="${ROUTER}_LAN_PORT";  printf -v LAN_PORT  '%s' "${!v}"
  v="${ROUTER}_LAN_MCAST"; printf -v LAN_MCAST '%s' "${!v}"
  # every other host's LAN, so this host can be routed to all of them
  PEER_NETS=""
  local o r n
  for o in $HOSTS; do
    [[ "$o" == "$h" ]] && continue
    v="${o}_ROUTER"; r="${!v}"
    v="${r}_LAN_NET"; n="${!v}"
    PEER_NETS="${PEER_NETS}${PEER_NETS:+ }${n}"
  done
}
