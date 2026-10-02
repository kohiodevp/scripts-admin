#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
WARN_PCT="${WARN_PCT-80}"
CRIT_PCT="${CRIT_PCT-90}"
ETA_DAYS="${ETA_DAYS-7}"
STATE_FILE="${STATE_FILE-${XDG_STATE_HOME:-$HOME/.local/state}/disk-predict.state}"
CLEAR_STATE=0

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-w PCT] [-c PCT] [-t JOURS] [-s FICHIER]" \
    "              [-C] [MONTAGE...]" \
    "" \
    "Anticipe la saturation des disques : compare la derniere utilisation" \
    "connue (fichier d'etat) a l'instant present, extrapole le taux de" \
    "croissance et estime la date de remplissage." \
    "" \
    "Options:" \
    "  -w, --warn PCT       seuil d'avertissement (defaut: ${WARN_PCT})" \
    "  -c, --crit PCT       seuil critique (defaut: ${CRIT_PCT})" \
    "  -t, --days JOURS     alerte si plein avant ce delai (defaut: ${ETA_DAYS})" \
    "  -s, --state FICHIER  fichier d'etat (defaut: ${STATE_FILE})" \
    "  -C, --clear          remet a zero le fichier d'etat puis sort" \
    "  -h, --help           affiche cette aide" \
    "" \
    "Sans montage, les systemes de fichiers reels sont analyses." \
    "" \
    "Codes de retour: 0 OK, 1 avertissement, 2 critique"
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
  for tool in df awk sort; do
    command -v "${tool}" >/dev/null 2>&1 \
      || die "commande introuvable: ${tool}"
  done
}

check_config() {
  local number=""
  for number in "${WARN_PCT}" "${CRIT_PCT}" "${ETA_DAYS}"; do
    [[ "${number}" =~ ^[0-9]+$ ]] || die "valeur entiere attendue: ${number}"
  done
  [[ "${WARN_PCT}" -lt "${CRIT_PCT}" ]] \
    || die "WARN_PCT doit etre inferieur a CRIT_PCT"
}

list_mounts() {
  if [[ "${#MOUNTS[@]}" -gt 0 ]]; then
    return 0
  fi
  mapfile -t MOUNTS < <(df -PT 2>/dev/null \
    | awk 'NR > 1 && $2 !~ /^(tmpfs|devtmpfs|squashfs|overlay|efivarfs|ramfs|tracefs|cgroup2?)$/ { print $NF }')
  if [[ "${#MOUNTS[@]}" -eq 0 ]]; then
    die "aucun montage a analyser"
  fi
}

load_state() {
  STATE_KV=""
  [[ -f "${STATE_FILE}" ]] || return 0
  STATE_KV="$(awk -F'|' '{ print $1 "|" $2 "|" $3 }' "${STATE_FILE}")" \
    || true
}

read_used() {
  local mount="$1"
  local line=""
  line="$(df -Pk -- "${mount}" 2>/dev/null | awk 'NR == 2 { print $3 }')" \
    || true
  printf '%s' "${line:-}"
}

read_avail() {
  local mount="$1"
  local line=""
  line="$(df -Pk -- "${mount}" 2>/dev/null | awk 'NR == 2 { print $4 }')" \
    || true
  printf '%s' "${line:-}"
}

read_total() {
  local mount="$1"
  local line=""
  line="$(df -Pk -- "${mount}" 2>/dev/null | awk 'NR == 2 { print $2 }')" \
    || true
  printf '%s' "${line:-}"
}

read_pct() {
  local mount="$1"
  local line=""
  line="$(df -Pk -- "${mount}" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')" \
    || true
  printf '%s' "${line:-}"
}

state_entry() {
  local mount="$1"
  printf '%s\n' "${STATE_KV}" \
    | awk -F'|' -v m="${mount}" '$1 == m { print $2 "|" $3; exit }'
}

update_state() {
  local now
  now="$(date -u +%s)"
  local mount=""
  local used=""
  local tmp="${STATE_FILE}.tmp.$$"
  mkdir -p "$(dirname "${STATE_FILE}")" 2>/dev/null || true
  umask 077
  : > "${tmp}" || true
  for mount in "${MOUNTS[@]}"; do
    used="$(read_used "${mount}")"
    [[ -n "${used}" ]] || continue
    printf '%s|%s|%s\n' "${mount}" "${now}" "${used}" >> "${tmp}" \
      2>/dev/null || true
  done
  if [[ -s "${tmp}" ]]; then
    mv -f "${tmp}" "${STATE_FILE}" 2>/dev/null \
      || rm -f "${tmp}" 2>/dev/null || true
  else
    rm -f "${tmp}" 2>/dev/null || true
  fi
}

