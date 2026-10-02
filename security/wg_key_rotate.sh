#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
WG_BIN="${WG_BIN:-wg}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_CONFIG="${WG_CONFIG:-}"
ALIAS_FILE="${ALIAS_FILE:-}"
PSK_FILE="${PSK_FILE:-}"
EXECUTE=0

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-i IFACE] [-p PEER] [-a FICHIER] [--psk FICHIER]" \
    "              [-c FICHIER] [--execute]" \
    "" \
    "Rotation de cle de pair WireGuard. Par defaut : simulation (aucune" \
    "modification). Avec --execute : generation locale d'une nouvelle" \
    "paire, retrait de l'ancien pair, reajout sous la nouvelle cle en" \
    "conservant allowed-ips, endpoint et keepalive, puis sauvegarde de" \
    "la configuration." \
    "" \
    "La cle privee n'est jamais affichee ni journalisee : seule la cle" \
    "publique resultat est rapportee." \
    "" \
    "Options:" \
    "  -i, --interface IFACE  interface wg (defaut: ${WG_INTERFACE})" \
    "  -p, --peer PEER        cle publique du pair, ou alias @nom" \
    "  -a, --alias-file FILE  correspondances '@nom cle_publique'" \
    "      --psk FILE         fichier de cle pre-partagee a conserver" \
    "  -c, --config FICHIER   configuration wg-quick a sauvegarder" \
    "      --execute          effectue la rotation (sinon simulation)" \
    "  -h, --help             affiche cette aide" \
    "" \
    "Variables d'environnement:" \
    "  WG_INTERFACE           interface (defaut: ${WG_INTERFACE})" \
    "  ALIAS_FILE             fichier d'alias (defaut: ${ALIAS_FILE:-vide})" \
    "" \
    "Codes de retour: 0 OK ou simulation, 2 erreur fatale"
}

log() {
  local priority="$1"
  shift
  printf '%s %s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${priority^^}" "$PROG" "$*" >&2
  logger -p "user.${priority}" -t "$PROG" -- "$*" 2>/dev/null || true
}

die() {
  log err "$*"
  exit 2
}

require_tools() {
  command -v "${WG_BIN}" >/dev/null 2>&1 \
    || die "commande introuvable: ${WG_BIN}"
}

check_config() {
  [[ -n "${PEER}" ]] || die "pair requis (-p, cle publique ou @alias)"
  "${WG_BIN}" show "${WG_INTERFACE}" >/dev/null 2>&1 \
    || die "interface WireGuard inaccessible: ${WG_INTERFACE}"
  if [[ "${PEER}" == @* ]]; then
    resolve_alias
  fi
  [[ "${PEER}" =~ ^[A-Za-z0-9+/]{42,44}=?$ ]] \
    || die "cle publique invalide: ${PEER}"
  if [[ -n "${PSK_FILE}" && ! -r "${PSK_FILE}" ]]; then
    die "fichier psk illisible: ${PSK_FILE}"
  fi
}

resolve_alias() {
  local alias_name="${PEER#@}"
  local line=""
  local name=""
  local key=""
  [[ -n "${ALIAS_FILE}" ]] || die "alias ${PEER} mais ALIAS_FILE vide"
  [[ -r "${ALIAS_FILE}" ]] || die "fichier alias illisible: ${ALIAS_FILE}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
      \#*) continue ;;
    esac
    read -r name key <<< "${line}"
    if [[ "${name}" == "${alias_name}" ]]; then
      PEER="${key}"
      return 0
    fi
  done < "${ALIAS_FILE}"
  die "alias introuvable: ${alias_name}"
}

peer_present() {
  local listed=""
  listed="$("${WG_BIN}" show "${WG_INTERFACE}" peers 2>/dev/null)" || true
  printf '%s\n' "${listed}" | grep -qFx "${PEER}"
}

peer_setting() {
  local getter="$1"
  "${WG_BIN}" show "${WG_INTERFACE}" "${getter}" "${PEER}" 2>/dev/null || true
}

