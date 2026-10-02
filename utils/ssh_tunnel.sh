#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
SSH_BIN="${SSH_BIN:-ssh}"
TUNNEL_NAME="${TUNNEL_NAME-default}"
SOCKET_DIR="${SOCKET_DIR:-${XDG_RUNTIME_DIR:-/tmp}/ssh-tunnels}"
IDENTITY="${IDENTITY:-}"
JUMP="${JUMP:-}"
SSH_USER="${SSH_USER:-}"
SSH_PORT="${SSH_PORT:-}"
EXTRA_OPTS="${EXTRA_OPTS:-}"
DRY_RUN=0
LOCAL_FORWARDS=()
REMOTE_FORWARDS=()

usage() {
  printf '%s\n' \
    "Usage: ${PROG} <start|stop|status|restart> [OPTIONS] [user@hote]" \
    "" \
    "Gestion de tunnels SSH persistants via maitre de controle : socket" \
    "dedie, verrou d'instance par nom, forwards valides et arret" \
    "propre." \
    "" \
    "Commandes:" \
    "  start     ouvre le tunnel (idempotent si deja actif)" \
    "  stop      ferme le tunnel (succes meme si deja arrete)" \
    "  status    etat du tunnel (0 actif, 1 inactif)" \
    "  restart   stop puis start" \
    "" \
    "Options:" \
    "  -n, --name NOM       identifiant du tunnel (defaut: ${TUNNEL_NAME})" \
    "  -L, --local SPEC     forward local: [bind:]port:hote:port" \
    "  -R, --remote SPEC    forward distant: [bind:]port:hote:port" \
    "  -J, --jump HOTE      saut ProxyJump" \
    "  -i, --identity FILE  cle privee SSH" \
    "  -u, --user USER      utilisateur distant" \
    "  -p, --port PORT      port SSH distant" \
    "  -o, --option OPT     option ssh supplementaire (repetable)" \
    "  -S, --socket-dir DIR repertoire des sockets" \
    "      --dry-run        affiche la commande sans l'executer" \
    "  -h, --help           affiche cette aide" \
    "" \
    "Variables d'environnement:" \
    "  SSH_BIN              binaire ssh (defaut: ${SSH_BIN})" \
    "  TUNNEL_NAME          nom du tunnel (defaut: ${TUNNEL_NAME})" \
    "" \
    "Codes de retour: 0 OK, 1 inactif (status), 2 fatale, 64 usage"
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
  command -v "${SSH_BIN}" >/dev/null 2>&1 \
    || die "commande introuvable: ${SSH_BIN}"
}

