#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
BORG_BIN="${BORG_BIN:-borg}"
BORG_REPO="${BORG_REPO-/var/backups/borg/repo}"
BORG_PREFIX="${BORG_PREFIX-infra}"
BACKUP_PATHS="${BACKUP_PATHS-/etc /opt /srv /home}"
RESTORE_DIR="${RESTORE_DIR:-}"
ARCHIVE="${ARCHIVE:-}"
KEEP=0
DRY_RUN=0

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-n] [-k] [-a ARCHIVE] [-d DOSSIER]" \
    "" \
    "Test de restauration hors-ligne d'une archive BorgBackup :" \
    "extrait la derniere archive (ou une archive choisie) dans un" \
    "repertoire temporaire, verifie la reconstruction des chemins" \
    "sauvegardes puis nettoie. Aucune donnee existante n'est modifiee." \
    "" \
    "Options:" \
    "  -a, --archive NOM   archive a tester (defaut: derniere ${BORG_PREFIX}-*)" \
    "  -d, --dir DOSSIER   destination du test (defaut: mktemp -d)" \
    "  -k, --keep          conserve le dossier de restauration" \
    "  -n, --dry-run       liste l'archive sans extraire" \
    "  -h, --help          affiche cette aide" \
    "" \
    "Variables d'environnement:" \
    "  BORG_REPO           depot BorgBackup (defaut: ${BORG_REPO})" \
    "  BORG_PREFIX         prefixe des archives (defaut: ${BORG_PREFIX})" \
    "  BACKUP_PATHS        chemins attendus dans l'archive" \
    "  BORG_PASSPHRASE     fournie par l'appelant, jamais par ce script" \
    "  BORG_PASSCOMMAND    commande de lecture du secret (alternative)" \
    "" \
    "Codes de retour: 0 OK, 1 restauration incomplète, 2 erreur fatale"
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
  for tool in "${BORG_BIN}" mktemp find; do
    command -v "${tool}" >/dev/null 2>&1 \
      || die "commande introuvable: ${tool}"
  done
}

check_auth() {
  if [[ -z "${BORG_PASSPHRASE:-}" && -z "${BORG_PASSCOMMAND:-}" ]]; then
    die "BORG_PASSPHRASE ou BORG_PASSCOMMAND doit etre fourni"
  fi
}

select_paths() {
  local candidate
  local -a split=()
  VALID_PATHS=()
  read -r -a split <<< "${BACKUP_PATHS}"
  for candidate in "${split[@]}"; do
    if [[ -e "${candidate}" ]]; then
      VALID_PATHS+=("${candidate}")
    else
      log warning "chemin ignore (introuvable): ${candidate}"
    fi
  done
  if [[ "${#VALID_PATHS[@]}" -eq 0 ]]; then
    die "aucun chemin valide dans BACKUP_PATHS"
  fi
}

resolve_archive() {
  local found=""
  if [[ -n "${ARCHIVE}" ]]; then
    found="${ARCHIVE}"
  else
    found="$("${BORG_BIN}" list --short "${BORG_REPO}" \
      "${BORG_PREFIX}-*" 2>/dev/null | sort | tail -n 1)" || true
  fi
  [[ -n "${found}" ]] || die "aucune archive ${BORG_PREFIX}-* dans ${BORG_REPO}"
  ARCHIVE="${found}"
}

resolve_dest() {
  if [[ -n "${RESTORE_DIR}" ]]; then
    DEST_DIR="${RESTORE_DIR}"
    mkdir -p "${DEST_DIR}" || die "creation impossible: ${DEST_DIR}"
    OWN_DEST=0
  else
    DEST_DIR="$(mktemp -d /tmp/restore-test.XXXXXX)" \
      || die "mktemp impossible"
    OWN_DEST=1
  fi
}

cleanup() {
  if [[ "${OWN_DEST}" -eq 1 && "${KEEP}" -eq 0 ]]; then
    rm -rf "${DEST_DIR}" 2>/dev/null || true
    log info "dossier de test supprime"
  elif [[ "${KEEP}" -eq 1 ]]; then
    log info "restauration conservee: ${DEST_DIR}"
  fi
}