generate_keys() {
  TMP_DIR="$(mktemp -d /tmp/wg-rotate.XXXXXX)" \
    || die "mktemp impossible"
  "${WG_BIN}" genkey > "${TMP_DIR}/private"
  "${WG_BIN}" pubkey < "${TMP_DIR}/private" > "${TMP_DIR}/public"
  NEW_PEER="$(tr -d '\n' < "${TMP_DIR}/public")"
  [[ -n "${NEW_PEER}" ]] || die "generation de cle impossible"
}

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    if command -v shred >/dev/null 2>&1; then
      shred -u "${TMP_DIR}/private" 2>/dev/null || true
    fi
    rm -rf "${TMP_DIR}" 2>/dev/null || true
  fi
}

plan() {
  local allowed=""
  local endpoint=""
  local keepalive=""
  allowed="$(peer_setting allowed-ips)"
  endpoint="$(peer_setting endpoint)"
  keepalive="$(peer_setting persistent-keepalive)"
  printf '%s\n' \
    "Simulation de rotation (aucune modification)" \
    "  interface:    ${WG_INTERFACE}" \
    "  ancienne cle: ${PEER}" \
    "  allowed-ips:  ${allowed:-aucun}" \
    "  endpoint:     ${endpoint:-aucun}" \
    "  keepalive:    ${keepalive:-0}" \
    "  psk:          ${PSK_FILE:-non fourni}" \
    "  actions:      generer paire, retirer l'ancien pair," \
    "                reajouter sous la nouvelle cle, sauvegarder"
}

apply() {
  local allowed=""
  local endpoint=""
  local keepalive=""
  local -a set_args=()

  allowed="$(peer_setting allowed-ips)"
  endpoint="$(peer_setting endpoint)"
  keepalive="$(peer_setting persistent-keepalive)"

  generate_keys
  trap cleanup EXIT

  "${WG_BIN}" set "${WG_INTERFACE}" peer "${PEER}" remove
  log info "ancien pair retire"

  set_args=("${WG_INTERFACE}" peer "${NEW_PEER}")
  if [[ -n "${allowed}" ]]; then
    set_args+=(allowed-ips "${allowed}")
  fi
  if [[ -n "${endpoint}" ]]; then
    set_args+=(endpoint "${endpoint}")
  fi
  if [[ -n "${keepalive}" && "${keepalive}" != "0" ]]; then
    set_args+=(persistent-keepalive "${keepalive}")
  fi
  if [[ -n "${PSK_FILE}" ]]; then
    set_args+=(preshared-key "${PSK_FILE}")
  fi
  "${WG_BIN}" set "${set_args[@]}"
  log info "nouveau pair ajoute"

  if [[ -n "${WG_CONFIG}" ]]; then
    [[ -f "${WG_CONFIG}" ]] || die "configuration introuvable: ${WG_CONFIG}"
    if command -v wg-quick >/dev/null 2>&1; then
      wg-quick save "${WG_INTERFACE}" >/dev/null \
        || die "sauvegarde wg-quick impossible"
      log info "configuration sauvegardee: ${WG_CONFIG}"
    else
      log warning "wg-quick absent, sauvegarde ignoree"
    fi
  fi

  cleanup
  trap - EXIT
  printf '%s\n' \
    "Rotation terminee" \
    "  interface:    ${WG_INTERFACE}" \
    "  nouvelle cle: ${NEW_PEER}" \
    "  ancienne cle: ${PEER} (retiree)"
}

main() {
  local opt=""
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -i | --interface)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        WG_INTERFACE="$2"
        shift 2
        ;;
      -p | --peer)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        PEER="$2"
        shift 2
        ;;
      -a | --alias-file)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        ALIAS_FILE="$2"
        shift 2
        ;;
      --psk)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        PSK_FILE="$2"
        shift 2
        ;;
      -c | --config)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        WG_CONFIG="$2"
        shift 2
        ;;
      --execute)
        EXECUTE=1
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
  check_config
  peer_present || die "pair absent de ${WG_INTERFACE}: ${PEER}"

  if [[ "${EXECUTE}" -eq 0 ]]; then
    plan
    return 0
  fi
  apply
}

TMP_DIR=""
PEER=""
main "$@"
