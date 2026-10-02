#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
RESOLVER="${RESOLVER:-}"
RECORD_TYPE="${RECORD_TYPE-A}"
WARN_MS="${WARN_MS-500}"
QUERY_TIMEOUT="${QUERY_TIMEOUT-2}"
EXPECT_FILE="${EXPECT_FILE:-}"

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-r RESOLVER] [-f FICHIER] [-t TYPE]" \
    "              [-w MS] [-T S] [NOM...]" \
    "" \
    "Verification DNS : interroge un resolveur pour chaque nom, mesure" \
    "le temps de reponse et compare les adresses obtenues aux" \
    "attendues." \
    "" \
    "Options:" \
    "  -r, --resolver IP   serveur DNS (defaut: premier de resolv.conf)" \
    "  -f, --file FICHIER  noms a tester, format: nom [ip ip...]" \
    "  -t, --type TYPE     type d'enregistrement (defaut: ${RECORD_TYPE})" \
    "  -w, --warn MS       seuil de latence en ms (defaut: ${WARN_MS})" \
    "  -T, --timeout S     timeout par requete (defaut: ${QUERY_TIMEOUT})" \
    "  -h, --help          affiche cette aide" \
    "" \
    "Un nom sans adresse attendue est seulement rapporte." \
    "" \
    "Codes de retour: 0 OK, 1 divergence ou timeout, 2 erreur fatale"
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
  for tool in dig awk sort; do
    command -v "${tool}" >/dev/null 2>&1 \
      || die "commande introuvable: ${tool}"
  done
}

default_resolver() {
  local ns=""
  ns="$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null)" \
    || true
  printf '%s' "${ns}"
}

check_config() {
  if [[ -z "${RESOLVER}" ]]; then
    RESOLVER="$(default_resolver)"
  fi
  [[ -n "${RESOLVER}" ]] || die "aucun resolveur (utilisez -r)"
  [[ "${RECORD_TYPE}" =~ ^[A-Za-z]+$ ]] || die "type invalide: ${RECORD_TYPE}"
  [[ "${WARN_MS}" =~ ^[0-9]+$ ]] || die "seuil -w invalide: ${WARN_MS}"
  [[ "${QUERY_TIMEOUT}" =~ ^[0-9]+$ ]] || die "timeout -T invalide"
}

load_expectations() {
  local line=""
  local name=""
  local rest=""
  [[ -n "${EXPECT_FILE}" ]] || return 0
  [[ -r "${EXPECT_FILE}" ]] || die "fichier illisible: ${EXPECT_FILE}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
      \#*) continue ;;
    esac
    read -r name rest <<< "${line}"
    [[ -n "${name}" ]] || continue
    EXPECTED["${name}"]="${rest:-}"
  done < "${EXPECT_FILE}"
}

normalize_set() {
  local -a items=()
  read -r -a items <<< "$1"
  if [[ "${#items[@]}" -eq 0 ]]; then
    printf ''
    return 0
  fi
  printf '%s\n' "${items[@]}" | sort -u | paste -sd, -
}

query() {
  local name="$1"
  local started=0
  local finished=0
  local rc=0
  ANSWERS=""
  started="$(date +%s%N)"
  ANSWERS="$(dig +short +time="${QUERY_TIMEOUT}" +tries=1 \
    -p 53 "@${RESOLVER}" "${name}" "${RECORD_TYPE}" 2>/dev/null)" \
    || rc=$?
  finished="$(date +%s%N)"
  RTT_MS="$(( (finished - started) / 1000000 ))"
  DIG_RC="${rc}"
}

verify_one() {
  local name="$1"
  local expected="${EXPECTED[$name]-}"
  local want=""
  local have=""
  local status="OK"

  query "${name}"

  if [[ "${DIG_RC}" -ne 0 ]]; then
    printf '%-30s %-24s %-24s %6sms TIMEOUT\n' \
      "${name}" "${expected:-aucune}" "-" "${RTT_MS}"
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  have="$(normalize_set "$(printf '%s\n' "${ANSWERS}" | tr '\n' ' ')")"
  if [[ -n "${expected}" ]]; then
    want="$(normalize_set "${expected}")"
    if [[ -z "${have}" ]]; then
      status="ABSENT"
    elif [[ "${have}" != "${want}" ]]; then
      status="DIVERGENT"
    fi
  fi

  if [[ "${status}" != "OK" ]]; then
    FAILURES=$((FAILURES + 1))
  fi
  if [[ "${RTT_MS}" -gt "${WARN_MS}" ]]; then
    SLOW=$((SLOW + 1))
    if [[ "${status}" == "OK" ]]; then
      status="LENT"
    fi
  fi

  printf '%-30s %-24s %-24s %6sms %s\n' \
    "${name}" "${expected:-aucune}" "${have:-aucune}" "${RTT_MS}" \
    "${status}"
}

main() {
  local opt=""
  local -a names=()
  local name=""

  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -r | --resolver)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        RESOLVER="$2"
        shift 2
        ;;
      -f | --file)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        EXPECT_FILE="$2"
        shift 2
        ;;
      -t | --type)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        RECORD_TYPE="$2"
        shift 2
        ;;
      -w | --warn)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        WARN_MS="$2"
        shift 2
        ;;
      -T | --timeout)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        QUERY_TIMEOUT="$2"
        shift 2
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*)
        printf 'Option inconnue: %s\n' "${opt}" >&2
        usage >&2
        return 64
        ;;
      *)
        names+=("$1")
        shift
        ;;
    esac
  done

  require_tools
  check_config
  load_expectations

  if [[ "${#names[@]}" -eq 0 ]]; then
    for name in "${!EXPECTED[@]}"; do
      names+=("${name}")
    done
  fi
  if [[ "${#names[@]}" -eq 0 ]]; then
    usage >&2
    return 64
  fi

  printf '%-30s %-24s %-24s %7s %s\n' \
    "NOM" "ATTENDU" "OBTENU" "RTT" "STATUT"
  for name in "${names[@]}"; do
    verify_one "${name}"
  done

  log info "termine: ${FAILURES} ecart(s), ${SLOW} reponse(s) lente(s)"
  if [[ "${FAILURES}" -gt 0 ]]; then
    return 1
  fi
  return 0
}

declare -A EXPECTED=()
FAILURES=0
SLOW=0
DIG_RC=0
RTT_MS=0
ANSWERS=""
main "$@"
