#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
VAULT_FILE="${VAULT_FILE:-./secrets.env}"
KEY_LENGTH="${KEY_LENGTH-32}"
HOOK="${HOOK:-}"
EXECUTE=0
CHECK=0

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-f FICHIER] [-k CLE] [-l OCTETS]" \
    "              [--hook COMMANDE] [--check] [--execute]" \
    "" \
    "Rotation d'un secret dans un fichier de type .env. Par defaut :" \
    "simulation. Avec --execute : generation locale (OpenSSL)," \
    "remplacement atomique de la ligne CLE=, sauvegarde de l'ancien" \
    "fichier puis hook optionnel." \
    "" \
    "La valeur n'est jamais affichee ni journalisee : seul son nom et" \
    "sa longueur sont rapportes." \
    "" \
    "Options:" \
    "  -f, --file FICHIER   fichier cible (defaut: ${VAULT_FILE})" \
    "  -k, --key CLE        nom de la variable (requis)" \
    "  -l, --length OCTETS  entropie en octets (defaut: ${KEY_LENGTH})" \
    "      --hook COMMANDE  commande executee apres rotation" \
    "      --check          verifie la presence et la longueur (lecture)" \
    "      --execute        effectue la rotation (sinon simulation)" \
    "  -h, --help           affiche cette aide" \
    "" \
    "Variables d'environnement:" \
    "  VAULT_FILE           fichier cible (defaut: ${VAULT_FILE})" \
    "  KEY_LENGTH           entropie en octets (defaut: ${KEY_LENGTH})" \
    "" \
    "Codes de retour: 0 OK, 1 verification ou hook en echec, 2 fatale"
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
  for tool in "${OPENSSL_BIN}" awk; do
    command -v "${tool}" >/dev/null 2>&1 \
      || die "commande introuvable: ${tool}"
  done
}

check_config() {
  [[ -n "${KEY}" ]] || die "cle requise (-k)"
  [[ "${KEY}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || die "nom de cle invalide: ${KEY}"
  [[ "${KEY_LENGTH}" =~ ^[0-9]+$ && "${KEY_LENGTH}" -ge 16 ]] \
    || die "longueur invalide (min 16): ${KEY_LENGTH}"
}

key_line_count() {
  local count=0
  if [[ -f "${VAULT_FILE}" ]]; then
    count="$(grep -c "^${KEY}=" "${VAULT_FILE}" 2>/dev/null)" || true
    count="$(printf '%s' "${count}" | tr -cd '0-9')"
  fi
  printf '%s' "${count:-0}"
}

current_length() {
  local line=""
  if [[ ! -f "${VAULT_FILE}" ]]; then
    printf '0'
    return 0
  fi
  line="$(grep -m1 "^${KEY}=" "${VAULT_FILE}" 2>/dev/null)" || true
  if [[ -z "${line}" ]]; then
    printf '0'
    return 0
  fi
  printf '%s' "${line#*=}" | wc -c | tr -cd '0-9'
}

generate_value() {
  local raw=""
  raw="$("${OPENSSL_BIN}" rand -base64 "${KEY_LENGTH}")" \
    || die "generation aleatoire impossible"
  NEW_VALUE="$(printf '%s' "${raw}" | tr -d '\n')"
  if [[ "${#NEW_VALUE}" -lt 32 ]]; then
    die "valeur generee trop courte"
  fi
}

backup_file() {
  local stamp=""
  if [[ ! -f "${VAULT_FILE}" ]]; then
    return 0
  fi
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p -- "${VAULT_FILE}" "${VAULT_FILE}.bak.${stamp}" \
    || die "sauvegarde impossible"
  log info "sauvegarde: ${VAULT_FILE}.bak.${stamp}"
}

rewrite_file() {
  local tmp="${VAULT_FILE}.tmp.$$"
  local line=""
  local replaced=0

  if [[ -f "${VAULT_FILE}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        "${KEY}="*)
          if [[ "${replaced}" -eq 0 ]]; then
            printf '%s=%s\n' "${KEY}" "${NEW_VALUE}" >> "${tmp}"
            replaced=1
          fi
          ;;
        *)
          printf '%s\n' "${line}" >> "${tmp}"
          ;;
      esac
    done < "${VAULT_FILE}"
  fi
  if [[ "${replaced}" -eq 0 ]]; then
    printf '%s=%s\n' "${KEY}" "${NEW_VALUE}" >> "${tmp}"
  fi
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${VAULT_FILE}"
  log info "rotation appliquee: ${KEY} (longueur=${#NEW_VALUE})"
}

run_hook() {
  local rc=0
  [[ -n "${HOOK}" ]] || return 0
  log info "execution du hook"
  sh -c "${HOOK}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log warning "hook en echec (rc=${rc})"
    return 1
  fi
  return 0
}

do_check() {
  local length=""
  local lines=""
  lines="$(key_line_count)"
  length="$(current_length)"
  if [[ "${lines}" == "0" ]]; then
    printf 'absente: cle=%s fichier=%s\n' "${KEY}" "${VAULT_FILE}"
    return 1
  fi
  if [[ "${lines}" != "1" ]]; then
    printf 'doublon: cle=%s lignes=%s\n' "${KEY}" "${lines}"
    return 1
  fi
  if [[ "${length}" -lt "${KEY_LENGTH}" ]]; then
    printf 'faible: cle=%s longueur=%s (min %s)\n' \
      "${KEY}" "${length}" "${KEY_LENGTH}"
    return 1
  fi
  printf 'presente: cle=%s longueur=%s\n' "${KEY}" "${length}"
  return 0
}

simulate() {
  local lines=""
  local action="ajout"
  lines="$(key_line_count)"
  if [[ "${lines}" != "0" ]]; then
    action="remplacement"
  fi
  printf '%s\n' \
    "Simulation de rotation (aucune modification)" \
    "  fichier:  ${VAULT_FILE}" \
    "  cle:      ${KEY}" \
    "  action:   ${action}" \
    "  entropie: ${KEY_LENGTH} octets"
}

main() {
  local opt=""
  local rc=0
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -f | --file)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        VAULT_FILE="$2"
        shift 2
        ;;
      -k | --key)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        KEY="$2"
        shift 2
        ;;
      -l | --length)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        KEY_LENGTH="$2"
        shift 2
        ;;
      --hook)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        HOOK="$2"
        shift 2
        ;;
      --check)
        CHECK=1
        shift
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

  if [[ "${CHECK}" -eq 1 ]]; then
    do_check || return 1
    return 0
  fi
  if [[ "${EXECUTE}" -eq 0 ]]; then
    simulate
    return 0
  fi

  generate_value
  backup_file
  rewrite_file
  run_hook || rc=1
  do_check || rc=1
  return "${rc}"
}

KEY=""
NEW_VALUE=""
main "$@"
