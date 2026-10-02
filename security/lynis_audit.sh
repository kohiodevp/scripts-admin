#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
LYNIS_BIN="${LYNIS_BIN:-lynis}"
LYNIS_MIN_INDEX="${LYNIS_MIN_INDEX-70}"
LYNIS_LOG="${LYNIS_LOG:-}"
MODE="quick"

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-p] [-m INDICE] [-o FICHIER]" \
    "" \
    "Audit Lynis en lecture seule : execute un scan, conserve la sortie" \
    "complete dans un journal puis compare l'indice de durcissement au" \
    "seuil attendu." \
    "" \
    "Options:" \
    "  -p, --pentest     audit pentest au lieu du mode rapide" \
    "  -m, --min INDICE  indice minimal acceptable (defaut: ${LYNIS_MIN_INDEX})" \
    "  -o, --output FILE journal de sortie (defaut: lynis-\$DATE.log)" \
    "  -h, --help        affiche cette aide" \
    "" \
    "Variables d'environnement:" \
    "  LYNIS_BIN         binaire lynis (defaut: ${LYNIS_BIN})" \
    "  LYNIS_MIN_INDEX   seuil de durcissement (defaut: ${LYNIS_MIN_INDEX})" \
    "" \
    "Codes de retour: 0 conforme, 1 sous le seuil, 2 erreur fatale"
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
  for tool in "${LYNIS_BIN}" grep awk; do
    command -v "${tool}" >/dev/null 2>&1 \
      || die "commande introuvable: ${tool}"
  done
}

check_config() {
  [[ "${LYNIS_MIN_INDEX}" =~ ^[0-9]+$ ]] || die "indice invalide: ${LYNIS_MIN_INDEX}"
  if [[ -z "${LYNIS_LOG}" ]]; then
    LYNIS_LOG="/var/log/lynis-${PROG%.sh}-$(date -u +%Y%m%dT%H%M%SZ).log"
    if ! touch "${LYNIS_LOG}" 2>/dev/null; then
      LYNIS_LOG="${TMPDIR:-/tmp}/lynis-${PROG%.sh}-$(date -u +%Y%m%dT%H%M%SZ).log"
    fi
  fi
  touch "${LYNIS_LOG}" 2>/dev/null || die "journal inaccessible: ${LYNIS_LOG}"
}

run_lynis() {
  local rc=0
  local -a cmd=("${LYNIS_BIN}" audit system)
  if [[ "${MODE}" == "pentest" ]]; then
    cmd+=(--pentest)
  else
    cmd+=(--quick)
  fi
  log info "execution de: ${cmd[*]}"
  "${cmd[@]}" > "${LYNIS_LOG}" 2>&1 || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    tail -n 20 "${LYNIS_LOG}" >&2 || true
    die "echec de lynis (rc=${rc})"
  fi
}

parse_report() {
  local line=""
  local pattern=""
  HARDENING=""
  TESTS=""
  PLUGINS=""
  for pattern in "Hardening index" "Tests performed" "Plugins enabled"; do
    line="$(grep -m1 -i "${pattern}" "${LYNIS_LOG}" 2>/dev/null)" || true
    case "${pattern}" in
      "Hardening index")
        HARDENING="$(first_number "${line}")"
        ;;
      "Tests performed")
        TESTS="$(first_number "${line}")"
        ;;
      "Plugins enabled")
        PLUGINS="$(first_number "${line}")"
        ;;
    esac
  done
  SUGGESTIONS="$(grep -c -i 'suggestion' "${LYNIS_LOG}" 2>/dev/null)" || true
  SUGGESTIONS="$(printf '%s' "${SUGGESTIONS}" | tr -cd '0-9')"
  WARNINGS="$(grep -c -i '\[WARNING\]' "${LYNIS_LOG}" 2>/dev/null)" || true
  WARNINGS="$(printf '%s' "${WARNINGS}" | tr -cd '0-9')"
}

first_number() {
  printf '%s' "$1" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^[0-9]+$/) {
        print $i
        exit
      }
    }
  }'
}

report() {
  printf '%s\n' \
    "Audit Lynis (${MODE})" \
    "  journal:      ${LYNIS_LOG}" \
    "  indice:       ${HARDENING:-inconnu} (seuil ${LYNIS_MIN_INDEX})" \
    "  tests:        ${TESTS:-inconnu}" \
    "  plugins:      ${PLUGINS:-inconnu}" \
    "  avertissements: ${WARNINGS:-0}" \
    "  suggestions:  ${SUGGESTIONS:-0}"
}

main() {
  local opt=""
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -p | --pentest)
        MODE="pentest"
        shift
        ;;
      -m | --min)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        LYNIS_MIN_INDEX="$2"
        shift 2
        ;;
      -o | --output)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        LYNIS_LOG="$2"
        shift 2
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
  run_lynis
  parse_report
  report

  if [[ -z "${HARDENING}" ]]; then
    log err "indice de durcissement introuvable dans la sortie lynis"
    return 1
  fi
  if [[ "${HARDENING}" -lt "${LYNIS_MIN_INDEX}" ]]; then
    log warning "indice ${HARDENING} inferieur au seuil ${LYNIS_MIN_INDEX}"
    return 1
  fi
  log info "indice ${HARDENING} conforme (seuil ${LYNIS_MIN_INDEX})"
  return 0
}

HARDENING=""
TESTS=""
PLUGINS=""
SUGGESTIONS=""
WARNINGS=""
main "$@"
