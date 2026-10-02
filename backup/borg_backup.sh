#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
BORG_BIN="${BORG_BIN:-borg}"

BORG_REPO="${BORG_REPO-/var/backups/borg/repo}"
BORG_PREFIX="${BORG_PREFIX-infra}"
BORG_ENCRYPTION="${BORG_ENCRYPTION-repokey-blake2}"
BORG_COMPRESSION="${BORG_COMPRESSION-auto,zstd,6}"
BACKUP_PATHS="${BACKUP_PATHS-/etc /opt /srv /home}"
BORG_EXCLUDES="${BORG_EXCLUDES:-}"
BORG_KEEP_DAILY="${BORG_KEEP_DAILY-7}"
BORG_KEEP_WEEKLY="${BORG_KEEP_WEEKLY-4}"
BORG_KEEP_MONTHLY="${BORG_KEEP_MONTHLY-12}"
BORG_CHECK_MODE="${BORG_CHECK_MODE-metadata}"
LOCK_FILE="${LOCK_FILE-/run/lock/borg-backup.lock}"
DRY_RUN=0

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-n]" \
    "" \
    "Sauvegarde chiffree BorgBackup : initialisation auto du depot, creation" \
    "d'archive, retention 3-2-1 (7J/4H/12M) puis verification d'integrite." \
    "" \
    "Options:" \
    "  -n, --dry-run   simulation de la creation (borg create --dry-run)" \
    "  -h, --help      affiche cette aide" \
    "" \
    "Variables d'environnement:" \
    "  BORG_REPO            depot local ou ssh://user@hote/chemin (defaut: ${BORG_REPO})" \
    "  BORG_PREFIX          prefixe des archives (defaut: ${BORG_PREFIX})" \
    "  BORG_ENCRYPTION      chiffrement a l'init (defaut: ${BORG_ENCRYPTION})" \
    "  BORG_COMPRESSION     algorithme de compression (defaut: ${BORG_COMPRESSION})" \
    "  BACKUP_PATHS          chemins a sauvegarder, separes par des espaces" \
    "                        (defaut: ${BACKUP_PATHS})" \
    "                        si defini mais vide, le script s'arrete en erreur" \
    "  BORG_EXCLUDES        motifs d'exclusion supplementaires" \
    "  BORG_KEEP_DAILY      copies journalieres conservees (defaut: ${BORG_KEEP_DAILY})" \
    "  BORG_KEEP_WEEKLY     copies hebdomadaires conservees (defaut: ${BORG_KEEP_WEEKLY})" \
    "  BORG_KEEP_MONTHLY    copies mensuelles conservees (defaut: ${BORG_KEEP_MONTHLY})" \
    "  BORG_CHECK_MODE      metadata | data | off (defaut: ${BORG_CHECK_MODE})" \
    "  LOCK_FILE            verrou d'execution (defaut: ${LOCK_FILE})" \
    "  BORG_PASSPHRASE      fournie par l'appelant, jamais par ce script" \
    "  BORG_PASSCOMMAND     commande de lecture du secret (alternative)" \
    "" \
    "Codes de retour: 0 OK, 1 avertissement borg, 2 erreur fatale"
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

require_tools() {
  local tool
  for tool in "${BORG_BIN}" date flock; do
    command -v "${tool}" >/dev/null 2>&1 || die "commande introuvable: ${tool}"
  done
}

check_auth() {
  if [[ -z "${BORG_PASSPHRASE:-}" && -z "${BORG_PASSCOMMAND:-}" ]]; then
    die "BORG_PASSPHRASE ou BORG_PASSCOMMAND doit etre fourni par l'environnement"
  fi
}

check_config() {
  local mode_ok=0
  [[ -n "${BORG_REPO}" ]] || die "BORG_REPO ne peut pas etre vide"
  [[ -n "${BORG_PREFIX}" ]] || die "BORG_PREFIX ne peut pas etre vide"
  [[ -n "${LOCK_FILE}" ]] || die "LOCK_FILE ne peut pas etre vide"
  case "${BORG_CHECK_MODE}" in
    metadata | data | off)
      mode_ok=1
      ;;
  esac
  [[ "${mode_ok}" -eq 1 ]] || die "BORG_CHECK_MODE invalide: ${BORG_CHECK_MODE}"
}

lock_repo() {
  if ! mkdir -p "$(dirname "${LOCK_FILE}")" 2>/dev/null; then
    die "repertoire du verrou inaccessible: $(dirname "${LOCK_FILE}")"
  fi
  if ! exec 9>"${LOCK_FILE}"; then
    die "ouverture du verrou impossible: ${LOCK_FILE}"
  fi
  if ! flock -n 9; then
    die "une sauvegarde est deja en cours (verrou: ${LOCK_FILE})"
  fi
}

