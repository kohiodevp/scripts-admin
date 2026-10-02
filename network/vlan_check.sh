#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
EXPECTED_VLANS="${EXPECTED_VLANS:-}"

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-e LISTE] [NOM...]" \
    "" \
    "Controle en lecture seule de la configuration VLAN 802.1Q :" \
    "interfaces detectees, coherence des parents, doublons d'identifiant," \
    "MTU et conformite a la liste attendue." \
    "" \
    "Options:" \
    "  -e, --expected LISTE  attendu, format 'id:parent id:parent'" \
    "                        (defaut: \$EXPECTED_VLANS)" \
    "  -h, --help            affiche cette aide" \
    "" \
    "Arguments:" \
    "  NOM                   restreint le controle a ces interfaces" \
    "" \
    "Variables d'environnement:" \
    "  EXPECTED_VLANS        liste attendue (defaut: ${EXPECTED_VLANS:-vide})" \
    "" \
    "Codes de retour: 0 conforme, 1 avertissement, 2 erreur"
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
  for tool in ip awk; do
    command -v "${tool}" >/dev/null 2>&1 \
      || die "commande introuvable: ${tool}"
  done
}

discover_vlans() {
  local raw=""
  raw="$(ip -d link show 2>/dev/null)" || die "lecture des interfaces impossible"
  VLANS="$(printf '%s\n' "${raw}" | awk '
    /^[0-9]+: / {
      name = $2
      sub(/:$/, "", name)
      parent = ""
      at = index(name, "@")
      if (at > 0) {
        parent = substr(name, at + 1)
        name = substr(name, 1, at - 1)
      }
      up = (index($0, ",UP") > 0) ? 1 : 0
      mtu = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "mtu") {
          mtu = $(i + 1)
        }
      }
      pending = 1
      next
    }
    pending && /vlan protocol/ {
      vid = -1
      for (i = 1; i <= NF; i++) {
        if ($i == "id") {
          vid = $(i + 1)
        }
      }
      print name "|" parent "|" vid "|" mtu "|" up
      pending = 0
      next
    }
  ')"
}

interface_mtu() {
  local dev="$1"
  ip -o link show dev "${dev}" 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "mtu") { print $(i + 1); exit } }'
}

raise() {
  local level="$1"
  shift
  printf '%-10s %s\n' "${level}" "$*"
  if [[ "${level}" == "ERREUR" ]]; then
    ERRORS=$((ERRORS + 1))
  else
    WARNINGS=$((WARNINGS + 1))
  fi
}

selected() {
  local name="$1"
  local item=""
  if [[ "${#FILTER[@]}" -eq 0 ]]; then
    return 0
  fi
  for item in "${FILTER[@]}"; do
    if [[ "${item}" == "${name}" ]]; then
      return 0
    fi
  done
  return 1
}

expected_entry_present() {
  local entry="$1"
  local item=""
  for item in ${EXPECTED_VLANS}; do
    if [[ "${item}" == "${entry}" ]]; then
      return 0
    fi
  done
  return 1
}

check_vlan() {
  local name="$1"
  local parent="$2"
  local vid="$3"
  local mtu="$4"
  local up="$5"
  local state="DOWN"
  local parent_mtu=""

  if [[ "${up}" == "1" ]]; then
    state="UP"
  fi
  if ! ip link show dev "${parent}" >/dev/null 2>&1; then
    raise ERREUR "${name}: parent absent (${parent})"
  else
    parent_mtu="$(interface_mtu "${parent}")"
    if [[ -n "${parent_mtu}" && "${mtu}" =~ ^[0-9]+$ ]] \
      && [[ "${mtu}" -gt "${parent_mtu}" ]]; then
      raise AVERT "${name}: MTU ${mtu} superieur au parent ${parent_mtu}"
    fi
  fi
  if [[ -n "${EXPECTED_VLANS}" ]] \
    && ! expected_entry_present "${vid}:${parent}"; then
    raise AVERT "${name}: non repertorie (attendu: ${EXPECTED_VLANS})"
  fi
  if [[ -z "${EXPECTED_VLANS}" ]] && [[ -z "${SEEN_IDS}" ]]; then
    SEEN_IDS=" "
  fi
  printf '%-16s %-12s id=%-6s mtu=%-6s %s\n' \
    "${name}" "${parent}" "${vid}" "${mtu}" "${state}"
}

check_expected_present() {
  local item=""
  local vid=""
  local parent=""
  local found=0
  local line=""
  [[ -n "${EXPECTED_VLANS}" ]] || return 0
  for item in ${EXPECTED_VLANS}; do
    [[ "${item}" == *:* ]] || die "format attendu id:parent: ${item}"
    vid="${item%%:*}"
    parent="${item##*:}"
    found=0
    while IFS='|' read -r name p v rest; do
      [[ -n "${name}" ]] || continue
      if [[ "${p}" == "${parent}" && "${v}" == "${vid}" ]]; then
        found=1
        break
      fi
    done <<< "${VLANS}"
    if [[ "${found}" -eq 0 ]]; then
      raise ERREUR "VLAN ${vid} sur ${parent} absent de la configuration"
    fi
    line=""
  done
}

check_duplicates() {
  local dupes=""
  dupes="$(printf '%s\n' "${VLANS}" | awk -F'|' '
    $3 != "-1" {
      key = $3 ":" $2
      count[key]++
      if (count[key] == 2) {
        print key
      }
    }
  ')"
  if [[ -n "${dupes}" ]]; then
    local line=""
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      raise ERREUR "identifiant duplique: ${line}"
    done <<< "${dupes}"
  fi
}

main() {
  local opt=""
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -e | --expected)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        EXPECTED_VLANS="$2"
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
        FILTER+=("$1")
        shift
        ;;
    esac
  done

  require_tools
  discover_vlans
  if [[ -z "${VLANS}" ]]; then
    if [[ -n "${EXPECTED_VLANS}" ]]; then
      log err "aucun VLAN detecte alors que ${EXPECTED_VLANS} attendu"
      return 2
    fi
    log info "aucun VLAN 802.1Q configure"
    return 0
  fi

  printf '%-16s %-12s %-10s %-12s %s\n' \
    "INTERFACE" "PARENT" "VLAN" "MTU" "ETAT"
  local name=""
  local parent=""
  local vid=""
  local mtu=""
  local up=""
  local rest=""
  while IFS='|' read -r name parent vid mtu up rest; do
    [[ -n "${name}" ]] || continue
    selected "${name}" || continue
    check_vlan "${name}" "${parent}" "${vid}" "${mtu}" "${up}"
  done <<< "${VLANS}"

  check_expected_present
  check_duplicates

  if [[ "${ERRORS}" -gt 0 ]]; then
    log err "controle VLAN: ${ERRORS} erreur(s), ${WARNINGS} avertissement(s)"
    return 2
  fi
  if [[ "${WARNINGS}" -gt 0 ]]; then
    log warning "controle VLAN: ${WARNINGS} avertissement(s)"
    return 1
  fi
  log info "controle VLAN conforme"
  return 0
}

VLANS=""
FILTER=()
ERRORS=0
WARNINGS=0
SEEN_IDS=""
main "$@"
