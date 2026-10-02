#!/usr/bin/env bash
set -euo pipefail

PROG="${0##*/}"

LOAD_WARN_RATIO="${LOAD_WARN_RATIO-1.5}"
LOAD_CRIT_RATIO="${LOAD_CRIT_RATIO-2.5}"
DISK_WARN_PCT="${DISK_WARN_PCT-85}"
DISK_CRIT_PCT="${DISK_CRIT_PCT-95}"
INODE_WARN_PCT="${INODE_WARN_PCT-85}"
INODE_CRIT_PCT="${INODE_CRIT_PCT-95}"
WG_INTERFACE="${WG_INTERFACE-wg0}"
WG_HANDSHAKE_MAX_AGE="${WG_HANDSHAKE_MAX_AGE-180}"
EXPECTED_PORTS="${EXPECTED_PORTS-22 80 443}"
SYSLOG_ON_FAIL="${SYSLOG_ON_FAIL-1}"

MAX_SEV=0
N_OK=0
N_WARN=0
N_CRIT=0

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h]" \
    "" \
    "Controle de sante du systeme : charge CPU, espace disque et inodes," \
    "conteneurs Docker, tunnel WireGuard et ports en ecoute." \
    "" \
    "Codes de retour: 0 OK, 1 avertissement, 2 critique" \
    "" \
    "Variables d'environnement:" \
    "  LOAD_WARN_RATIO        charge moyenne/nbre de coeurs -> WARN (defaut: ${LOAD_WARN_RATIO})" \
    "  LOAD_CRIT_RATIO        charge moyenne/nbre de coeurs -> CRIT (defaut: ${LOAD_CRIT_RATIO})" \
    "  DISK_WARN_PCT          occupation disque -> WARN (defaut: ${DISK_WARN_PCT})" \
    "  DISK_CRIT_PCT          occupation disque -> CRIT (defaut: ${DISK_CRIT_PCT})" \
    "  INODE_WARN_PCT         occupation inodes -> WARN (defaut: ${INODE_WARN_PCT})" \
    "  INODE_CRIT_PCT         occupation inodes -> CRIT (defaut: ${INODE_CRIT_PCT})" \
    "  WG_INTERFACE           interface WireGuard (defaut: ${WG_INTERFACE})" \
    "  WG_HANDSHAKE_MAX_AGE   age max de la poignee de main en s (defaut: ${WG_HANDSHAKE_MAX_AGE})" \
    "  EXPECTED_PORTS         ports qui doivent etre en ecoute (defaut: ${EXPECTED_PORTS})" \
    "                         si defini mais vide, aucun port n'est surveille" \
    "  SYSLOG_ON_FAIL         1 = journalise WARN/CRIT dans syslog (defaut: ${SYSLOG_ON_FAIL})"
}

require_uint() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} doit etre un entier positif (valeur: ${value})"
}

require_num() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "${name} doit etre un nombre positif (valeur: ${value})"
  [[ "${value}" != "0" && "${value}" != "0.0" ]] || die "${name} doit etre superieur a 0"
}

require_bool() {
  local name="$1"
  local value="$2"
  [[ "${value}" == "0" || "${value}" == "1" ]] || die "${name} doit valoir 0 ou 1 (valeur: ${value})"
}

die() {
  printf '[CRIT] %s\n' "$*" >&2
  exit 2
}

report() {
  local level="$1"
  shift
  case "${level}" in
    OK)
      N_OK=$((N_OK + 1))
      ;;
    WARN)
      N_WARN=$((N_WARN + 1))
      if [[ "${MAX_SEV}" -lt 1 ]]; then
        MAX_SEV=1
      fi
      ;;
    CRIT)
      N_CRIT=$((N_CRIT + 1))
      MAX_SEV=2
      ;;
    *)
      die "niveau de severite inconnu: ${level}"
      ;;
  esac
  printf '[%-4s] %s\n' "${level}" "$*"
  if [[ "${level}" != "OK" && "${SYSLOG_ON_FAIL}" == "1" ]]; then
    if [[ "${level}" == "CRIT" ]]; then
      logger -p user.err -t "$PROG" -- "$*" 2>/dev/null || true
    else
      logger -p user.warning -t "$PROG" -- "$*" 2>/dev/null || true
    fi
  fi
}