analyze_mount() {
  local mount="$1"
  local total used avail pct entry prev_t prev_u
  local eta="n/a" rate=0 trend="n/a" status="OK" line=""

  total="$(read_total "${mount}")"
  used="$(read_used "${mount}")"
  avail="$(read_avail "${mount}")"
  pct="$(read_pct "${mount}")"
  [[ -n "${total}" && "${total}" -gt 0 ]] 2>/dev/null || return 0

  entry="$(state_entry "${mount}")"
  if [[ -n "${entry}" ]]; then
    prev_t="${entry%%|*}"
    prev_u="${entry##*|}"
    if [[ "${prev_u}" =~ ^[0-9]+$ && "${prev_t}" =~ ^[0-9]+$ ]]; then
      local now delta_t delta_u
      now="$(date -u +%s)"
      delta_t=$((now - prev_t))
      delta_u=$((used - prev_u))
      if [[ "${delta_t}" -gt 60 ]]; then
        rate="$(awk -v u="${delta_u}" -v t="${delta_t}" \
          'BEGIN { printf "%.4f", (u / t) * 86400 }')"
        trend="$(awk -v r="${rate}" \
          'BEGIN { printf "%.1f Mo/j", r / 1024 }')"
        if awk -v r="${rate}" -v a="${avail}" \
          'BEGIN { exit !(r > 0 && a > 0) }'; then
          eta="$(awk -v a="${avail}" -v r="${rate}" \
            'BEGIN { printf "%.1f", a / r }')"
        else
          eta="stable"
        fi
      fi
    fi
  fi

  if awk -v p="${pct}" -v c="${CRIT_PCT}" 'BEGIN { exit !(p >= c) }'; then
    status="CRIT"
  elif awk -v e="${eta}" -v d="${ETA_DAYS}" \
    'BEGIN { exit !(e != "n/a" && e != "stable" && e + 0 <= 1.0) }'; then
    status="CRIT"
  elif awk -v p="${pct}" -v w="${WARN_PCT}" 'BEGIN { exit !(p >= w) }'; then
    status="WARN"
  elif awk -v e="${eta}" -v d="${ETA_DAYS}" \
    'BEGIN { exit !(e != "n/a" && e != "stable" && e + 0 <= d + 0) }'; then
    status="WARN"
  fi

  line="$(printf '%-24s %5s%% %8s %14s %8s' \
    "${mount}" "${pct}" \
    "$(awk -v a="${avail}" 'BEGIN { printf "%.1fG", a / 1048576 }')" \
    "${trend}" "${eta}")"
  printf '%s|%s\n' "${status}" "${line}"

  case "${status}" in
    CRIT)
      HIGHEST=2
      ;;
    WARN)
      if [[ "${HIGHEST}" -eq 0 ]]; then
        HIGHEST=1
      fi
      ;;
  esac
}

main() {
  local opt=""
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -w | --warn)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        WARN_PCT="$2"
        shift 2
        ;;
      -c | --crit)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        CRIT_PCT="$2"
        shift 2
        ;;
      -t | --days)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        ETA_DAYS="$2"
        shift 2
        ;;
      -s | --state)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        STATE_FILE="$2"
        shift 2
        ;;
      -C | --clear)
        CLEAR_STATE=1
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
        MOUNTS+=("$1")
        shift
        ;;
    esac
  done

  require_tools
  if [[ "${CLEAR_STATE}" -eq 1 ]]; then
    rm -f "${STATE_FILE}"
    log info "etat efface: ${STATE_FILE}"
    return 0
  fi
  check_config
  load_state
  list_mounts

  printf '%-24s %5s %8s %14s %8s\n' \
    "MONTAGE" "UTIL" "LIBRE" "TENDANCE" "PLEIN_DANS"
  local mount=""
  for mount in "${MOUNTS[@]}"; do
    analyze_mount "${mount}"
  done
  update_state

  if [[ "${HIGHEST}" -eq 2 ]]; then
    log err "saturation imminente detectee"
    return 2
  fi
  if [[ "${HIGHEST}" -eq 1 ]]; then
    log warning "saturation proche predite"
    return 1
  fi
  log info "tous les montage sont sains"
  return 0
}

MOUNTS=()
STATE_KV=""
HIGHEST=0
main "$@"