archive_inventory() {
  local count=0
  count="$("${BORG_BIN}" list --short "${BORG_REPO}" "${ARCHIVE}" \
    | wc -l)" || true
  log info "archive ${ARCHIVE}: ${count} entree(s)"
  if [[ "${count}" -eq 0 ]]; then
    die "archive vide ou illisible: ${ARCHIVE}"
  fi
}

extract_archive() {
  log info "extraction de ${ARCHIVE} vers ${DEST_DIR}"
  if ! (
    cd "${DEST_DIR}"
    "${BORG_BIN}" extract "${BORG_REPO}::${ARCHIVE}"
  ); then
    die "echec de borg extract pour ${ARCHIVE}"
  fi
}

verify_entries() {
  local entry=""
  local restored=""
  local archived=0
  local lost=0

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    archived=$((archived + 1))
    restored="${DEST_DIR}/${entry}"
    if [[ ! -e "${restored}" ]]; then
      log err "entree absente de la restauration: ${entry}"
      lost=$((lost + 1))
    fi
  done < <(
    "${BORG_BIN}" list --short "${BORG_REPO}" "${ARCHIVE}" 2>/dev/null
  )

  ENTRY_TOTAL="${archived}"
  ENTRY_MISSING="${lost}"
  if [[ "${archived}" -eq 0 ]]; then
    log err "inventaire d'archive vide"
    ENTRY_MISSING=1
  fi
}

verify_restore() {
  local path=""
  local restored=""
  local expected_kind=""
  local restored_kind=""
  local missing=0
  local mismatch=0
  local files=0

  files="$(find "${DEST_DIR}" -type f 2>/dev/null | wc -l)"
  if [[ "${files}" -eq 0 ]]; then
    log err "verification: aucun fichier restaure"
    MISSING_COUNT=1
    RESTORED_FILES=0
    return 0
  fi

  verify_entries
  missing="${ENTRY_MISSING}"

  for path in "${VALID_PATHS[@]}"; do
    restored="${DEST_DIR}${path}"
    if [[ ! -e "${restored}" ]]; then
      log err "chemin absent de la restauration: ${path}"
      missing=$((missing + 1))
      continue
    fi
    if [[ -d "${path}" ]]; then
      expected_kind="repertoire"
    else
      expected_kind="fichier"
    fi
    if [[ -d "${restored}" ]]; then
      restored_kind="repertoire"
    else
      restored_kind="fichier"
    fi
    if [[ "${expected_kind}" != "${restored_kind}" ]]; then
      log err "nature divergente pour ${path}: ${expected_kind} -> ${restored_kind}"
      mismatch=$((mismatch + 1))
    fi
  done

  RESTORED_FILES="${files}"
  MISSING_COUNT="${missing}"
  MISMATCH_COUNT="${mismatch}"
}

report() {
  local status="OK"
  if [[ "${MISSING_COUNT}" -gt 0 || "${MISMATCH_COUNT}" -gt 0 ]]; then
    status="INCOMPLETE"
  fi
  printf '%s\n' \
    "Test de restauration: ${status}" \
    "  depot:      ${BORG_REPO}" \
    "  archive:    ${ARCHIVE}" \
    "  fichiers:   ${RESTORED_FILES}" \
    "  entrees:    ${ENTRY_TOTAL}" \
    "  absents:    ${MISSING_COUNT}" \
    "  divergents: ${MISMATCH_COUNT}"
  if [[ "${status}" == "OK" ]]; then
    return 0
  fi
  return 1
}

main() {
  local opt
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -a | --archive)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        ARCHIVE="$2"
        shift 2
        ;;
      -d | --dir)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        RESTORE_DIR="$2"
        shift 2
        ;;
      -k | --keep)
        KEEP=1
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
      *)
        printf 'Option inconnue: %s\n' "${opt}" >&2
        usage >&2
        return 64
        ;;
    esac
  done

  require_tools
  check_auth
  select_paths
  resolve_archive

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    archive_inventory
    log info "dry-run: extraction non effectuee"
    return 0
  fi

  resolve_dest
  trap cleanup EXIT
  archive_inventory
  extract_archive
  verify_restore
  report
}

DEST_DIR=""
OWN_DEST=0
RESTORED_FILES=0
MISSING_COUNT=0
MISMATCH_COUNT=0
ENTRY_TOTAL=0
ENTRY_MISSING=0
VALID_PATHS=()
main "$@"