ensure_repo() {
  if "${BORG_BIN}" info >/dev/null 2>&1; then
    return 0
  fi
  log info "depot ${BORG_REPO} absent ou inconnu, initialisation (${BORG_ENCRYPTION})"
  local init_rc=0
  "${BORG_BIN}" init --encryption="${BORG_ENCRYPTION}" "${BORG_REPO}" >/dev/null 2>&1 || init_rc=$?
  if [[ "${init_rc}" -ne 0 ]]; then
    if "${BORG_BIN}" info >/dev/null 2>&1; then
      log info "depot deja present et accessible"
      return 0
    fi
    die "depot ${BORG_REPO} inaccessible et initialisation impossible (rc=${init_rc})"
  fi
  log info "depot ${BORG_REPO} initialise"
}

select_paths() {
  local raw="${BACKUP_PATHS}"
  local candidate
  local -a split=()
  VALID_PATHS=()
  read -r -a split <<< "${raw}"
  for candidate in "${split[@]}"; do
    if [[ -e "${candidate}" ]]; then
      VALID_PATHS+=("${candidate}")
    else
      log warning "chemin ignore (introuvable): ${candidate}"
    fi
  done
  if [[ "${#VALID_PATHS[@]}" -eq 0 ]]; then
    die "aucun chemin de sauvegarde valide dans BACKUP_PATHS"
  fi
}

build_excludes() {
  EXCLUDE_ARGS=(
    --exclude-caches
    --exclude '*.pyc'
    --exclude '*/__pycache__'
    --exclude '*/.cache'
    --exclude '/var/cache'
    --exclude '*/.thumbnails'
    --exclude '*.swp'
    --exclude '*.tmp'
    --exclude '*.bak'
  )
  local -a extra=()
  local motif
  [[ -n "${BORG_EXCLUDES}" ]] || return 0
  read -r -a extra <<< "${BORG_EXCLUDES}"
  for motif in "${extra[@]}"; do
    EXCLUDE_ARGS+=(--exclude "${motif}")
  done
}

create_archive() {
  local archive
  local -a cmd
  local rc=0

  archive="${BORG_PREFIX}-$(date -u +%Y%m%dT%H%M%SZ)"

  select_paths
  build_excludes
  cmd=(
    "${BORG_BIN}" create
    --stats
    --show-rc
    --compression "${BORG_COMPRESSION}"
    "${EXCLUDE_ARGS[@]}"
  )
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    cmd+=(--dry-run)
  fi
  cmd+=("::${archive}" "${VALID_PATHS[@]}")

  log info "creation de l'archive ${archive} (${#VALID_PATHS[@]} chemin(s))"
  "${cmd[@]}" || rc=$?
  if [[ "${rc}" -ge 2 ]]; then
    die "echec de borg create (rc=${rc})"
  fi
  if [[ "${rc}" -eq 1 ]]; then
    log warning "borg create signale des avertissements (rc=1)"
  fi
  ARCHIVE_CREATED="${archive}"
}

prune_repo() {
  local rc=0
  log info "retention 3-2-1: ${BORG_KEEP_DAILY} jour(s), ${BORG_KEEP_WEEKLY} semaine(s), ${BORG_KEEP_MONTHLY} mois"
  "${BORG_BIN}" prune \
    --show-rc \
    --keep-daily "${BORG_KEEP_DAILY}" \
    --keep-weekly "${BORG_KEEP_WEEKLY}" \
    --keep-monthly "${BORG_KEEP_MONTHLY}" \
    --glob-archives "${BORG_PREFIX}-*" \
    || rc=$?
  if [[ "${rc}" -ge 2 ]]; then
    die "echec de borg prune (rc=${rc})"
  fi
}

check_repo() {
  local rc=0
  local -a cmd=("${BORG_BIN}" check --show-rc)
  case "${BORG_CHECK_MODE}" in
    off)
      log info "verification d'integrite desactivee (BORG_CHECK_MODE=off)"
      return 0
      ;;
    data)
      cmd+=(--verify-data)
      ;;
    metadata)
      ;;
    *)
      die "BORG_CHECK_MODE invalide: ${BORG_CHECK_MODE}"
      ;;
  esac
  log info "verification d'integrite (${BORG_CHECK_MODE})"
  "${cmd[@]}" || rc=$?
  if [[ "${rc}" -ge 2 ]]; then
    die "echec de borg check (rc=${rc})"
  fi
  if [[ "${rc}" -eq 1 ]]; then
    log warning "borg check a signale des anomalies (rc=1)"
  fi
}

main() {
  local opt
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -n | --dry-run)
        DRY_RUN=1
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
  check_auth
  lock_repo

  export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=no
  export BORG_RELOCATED_REPO_ACCESS_IS_OK=no

  ensure_repo
  create_archive

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log info "dry-run: prune et check ignores"
    return 0
  fi

  prune_repo
  check_repo
  log info "sauvegarde terminee: ${ARCHIVE_CREATED}"
}

ARCHIVE_CREATED=""
EXCLUDE_ARGS=()
VALID_PATHS=()
main "$@"