check_load() {
  local load1=""
  local cores=""
  local warn_t
  local crit_t
  if [[ ! -r /proc/loadavg ]]; then
    report WARN "charge CPU: /proc/loadavg illisible"
    return 0
  fi
  read -r load1 _ < /proc/loadavg
  if ! command -v awk >/dev/null 2>&1; then
    report WARN "charge CPU: commande awk introuvable (1m=${load1})"
    return 0
  fi
  cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || printf '1')
  warn_t=$(awk -v c="${cores}" -v r="${LOAD_WARN_RATIO}" 'BEGIN { printf "%.2f", c * r }')
  crit_t=$(awk -v c="${cores}" -v r="${LOAD_CRIT_RATIO}" 'BEGIN { printf "%.2f", c * r }')
  if awk -v l="${load1}" -v t="${crit_t}" 'BEGIN { exit !(l + 0 > t + 0) }'; then
    report CRIT "charge CPU ${load1} sur ${cores} coeur(s) (seuil critique ${crit_t})"
  elif awk -v l="${load1}" -v t="${warn_t}" 'BEGIN { exit !(l + 0 > t + 0) }'; then
    report WARN "charge CPU ${load1} sur ${cores} coeur(s) (seuil d'alerte ${warn_t})"
  else
    report OK "charge CPU ${load1} sur ${cores} coeur(s)"
  fi
}

scan_usage() {
  local label="$1"
  local warn="$2"
  local crit="$3"
  local pcol="$4"
  shift 4
  local cap
  local mount
  local pct
  local max_pct=0
  local max_mount=""
  local checked=0

  if ! command -v df >/dev/null 2>&1; then
    report WARN "${label}: commande df introuvable"
    return 0
  fi

  while read -r cap mount; do
    [[ -n "${mount:-}" ]] || continue
    pct="${cap%\%}"
    if [[ ! "${pct}" =~ ^[0-9]+$ ]]; then
      continue
    fi
    checked=$((checked + 1))
    if ((pct > max_pct)); then
      max_pct="${pct}"
      max_mount="${mount}"
    fi
    if ((pct >= crit)); then
      report CRIT "${label}: ${mount} utilise ${pct}% (seuil critique ${crit}%)"
    elif ((pct >= warn)); then
      report WARN "${label}: ${mount} utilise ${pct}% (seuil d'alerte ${warn}%)"
    fi
  done < <(df --output="${pcol},target" "$@" 2>/dev/null | tail -n +2)

  if ((checked == 0)); then
    report WARN "${label}: aucune information disponible"
    return 0
  fi
  if ((max_pct >= warn)); then
    return 0
  fi
  report OK "${label}: ${checked} point(s) de montage, pire cas ${max_pct}% (${max_mount})"
}

check_wireguard() {
  local conf="/etc/wireguard/${WG_INTERFACE}.conf"
  local state=""
  local hs_raw=""
  local hs=""
  local rc=0
  local now
  local age

  if ! command -v ip >/dev/null 2>&1; then
    report WARN "wireguard: commande ip introuvable"
    return 0
  fi

  if ! ip link show dev "${WG_INTERFACE}" >/dev/null 2>&1; then
    if [[ -f "${conf}" ]]; then
      report CRIT "wireguard: ${WG_INTERFACE} configure mais interface absente"
    else
      report WARN "wireguard: ${WG_INTERFACE} non configure sur cet hote"
    fi
    return 0
  fi

  state=$(ip -br link show dev "${WG_INTERFACE}" 2>/dev/null | awk '{ print $2 }') || true
  if [[ "${state}" != "UP" ]]; then
    report CRIT "wireguard: interface ${WG_INTERFACE} en etat ${state:-inconnu}"
    return 0
  fi

  if ! command -v wg >/dev/null 2>&1; then
    report WARN "wireguard: outil wg introuvable, poignee de main non verifiable"
    return 0
  fi

  hs_raw=$(wg show "${WG_INTERFACE}" latest-handshakes 2>/dev/null) || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    report WARN "wireguard: interrogation de ${WG_INTERFACE} impossible (rc=${rc})"
    return 0
  fi
  hs=$(printf '%s\n' "${hs_raw}" | awk 'NR == 1 { print $2 }')
  if [[ ! "${hs}" =~ ^[0-9]+$ || "${hs}" == "0" ]]; then
    report WARN "wireguard: aucune poignee de main enregistree sur ${WG_INTERFACE}"
    return 0
  fi

  now=$(date +%s)
  age=$((now - hs))
  if ((age <= WG_HANDSHAKE_MAX_AGE)); then
    report OK "wireguard: ${WG_INTERFACE} UP, poignee de main il y a ${age}s"
  elif ((age <= WG_HANDSHAKE_MAX_AGE * 4)); then
    report WARN "wireguard: poignee de main ancienne sur ${WG_INTERFACE} (${age}s)"
  else
    report CRIT "wireguard: poignee de main perdue sur ${WG_INTERFACE} (${age}s)"
  fi
}

