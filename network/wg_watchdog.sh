#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"

WG_INTERFACE="${WG_INTERFACE-wg0}"
WG_PING_TARGET="${WG_PING_TARGET:-}"
WG_PING_COUNT="${WG_PING_COUNT-3}"
WG_PING_TIMEOUT="${WG_PING_TIMEOUT-3}"
WG_PING_INTERVAL="${WG_PING_INTERVAL-2}"
WG_MAX_FAILURES="${WG_MAX_FAILURES-3}"
WG_STATE_FILE="${WG_STATE_FILE-/run/wg-watchdog.state}"
WG_LOCK_FILE="${WG_LOCK_FILE-/run/wg-watchdog.lock}"
WG_RESTART_CMD="${WG_RESTART_CMD:-}"
WG_RESTART_DELAY="${WG_RESTART_DELAY-10}"
WG_FORCE=0

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-f]" \
    "" \
    "Watchdog de l'interface WireGuard : ping de la passerelle du tunnel," \
    "compteur d'echecs consecutifs, relance propre du service au-dela du seuil" \
    "et trace ecrite dans syslog." \
    "" \
    "A executer en tache cron (ex: * * * * * root /usr/local/bin/${PROG})." \
    "" \
    "Options:" \
    "  -f, --force    tente la relance meme si le seuil n'est pas atteint" \
    "  -h, --help     affiche cette aide" \
    "" \
    "Variables d'environnement:" \
    "  WG_INTERFACE       interface surveillee (defaut: ${WG_INTERFACE})" \
    "  WG_PING_TARGET     hote a pinger a travers le tunnel ; si vide, la" \
    "                     passerelle est deduite des routes de l'interface" \
    "  WG_PING_COUNT      essais par execution (defaut: ${WG_PING_COUNT})" \
    "  WG_PING_TIMEOUT    timeout ping en secondes (defaut: ${WG_PING_TIMEOUT})" \
    "  WG_PING_INTERVAL   pause entre essais en secondes (defaut: ${WG_PING_INTERVAL})" \
    "  WG_MAX_FAILURES    echecs consecutifs avant relance (defaut: ${WG_MAX_FAILURES})" \
    "  WG_RESTART_DELAY   attente apres relance en secondes (defaut: ${WG_RESTART_DELAY})" \
    "  WG_RESTART_CMD     commande de relance explicite (defaut: systemctl puis wg-quick)" \
    "  WG_STATE_FILE      compteur d'echecs (defaut: ${WG_STATE_FILE})" \
    "  WG_LOCK_FILE       verrou anti-surfait (defaut: ${WG_LOCK_FILE})" \
    "" \
    "Codes de retour: 0 tunnel joignable, 1 degrade sous seuil, 2 critique"
}

log() {
  local priority="$1"
  shift
  printf '%s %s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${priority^^}" "$PROG" "$*" >&2
  logger -p "user.${priority}" -t "$PROG" -- "$*" 2>/dev/null || true
}

die() {
  log err "$*"
  exit 2
}

require_uint() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} doit etre un entier positif (valeur: ${value})"
}

require_tools() {
  local tool
  for tool in ping ip flock mktemp date sleep; do
    command -v "${tool}" >/dev/null 2>&1 || die "commande introuvable: ${tool}"
  done
}

resolve_target() {
  local gateway=""
  if [[ -n "${WG_PING_TARGET}" ]]; then
    printf '%s\n' "${WG_PING_TARGET}"
    return 0
  fi
  gateway=$(ip -4 route show dev "${WG_INTERFACE}" 2>/dev/null \
    | awk '$1 == "via" { print $2; exit }') || true
  if [[ -n "${gateway}" ]]; then
    printf '%s\n' "${gateway}"
    return 0
  fi
  return 1
}

check_ping_capability() {
  local output
  output=$(ping -I "${WG_INTERFACE}" -n -q -c 1 -W 1 127.0.0.1 2>&1) || true
  if [[ "${output}" == *"Operation not permitted"* || "${output}" == *"Permission denied"* ]]; then
    die "ping sur ${WG_INTERFACE} refuse : execution en root ou possession de CAP_NET_RAW requise"
  fi
  return 0
}

probe() {
  local target="$1"
  ping -I "${WG_INTERFACE}" -n -q -c 1 -W "${WG_PING_TIMEOUT}" "${target}" >/dev/null 2>&1
}

attempt_probe() {
  local target="$1"
  local attempt
  for ((attempt = 1; attempt <= WG_PING_COUNT; attempt++)); do
    if probe "${target}"; then
      return 0
    fi
    if [[ "${attempt}" -lt "${WG_PING_COUNT}" ]]; then
      sleep "${WG_PING_INTERVAL}"
    fi
  done
  return 1
}

read_state() {
  local value=""
  if [[ -f "${WG_STATE_FILE}" ]]; then
    IFS= read -r value < "${WG_STATE_FILE}" || true
  fi
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    value=0
  fi
  printf '%s\n' "${value}"
}

