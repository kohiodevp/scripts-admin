#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
SERVICES="${SERVICES:-}"
TIMEOUT_S="${TIMEOUT_S-5}"
JSON=0
CHECK_ENABLED=1

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-t SECONDES] [-j] [-q] [SERVICE...]" \
    "" \
    "Etat des services systemd : actif/inactif, sous-etat, redemarrages" \
    "et activation au demarrage. Sans systemd, un repli sur pgrep est" \
    "utilise (etat processus uniquement)." \
    "" \
    "Options:" \
    "  -t, --timeout S   timeout par interrogation (defaut: ${TIMEOUT_S})" \
    "  -j, --json        sortie JSON" \
    "  -q, --quick       ignore l'etat d'activation au demarrage" \
    "  -h, --help        affiche cette aide" \
    "" \
    "Arguments:" \
    "  SERVICE           noms systemd (defaut: \$SERVICES)" \
    "" \
    "Variables d'environnement:" \
    "  SERVICES          liste separee par espaces (defaut: ${SERVICES:-vide})" \
    "  TIMEOUT_S         timeout par interrogation (defaut: ${TIMEOUT_S})" \
    "" \
    "Codes de retour: 0 tous actifs, 1 au moins un inactif, 2 hors service"
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

usage_error() {
  usage >&2
  return 64
}

require_tools() {
  command -v awk >/dev/null 2>&1 || die "commande introuvable: awk"
}

detect_backend() {
  if command -v systemctl >/dev/null 2>&1 \
    && systemctl list-units --type=service >/dev/null 2>&1; then
    BACKEND="systemd"
    return 0
  fi
  if command -v pgrep >/dev/null 2>&1; then
    BACKEND="pgrep"
    log warning "systemd indisponible, repli sur pgrep"
    return 0
  fi
  die "aucun backend disponible (systemd ou pgrep)"
}

check_systemd() {
  local name="$1"
  local active="unknown"
  local sub="unknown"
  local enabled="unknown"
  local restarts="0"

  active="$(timeout "${TIMEOUT_S}" systemctl is-active "${name}" 2>/dev/null)" \
    || true
  sub="$(timeout "${TIMEOUT_S}" \
    systemctl show "${name}" -p SubState --value 2>/dev/null)" || true
  restarts="$(timeout "${TIMEOUT_S}" \
    systemctl show "${name}" -p NRestarts --value 2>/dev/null)" || true
  if [[ "${CHECK_ENABLED}" -eq 1 ]]; then
    enabled="$(timeout "${TIMEOUT_S}" \
      systemctl is-enabled "${name}" 2>/dev/null)" || true
  fi
  [[ -n "${active}" ]] || active="unknown"
  [[ -n "${sub}" ]] || sub="unknown"
  [[ -n "${restarts}" && "${restarts}" =~ ^[0-9]+$ ]] || restarts="0"
  [[ -n "${enabled}" ]] || enabled="n/a"

  printf '%s|%s|%s|%s|%s\n' \
    "${name}" "${active}" "${sub}" "${enabled}" "${restarts}"
}

check_pgrep() {
  local name="$1"
  local active="inactive"
  local restarts="0"

  if pgrep -f "${name}" >/dev/null 2>&1; then
    active="active"
  fi
  printf '%s|%s|%s|%s|%s\n' \
    "${name}" "${active}" "process" "n/a" "${restarts}"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

emit_json() {
  local first=1
  printf '{ "backend": "%s", "services": [' "${BACKEND}"
  local line=""
  for line in "${RESULTS[@]}"; do
    if [[ "${first}" -eq 0 ]]; then
      printf ','
    fi
    first=0
    printf '\n  { "name": "%s", "state": "%s", "sub": "%s",' \
      "$(json_escape "${line%%|*}")" \
      "$(json_escape "$(printf '%s' "${line}" | cut -d'|' -f2)")" \
      "$(json_escape "$(printf '%s' "${line}" | cut -d'|' -f3)")"
    printf ' "enabled": "%s", "restarts": %s }' \
      "$(json_escape "$(printf '%s' "${line}" | cut -d'|' -f4)")" \
      "$(printf '%s' "${line}" | cut -d'|' -f5)"
  done
  printf '\n] }\n'
}

emit_text() {
  printf '%-24s %-10s %-12s %-12s %s\n' \
    "SERVICE" "ETAT" "SOUS-ETAT" "DEMARRAGE" "REDEMARRAGES"
  local line=""
  for line in "${RESULTS[@]}"; do
    printf '%-24s %-10s %-12s %-12s %s\n' \
      "${line%%|*}" \
      "$(printf '%s' "${line}" | cut -d'|' -f2)" \
      "$(printf '%s' "${line}" | cut -d'|' -f3)" \
      "$(printf '%s' "${line}" | cut -d'|' -f4)" \
      "$(printf '%s' "${line}" | cut -d'|' -f5)"
  done
}

evaluate() {
  local line=""
  local state=""
  local restarts=""
  FAILED=0
  for line in "${RESULTS[@]}"; do
    state="$(printf '%s' "${line}" | cut -d'|' -f2)"
    restarts="$(printf '%s' "${line}" | cut -d'|' -f5)"
    if [[ "${state}" != "active" && "${state}" != "running" ]]; then
      FAILED=1
    fi
    if [[ "${restarts}" =~ ^[0-9]+$ && "${restarts}" -gt 3 ]]; then
      FAILED=1
    fi
  done
}

main() {
  local opt=""
  local -a names=()
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -t | --timeout)
        [[ $# -ge 2 ]] || usage_error
        TIMEOUT_S="$2"
        shift 2
        ;;
      -j | --json)
        JSON=1
        shift
        ;;
      -q | --quick)
        CHECK_ENABLED=0
        shift
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
  if [[ "${#names[@]}" -eq 0 ]]; then
    read -r -a names <<< "${SERVICES}"
  fi
  if [[ "${#names[@]}" -eq 0 ]]; then
    usage_error
  fi
  detect_backend

  local name=""
  for name in "${names[@]}"; do
    [[ -n "${name}" ]] || continue
    if [[ "${BACKEND}" == "systemd" ]]; then
      RESULTS+=("$(check_systemd "${name}")")
    else
      RESULTS+=("$(check_pgrep "${name}")")
    fi
  done

  evaluate
  if [[ "${JSON}" -eq 1 ]]; then
    emit_json
  else
    emit_text
  fi

  if [[ "${FAILED}" -eq 1 ]]; then
    log warning "au moins un service est degrade"
    return 1
  fi
  log info "tous les services sont actifs"
  return 0
}

BACKEND=""
RESULTS=()
FAILED=0
main "$@"
