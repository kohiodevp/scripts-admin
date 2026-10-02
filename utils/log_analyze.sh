#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
TOP_N="${TOP_N-10}"
MAX_ERRORS="${MAX_ERRORS--1}"
FILTER_PATTERN="${FILTER_PATTERN:-}"
SEVERITY_PATTERN="${SEVERITY_PATTERN:-}"

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-f FICHIER] [-t N] [-p REGEX] [-e REGEX]" \
    "              [-c N] [FICHIER...]" \
    "" \
    "Analyse de journaux : volume, ventilation par severite (ERROR," \
    "WARN, INFO, DEBUG, CRIT) et messages les plus frequentes apres" \
    "normalisation (chiffres, guillemets et horodatages groupes)." \
    "" \
    "Options:" \
    "  -f, --file FICHIER  journal a analyser (autant que voulu)" \
    "  -t, --top N         messages du top affiches (defaut: ${TOP_N})" \
    "  -p, --pattern REGEX ne retient que les lignes correspondantes" \
    "  -e, --error REGEX   regex d'erreur supplementaire" \
    "  -c, --max-errors N  code 1 si erreurs > N (defaut: illimite)" \
    "  -h, --help          affiche cette aide" \
    "" \
    "Sans fichier, le flux standard est lu." \
    "" \
    "Codes de retour: 0 OK, 1 seuil d'erreurs depasse, 2 erreur fatale"
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
  for tool in awk sort head; do
    command -v "${tool}" >/dev/null 2>&1 \
      || die "commande introuvable: ${tool}"
  done
}

analyze() {
  local kind=""
  local a=""
  local b=""
  TOTAL=0
  N_CRIT=0
  N_ERROR=0
  N_WARN=0
  N_INFO=0
  N_DEBUG=0
  MESSAGE_LINES=()

  while IFS='|' read -r kind a b; do
    case "${kind}" in
      @STAT)
        case "${a}" in
          total) TOTAL="${b}" ;;
          crit) N_CRIT="${b}" ;;
          error) N_ERROR="${b}" ;;
          warn) N_WARN="${b}" ;;
          info) N_INFO="${b}" ;;
          debug) N_DEBUG="${b}" ;;
        esac
        ;;
      @MSG)
        MESSAGE_LINES+=("${a}"$'\t'"${b}")
        ;;
    esac
  done < <(awk -v filter="${FILTER_PATTERN}" -v extra="${SEVERITY_PATTERN}" '
    filter != "" && $0 !~ filter { next }
    {
      total++
      low = tolower($0)
      is_crit = (low ~ /critical|critique|fatal|panic/)
      is_err = (low ~ /(^|[^a-z])error([^a-z]|$)|erreur|failed|failure|echec/)
      is_warn = (low ~ /warn|avertissement/)
      is_dbg = (low ~ /debug|trace/)
      if (is_crit) {
        crit++
      } else if (is_err) {
        err++
      } else if (extra != "" && $0 ~ extra) {
        err++
      } else if (is_warn) {
        warn++
      } else if (is_dbg) {
        debug++
      } else {
        info++
      }
      msg = $0
      gsub(/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}/,
            "<ts>", msg)
      gsub(/"([^"]|\\")*"/, "\"...\"", msg)
      gsub(/[0-9]+/, "#", msg)
      gsub(/[[:space:]]+/, " ", msg)
      if (length(msg) > 160) {
        msg = substr(msg, 1, 160)
      }
      msgs[msg]++
    }
    END {
      printf "@STAT|total|%d\n", total
      printf "@STAT|crit|%d\n", crit
      printf "@STAT|error|%d\n", err
      printf "@STAT|warn|%d\n", warn
      printf "@STAT|info|%d\n", info
      printf "@STAT|debug|%d\n", debug
      for (m in msgs) {
        printf "@MSG|%d|%s\n", msgs[m], m
      }
    }
  ' "$@")

  if [[ "${TOTAL}" -eq 0 ]]; then
    log warning "aucune ligne analysee"
  fi
}

report() {
  local ranked=()
  printf '%s\n' \
    "Analyse: ${TOTAL} ligne(s)" \
    "  CRIT=${N_CRIT} ERROR=${N_ERROR} WARN=${N_WARN} INFO=${N_INFO} DEBUG=${N_DEBUG}"
  if [[ "${#MESSAGE_LINES[@]}" -eq 0 ]]; then
    return 0
  fi
  printf 'Top %s messages normalises:\n' "${TOP_N}"
  mapfile -t ranked < <(
    printf '%s\n' "${MESSAGE_LINES[@]}" | sort -t $'\t' -k1,1 -rn \
      | head -n "${TOP_N}"
  )
  local entry=""
  local rank=1
  for entry in "${ranked[@]}"; do
    printf '  %2d. %6s  %s\n' "${rank}" \
      "${entry%%$'\t'*}" "${entry#*$'\t'}"
    rank=$((rank + 1))
  done
}

main() {
  local opt=""
  local -a files=()
  local file=""
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -f | --file)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        files+=("$2")
        shift 2
        ;;
      -t | --top)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        TOP_N="$2"
        shift 2
        ;;
      -p | --pattern)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        FILTER_PATTERN="$2"
        shift 2
        ;;
      -e | --error)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        SEVERITY_PATTERN="$2"
        shift 2
        ;;
      -c | --max-errors)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        MAX_ERRORS="$2"
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
        files+=("$1")
        shift
        ;;
    esac
  done

  require_tools
  [[ "${TOP_N}" =~ ^[1-9][0-9]*$ ]] || die "top invalide: ${TOP_N}"
  [[ "${MAX_ERRORS}" =~ ^-?[0-9]+$ ]] || die "seuil invalide: ${MAX_ERRORS}"

  if [[ "${#files[@]}" -eq 0 ]]; then
    files=("/dev/stdin")
  fi
  for file in "${files[@]}"; do
    if [[ "${file}" != "/dev/stdin" && ! -r "${file}" ]]; then
      die "fichier illisible: ${file}"
    fi
  done

  analyze "${files[@]}"
  report

  if [[ "${MAX_ERRORS}" -ge 0 && "${N_ERROR}" -gt "${MAX_ERRORS}" ]]; then
    log warning "${N_ERROR} erreur(s) superieur au seuil ${MAX_ERRORS}"
    return 1
  fi
  return 0
}

MESSAGE_LINES=()
main "$@"