write_state() {
  local value="$1"
  local tmp
  tmp=$(mktemp "${WG_STATE_FILE}.XXXXXX") || die "creation du fichier d'etat impossible"
  printf '%s\n' "${value}" >"${tmp}"
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${WG_STATE_FILE}"
}

lock_state() {
  local dir
  dir=$(dirname "${WG_STATE_FILE}")
  if [[ ! -d "${dir}" ]]; then
    mkdir -p "${dir}" 2>/dev/null || die "repertoire d'etat inaccessible: ${dir}"
  fi
  [[ -w "${dir}" ]] || die "repertoire d'etat non inscriptible: ${dir}"
  if ! exec 8>"${WG_LOCK_FILE}"; then
    die "ouverture du verrou impossible: ${WG_LOCK_FILE}"
  fi
  if ! flock -n 8; then
    log info "une instance tourne deja, abandon"
    exit 0
  fi
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
  else
    return 1
  fi
}

restart_interface() {
  local unit="wg-quick@${WG_INTERFACE}.service"

  if [[ -n "${WG_RESTART_CMD}" ]]; then
    log warning "relance de ${WG_INTERFACE} via WG_RESTART_CMD"
    if run_root bash -c "${WG_RESTART_CMD}"; then
      log info "commande de relance executee avec succes"
      return 0
    fi
    die "echec de la commande WG_RESTART_CMD"
  fi

  if command -v systemctl >/dev/null 2>&1 \
    && systemctl list-unit-files --no-legend "${unit}" 2>/dev/null | grep -q .; then
    log warning "relance du service ${unit}"
    if run_root systemctl restart "${unit}"; then
      log info "service ${unit} relance"
      return 0
    fi
    die "echec de systemctl restart ${unit}"
  fi

  if command -v wg-quick >/dev/null 2>&1; then
    log warning "recreation de l'interface ${WG_INTERFACE} via wg-quick"
    run_root wg-quick down "${WG_INTERFACE}" || true
    if run_root wg-quick up "${WG_INTERFACE}"; then
      log info "interface ${WG_INTERFACE} recreee"
      return 0
    fi
    die "echec de wg-quick up ${WG_INTERFACE}"
  fi

  die "aucun moyen de relancer ${WG_INTERFACE} : definir WG_RESTART_CMD ou installer wg-quick"
}

main() {
  local target
  local failures
  local opt

  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -f | --force)
        WG_FORCE=1
        shift
        ;;
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

  require_tools
  require_uint WG_PING_COUNT "${WG_PING_COUNT}"
  require_uint WG_PING_TIMEOUT "${WG_PING_TIMEOUT}"
  require_uint WG_PING_INTERVAL "${WG_PING_INTERVAL}"
  require_uint WG_MAX_FAILURES "${WG_MAX_FAILURES}"
  require_uint WG_RESTART_DELAY "${WG_RESTART_DELAY}"
  if [[ "${WG_MAX_FAILURES}" -lt 1 ]]; then
    die "WG_MAX_FAILURES doit etre superieur ou egal a 1"
  fi
  if [[ "${WG_PING_COUNT}" -lt 1 ]]; then
    die "WG_PING_COUNT doit etre superieur ou egal a 1"
  fi
  if [[ "${WG_PING_TIMEOUT}" -lt 1 ]]; then
    die "WG_PING_TIMEOUT doit etre superieur ou egal a 1"
  fi

  lock_state
  check_ping_capability

  if ! target=$(resolve_target); then
    die "impossible de determiner la passerelle de ${WG_INTERFACE} : definir WG_PING_TARGET"
  fi

  if ! ip link show dev "${WG_INTERFACE}" >/dev/null 2>&1; then
    log warning "interface ${WG_INTERFACE} absente de l'hote"
  fi

  failures=$(read_state)

  if attempt_probe "${target}"; then
    if [[ "${failures}" -gt 0 ]]; then
      log info "tunnel ${WG_INTERFACE} de nouveau joignable apres ${failures} echec(s) consecutifs"
    fi
    write_state 0
    return 0
  fi

  failures=$((failures + 1))
  write_state "${failures}"
  log warning "echec du ping de ${target} via ${WG_INTERFACE} (${failures}/${WG_MAX_FAILURES})"

  if [[ "${failures}" -lt "${WG_MAX_FAILURES}" && "${WG_FORCE}" -eq 0 ]]; then
    log info "seuil de relance non atteint, nouvelle tentative au prochain passage"
    return 1
  fi

  restart_interface
  write_state 0
  sleep "${WG_RESTART_DELAY}"

  if attempt_probe "${target}"; then
    log info "tunnel ${WG_INTERFACE} relance et de nouveau joignable"
    return 0
  fi

  log err "tunnel ${WG_INTERFACE} toujours injoignable apres relance"
  return 2
}

main "$@"