check_docker() {
  local name=""
  local state=""
  local status=""
  local total=0
  local -a faulty=()

  if ! command -v docker >/dev/null 2>&1; then
    report WARN "docker: binaire absent du PATH"
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    report CRIT "docker: daemon inaccessible"
    return 0
  fi

  while IFS='|' read -r name state status; do
    [[ -n "${name}" ]] || continue
    total=$((total + 1))
    if [[ "${state}" == "running" && "${status}" != *"(unhealthy)"* ]]; then
      continue
    fi
    faulty+=("${name}=${state}")
  done < <(docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null)

  if ((total == 0)); then
    report WARN "docker: aucun conteneur detecte"
    return 0
  fi
  if ((${#faulty[@]} > 0)); then
    report CRIT "docker: ${#faulty[@]}/${total} conteneur(s) anormal(aux): ${faulty[*]}"
    return 0
  fi
  report OK "docker: ${total} conteneur(s) en execution"
}

check_ports() {
  local listening=""
  local addr
  local port
  local -a expected=()
  local -a open=()
  local -a missing=()

  if ! command -v ss >/dev/null 2>&1; then
    report WARN "ports: commande ss introuvable"
    return 0
  fi

  listening=$(ss -H -lntu 2>/dev/null | awk '{ print $5 }') || true
  while IFS= read -r addr; do
    [[ -n "${addr}" ]] || continue
    port="${addr##*:}"
    if [[ "${port}" =~ ^[0-9]+$ ]]; then
      open+=("${port}")
    fi
  done <<< "${listening}"

  read -r -a expected <<< "${EXPECTED_PORTS}"
  if ((${#expected[@]} == 0)); then
    report OK "ports: aucune attente definie, ${#open[@]} port(s) en ecoute"
    return 0
  fi

  for port in "${expected[@]}"; do
    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
      report WARN "ports: valeur invalide '${port}' dans EXPECTED_PORTS"
      continue
    fi
    if ! printf '%s\n' "${open[@]}" | grep -qx -- "${port}"; then
      missing+=("${port}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    report CRIT "ports: absent(s) de l'ecoute -> ${missing[*]} (ouverts: ${#open[@]})"
    return 0
  fi
  report OK "ports: ${EXPECTED_PORTS} en ecoute (${#open[@]} port(s) ouverts)"
}

print_summary() {
  printf '%s\n' "--- resume: ${N_OK} OK, ${N_WARN} WARN, ${N_CRIT} CRIT"
  case "${MAX_SEV}" in
    0)
      printf '%s\n' "RESULTAT: OK"
      ;;
    1)
      printf '%s\n' "RESULTAT: WARN"
      ;;
    *)
      printf '%s\n' "RESULTAT: CRIT"
      ;;
  esac
}

main() {
  local opt
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -h | --help)
        usage
        return 0
        ;;
      *)
        printf 'Option inconnue: %s\n' "${opt}" >&2
        usage >&2
        return 64
        ;;
    esac
  done

  require_num LOAD_WARN_RATIO "${LOAD_WARN_RATIO}"
  require_num LOAD_CRIT_RATIO "${LOAD_CRIT_RATIO}"
  require_uint DISK_WARN_PCT "${DISK_WARN_PCT}"
  require_uint DISK_CRIT_PCT "${DISK_CRIT_PCT}"
  require_uint INODE_WARN_PCT "${INODE_WARN_PCT}"
  require_uint INODE_CRIT_PCT "${INODE_CRIT_PCT}"
  require_uint WG_HANDSHAKE_MAX_AGE "${WG_HANDSHAKE_MAX_AGE}"
  require_bool SYSLOG_ON_FAIL "${SYSLOG_ON_FAIL}"

  check_load
  scan_usage "disque" "${DISK_WARN_PCT}" "${DISK_CRIT_PCT}" pcent -x tmpfs -x devtmpfs -x squashfs -x overlay
  scan_usage "inodes" "${INODE_WARN_PCT}" "${INODE_CRIT_PCT}" ipcent -x tmpfs -x devtmpfs -x squashfs -x overlay
  check_docker
  check_wireguard
  check_ports

  print_summary
  return "${MAX_SEV}"
}

main "$@"
