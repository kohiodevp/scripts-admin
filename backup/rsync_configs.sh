#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
RSYNC_BIN="${RSYNC_BIN:-rsync}"
RSYNC_DEST="${RSYNC_DEST:-}"
RSYNC_EXCLUDES="${RSYNC_EXCLUDES:-.git .cache *.bak *.tmp *.swp}"
LOCK_FILE="${LOCK_FILE-/run/lock/rsync-configs.lock}"
DELETE=0
DRY_RUN=0

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-n] [--delete] [-d DEST] [SRC...]" \
    "" \
    "Miroir des configurations vers une destination locale ou distante." \
    "Les chemins absolus sont reproanches sous la destination (convention" \
    "identique a borg extract), avec verrou d'execution et statistiques." \
    "" \
    "Options:" \
    "  -d, --dest DEST   destination rsync (defaut: \$RSYNC_DEST)" \
    "      --delete      supprime a la destination les fichiers sources absents" \
    "  -n, --dry-run     simulation sans ecriture" \
    "  -h, --help        affiche cette aide" \
    "" \
    "Arguments:" \
    "  SRC               chemins a mirroring (defaut: /etc)" \
    "" \
    "Variables d'environnement:" \
    "  RSYNC_DEST        destination (defaut: ${RSYNC_DEST:-non definie})" \
    "  RSYNC_EXCLUDES    motifs excludes, separes par espaces" \
    "                    (defaut: ${RSYNC_EXCLUDES})" \
    "  LOCK_FILE         verrou d'execution (defaut: ${LOCK_FILE})" \
    "" \
    "Codes de retour: 0 OK, 1 fichiers ignores, 2 erreur fatale"
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
  local tool
  for tool in "${RSYNC_BIN}" flock; do
    command -v "${tool}" >/dev/null 2>&1 \
      || die "commande introuvable: ${tool}"
  done
}

check_config() {
  local source=""
  [[ -n "${RSYNC_DEST}" ]] || die "destination absente (-d ou RSYNC_DEST)"
  if [[ "${#SOURCES[@]}" -eq 0 ]]; then
    SOURCES=("/etc")
  fi
  for source in "${SOURCES[@]}"; do
    [[ -e "${source}" ]] || die "source introuvable: ${source}"
  done
}

lock_run() {
  mkdir -p "$(dirname "${LOCK_FILE}")" 2>/dev/null \
    || die "repertoire du verrou inaccessible: $(dirname "${LOCK_FILE}")"
  exec 9>"${LOCK_FILE}" || die "ouverture du verrou impossible"
  flock -n 9 || die "une synchronisation est deja en cours"
}

build_excludes() {
  local -a extra=()
  local motif=""
  EXCLUDE_ARGS=()
  [[ -n "${RSYNC_EXCLUDES}" ]] || return 0
  read -r -a extra <<< "${RSYNC_EXCLUDES}"
  for motif in "${extra[@]}"; do
    [[ -n "${motif}" ]] || continue
    EXCLUDE_ARGS+=(--exclude "${motif}")
  done
}

run_rsync() {
  local rc=0
  local -a cmd=(
    "${RSYNC_BIN}"
    --archive
    --relative
    --human-readable
    --stats
    --partial
    --delay-updates
    --itemize-changes
  )
  if [[ "${DELETE}" -eq 1 ]]; then
    cmd+=(--delete)
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    cmd+=(--dry-run)
  fi
  if [[ "${#EXCLUDE_ARGS[@]}" -gt 0 ]]; then
    cmd+=("${EXCLUDE_ARGS[@]}")
  fi
  cmd+=("${SOURCES[@]}" "${RSYNC_DEST}")

  log info "synchronisation de ${#SOURCES[@]} source(s) vers ${RSYNC_DEST}"
  RSYNC_OUTPUT="$("${cmd[@]}" 2>&1)" || rc=$?
  if [[ "${rc}" -ge 2 ]]; then
    printf '%s\n' "${RSYNC_OUTPUT}" >&2
    die "echec rsync (rc=${rc})"
  fi
  if [[ "${rc}" -eq 1 ]]; then
    log warning "rsync signale des erreurs partielles (rc=1)"
  fi
}

report() {
  local transferred=""
  local created=""
  local deleted=""
  transferred="$(printf '%s\n' "${RSYNC_OUTPUT}" \
    | awk -F'[ ()]+' '/Total transferred file size/ { print $6; exit }')" \
    || true
  created="$(printf '%s\n' "${RSYNC_OUTPUT}" \
    | grep -c '^>f' )" || true
  deleted="$(printf '%s\n' "${RSYNC_OUTPUT}" \
    | grep -c '^\*deleting' )" || true
  printf '%s\n' \
    "Miroir ${DRY_RUN:+(dry-run)}${DRY_RUN} termine" \
    "  destination:  ${RSYNC_DEST}" \
    "  fichiers ecrits/transferes: ${created}" \
    "  suppression:  ${deleted}" \
    "  taille:       ${transferred:-0}"
  if [[ "${RSYNC_OUTPUT}" == *"skipping non-regular file"* ]]; then
    log warning "fichiers non reguliers ignores"
    return 1
  fi
  return 0
}

main() {
  local opt=""
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -d | --dest)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        RSYNC_DEST="$2"
        shift 2
        ;;
      --delete)
        DELETE=1
        shift
        ;;
      -n | --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      --)
        shift
        SOURCES+=("$@")
        break
        ;;
      -*)
        printf 'Option inconnue: %s\n' "${opt}" >&2
        usage >&2
        return 64
        ;;
      *)
        SOURCES+=("$1")
        shift
        ;;
    esac
  done

  require_tools
  check_config
  lock_run
  build_excludes
  run_rsync
  report
}

SOURCES=()
EXCLUDE_ARGS=()
RSYNC_OUTPUT=""
main "$@"