check_name() {
  [[ "${TUNNEL_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
    || die "nom de tunnel invalide: ${TUNNEL_NAME}"
}

valid_port() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#${port} >= 1 && 10#${port} <= 65535 ))
}

split_spec() {
  local spec="$1"
  SPEC_PARTS=()
  IFS=':' read -r -a SPEC_PARTS <<< "${spec}"
}

validate_bind() {
  local bind="$1"
  local label="$2"
  local spec="$3"
  if [[ -n "${bind}" && ! "${bind}" =~ ^[A-Za-z0-9._%-]+$ ]]; then
    die "forward ${label} invalide (bind): ${spec}"
  fi
}

validate_host() {
  local host="$1"
  local label="$2"
  local spec="$3"
  [[ "${host}" =~ ^[A-Za-z0-9._%-]+$ ]] \
    || die "forward ${label} invalide (hote): ${spec}"
}

validate_forward() {
  local spec="$1"
  local label="$2"
  if [[ "${label}" == "local" && "${spec}" == /* ]]; then
    split_spec "${spec}"
    if [[ "${#SPEC_PARTS[@]}" -ne 3 ]]; then
      die "forward local invalide (socket): ${spec}"
    fi
    validate_host "${SPEC_PARTS[1]}" "${label}" "${spec}"
    valid_port "${SPEC_PARTS[2]}" \
      || die "forward local invalide (port): ${spec}"
    return 0
  fi
  split_spec "${spec}"
  case "${#SPEC_PARTS[@]}" in
    3)
      valid_port "${SPEC_PARTS[0]}" \
        || die "forward ${label} invalide (port): ${spec}"
      validate_host "${SPEC_PARTS[1]}" "${label}" "${spec}"
      valid_port "${SPEC_PARTS[2]}" \
        || die "forward ${label} invalide (port): ${spec}"
      ;;
    4)
      validate_bind "${SPEC_PARTS[0]}" "${label}" "${spec}"
      valid_port "${SPEC_PARTS[1]}" \
        || die "forward ${label} invalide (port): ${spec}"
      validate_host "${SPEC_PARTS[2]}" "${label}" "${spec}"
      valid_port "${SPEC_PARTS[3]}" \
        || die "forward ${label} invalide (port): ${spec}"
      ;;
    *)
      die "forward ${label} invalide (format): ${spec}"
      ;;
  esac
}

validate_local_spec() {
  validate_forward "$1" "local"
}

validate_remote_spec() {
  validate_forward "$1" "distant"
}

socket_path() {
  printf '%s/%s.sock' "${SOCKET_DIR}" "${TUNNEL_NAME}"
}

meta_path() {
  printf '%s/%s.meta' "${SOCKET_DIR}" "${TUNNEL_NAME}"
}

ensure_dir() {
  mkdir -p "${SOCKET_DIR}" 2>/dev/null \
    || die "repertoire de sockets inaccessible: ${SOCKET_DIR}"
  chmod 700 "${SOCKET_DIR}" 2>/dev/null || true
}

read_meta() {
  local key="$1"
  local file
  file="$(meta_path)"
  local line=""
  META_VALUE=""
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      "${key}="*)
        META_VALUE="${line#*=}"
        return 0
        ;;
    esac
  done < "${file}"
  return 1
}

write_meta() {
  local file
  file="$(meta_path)"
  {
    printf 'TARGET=%s\n' "${TARGET}"
    printf 'NAME=%s\n' "${TUNNEL_NAME}"
    printf 'LOCAL=%s\n' "${LOCAL_FORWARDS[*]-}"
    printf 'REMOTE=%s\n' "${REMOTE_FORWARDS[*]-}"
  } > "${file}"
  chmod 600 "${file}" 2>/dev/null || true
}

is_active() {
  local sock
  sock="$(socket_path)"
  local target="${TARGET:-}"
  if [[ -z "${target}" ]]; then
    if ! read_meta TARGET; then
      return 1
    fi
    target="${META_VALUE}"
  fi
  [[ -S "${sock}" ]] || return 1
  "${SSH_BIN}" -S "${sock}" -O check "${target}" >/dev/null 2>&1
}

build_ssh_command() {
  local sock
  sock="$(socket_path)"
  SSH_CMD=(
    "${SSH_BIN}"
    -f -N
    -M
    -S "${sock}"
    -o ExitOnForwardFailure=yes
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o ControlPersist=no
  )
  if [[ -n "${IDENTITY}" ]]; then
    SSH_CMD+=(-i "${IDENTITY}")
  fi
  if [[ -n "${SSH_PORT}" ]]; then
    SSH_CMD+=(-p "${SSH_PORT}")
  fi
  if [[ -n "${JUMP}" ]]; then
    SSH_CMD+=(-J "${JUMP}")
  fi
  local spec=""
  for spec in "${LOCAL_FORWARDS[@]}"; do
    SSH_CMD+=(-L "${spec}")
  done
  for spec in "${REMOTE_FORWARDS[@]}"; do
    SSH_CMD+=(-R "${spec}")
  done
  if [[ -n "${EXTRA_OPTS}" ]]; then
    local -a extra=()
    read -r -a extra <<< "${EXTRA_OPTS}"
    SSH_CMD+=("${extra[@]}")
  fi
  if [[ -n "${SSH_USER}" ]]; then
    SSH_CMD+=(-l "${SSH_USER}")
  fi
  SSH_CMD+=("${TARGET}")
}

command_start() {
  local spec=""
  [[ -n "${TARGET}" ]] || { usage >&2; return 64; }
  for spec in "${LOCAL_FORWARDS[@]}"; do
    validate_local_spec "${spec}"
  done
  for spec in "${REMOTE_FORWARDS[@]}"; do
    validate_remote_spec "${spec}"
  done
  if [[ "${#LOCAL_FORWARDS[@]}" -eq 0 && "${#REMOTE_FORWARDS[@]}" -eq 0 ]]; then
    die "au moins un forward -L ou -R requis"
  fi
  ensure_dir
  if is_active; then
    log info "tunnel deja actif: ${TUNNEL_NAME}"
    return 0
  fi
  rm -f "$(socket_path)" 2>/dev/null || true
  build_ssh_command
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf 'dry-run: %s\n' "${SSH_CMD[*]}"
    return 0
  fi
  "${SSH_CMD[@]}" || die "ouverture du tunnel impossible"
  write_meta
  log info "tunnel ouvert: ${TUNNEL_NAME} -> ${TARGET}"
}

command_stop() {
  local sock
  sock="$(socket_path)"
  local target="localhost"
  ensure_dir
  if read_meta TARGET; then
    target="${META_VALUE}"
  fi
  if ! is_active; then
    rm -f "${sock}" 2>/dev/null || true
    rm -f "$(meta_path)" 2>/dev/null || true
    log info "tunnel deja arrete: ${TUNNEL_NAME}"
    return 0
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf 'dry-run: fermeture de %s\n' "${sock}"
    return 0
  fi
  "${SSH_BIN}" -S "${sock}" -O exit "${target}" >/dev/null 2>&1 || true
  rm -f "${sock}" 2>/dev/null || true
  rm -f "$(meta_path)" 2>/dev/null || true
  log info "tunnel ferme: ${TUNNEL_NAME}"
  return 0
}

command_status() {
  local state="inactif"
  local target=""
  local local_list=""
  local remote_list=""
  if is_active; then
    state="actif"
  fi
  if read_meta TARGET; then
    target="${META_VALUE}"
  fi
  if read_meta LOCAL; then
    local_list="${META_VALUE}"
  fi
  if read_meta REMOTE; then
    remote_list="${META_VALUE}"
  fi
  printf '%s\n' \
    "Tunnel: ${TUNNEL_NAME} [${state}]" \
    "  socket:    $(socket_path)" \
    "  cible:     ${target:-inconnue}" \
    "  local:     ${local_list:-aucun}" \
    "  distant:   ${remote_list:-aucun}"
  if [[ "${state}" == "actif" ]]; then
    return 0
  fi
  return 1
}

parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n | --name)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        TUNNEL_NAME="$2"
        shift 2
        ;;
      -L | --local)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        LOCAL_FORWARDS+=("$2")
        shift 2
        ;;
      -R | --remote)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        REMOTE_FORWARDS+=("$2")
        shift 2
        ;;
      -J | --jump)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        JUMP="$2"
        shift 2
        ;;
      -i | --identity)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        IDENTITY="$2"
        shift 2
        ;;
      -u | --user)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        SSH_USER="$2"
        shift 2
        ;;
      -p | --port)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        SSH_PORT="$2"
        shift 2
        ;;
      -o | --option)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        if [[ -n "${EXTRA_OPTS}" ]]; then
          EXTRA_OPTS="${EXTRA_OPTS} $2"
        else
          EXTRA_OPTS="$2"
        fi
        shift 2
        ;;
      -S | --socket-dir)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        SOCKET_DIR="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*)
        printf 'Option inconnue: %s\n' "$1" >&2
        usage >&2
        return 64
        ;;
      *)
        if [[ -n "${TARGET}" ]]; then
          printf 'Argument inattendu: %s\n' "$1" >&2
          usage >&2
          return 64
        fi
        TARGET="$1"
        shift
        ;;
    esac
  done
  return 0
}

main() {
  local command="${1:-}"
  if [[ -z "${command}" ]]; then
    usage >&2
    return 64
  fi
  shift
  case "${command}" in
    -h | --help)
      usage
      return 0
      ;;
    start | stop | status | restart) ;;
    *)
      printf 'Commande inconnue: %s\n' "${command}" >&2
      usage >&2
      return 64
      ;;
  esac

  parse_options "$@" || return $?
  require_tools
  check_name

  case "${command}" in
    start)
      command_start
      ;;
    stop)
      command_stop
      ;;
    status)
      command_status
      ;;
    restart)
      command_stop
      command_start
      ;;
  esac
}

TARGET=""
META_VALUE=""
SSH_CMD=()
SPEC_PARTS=()
main "$@"
