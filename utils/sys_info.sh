#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
BRIEF=0
TOP_PROCS="${TOP_PROCS-5}"

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-b] [-t N]" \
    "" \
    "Inventaire systeme en lecture seule : hote, noyau, uptime, memoire," \
    "systemes de fichiers, processus, adresses reseau et ports en" \
    "ecoute. Les commandes absentes sont signalees, jamais bloquantes." \
    "" \
    "Options:" \
    "  -b, --brief     ignore processus, reseau et ports" \
    "  -t, --top N     processus listes (defaut: ${TOP_PROCS})" \
    "  -h, --help      affiche cette aide" \
    "" \
    "Codes de retour: 0 toujours (diagnostic), 64 usage invalide"
}

log() {
  local priority="$1"
  shift
  printf '%s %s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${priority^^}" "$PROG" "$*" >&2
  logger -p "user.${priority}" -t "$PROG" -- "$*" 2>/dev/null || true
}

section() {
  printf '\n== %s ==\n' "$1"
}

field() {
  printf '  %-14s %s\n' "$1:" "$2"
}

skip() {
  printf '  (indisponible: %s)\n' "$1"
}

show_identity() {
  section "Systeme"
  local hostname_v=""
  hostname_v="$(hostname 2>/dev/null)" || hostname_v="?"
  field "hote" "${hostname_v}"
  if [[ -r /etc/os-release ]]; then
    field "distrib" "$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null \
      | cut -d= -f2- | tr -d '\"' || true)"
  else
    field "distrib" "inconnue"
  fi
  field "noyau" "$(uname -sr 2>/dev/null || printf 'inconnu')"
  field "arch" "$(uname -m 2>/dev/null || printf 'inconnue')"
}

show_uptime() {
  local up=""
  up="$(uptime -p 2>/dev/null)" || up=""
  if [[ -z "${up}" ]]; then
    up="$(uptime 2>/dev/null)" || up="indisponible"
  fi
  field "uptime" "${up}"
  if [[ -r /proc/loadavg ]]; then
    field "charge" "$(awk '{ print $1" "$2" "$3 }' /proc/loadavg)"
  fi
}

show_cpu_mem() {
  section "Processeur et memoire"
  if [[ -r /proc/cpuinfo ]]; then
    local cores model
    cores="$(grep -c ^processor /proc/cpuinfo)" || cores="?"
    model="$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)" \
      || model=""
    field "coeurs" "${cores}"
    field "modele" "${model:-inconnu}"
  else
    skip "/proc/cpuinfo"
  fi
  if [[ -r /proc/meminfo ]]; then
    awk '
      /^MemTotal:/ { t = $2 }
      /^MemAvailable:/ { a = $2 }
      /^SwapTotal:/ { s = $2 }
      /^SwapFree:/ { f = $2 }
      END {
        if (t > 0) {
          printf "  %-14s %.1f Go (%.1f%% libre)\n", "memoire:",
                 t / 1048576, 100 * a / t
        }
        if (s > 0) {
          printf "  %-14s %.1f Go (%.1f%% libre)\n", "swap:",
                 s / 1048576, 100 * f / s
        }
      }
    ' /proc/meminfo
  else
    skip "/proc/meminfo"
  fi
}

show_disks() {
  section "Systemes de fichiers"
  if command -v df >/dev/null 2>&1; then
    df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null \
      | awk 'NR == 1 || NR <= 12 { print "  " $0 }'
  else
    skip "df"
  fi
}

show_processes() {
  section "Processus (top ${TOP_PROCS} CPU)"
  if command -v ps >/dev/null 2>&1; then
    ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null \
      | head -n "$((TOP_PROCS + 1))" \
      | awk '{ printf "  %s\n", $0 }'
  else
    skip "ps"
  fi
}

show_network() {
  section "Reseau"
  if command -v ip >/dev/null 2>&1; then
    ip -br -4 addr show 2>/dev/null | awk '{ printf "  %s %s %s\n", $1, $2, $3 }'
  else
    skip "ip"
  fi
  if command -v ss >/dev/null 2>&1; then
    local listening
    listening="$(ss -H -lntu 2>/dev/null | wc -l)" || listening="?"
    field "ecoute" "${listening} port(s)"
  else
    skip "ss"
  fi
  if command -v docker >/dev/null 2>&1; then
    local running
    running="$(docker ps -q 2>/dev/null | wc -l)" || running="0"
    field "conteneurs" "${running} en cours"
  fi
}

main() {
  local opt=""
  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -b | --brief)
        BRIEF=1
        shift
        ;;
      -t | --top)
        [[ $# -ge 2 ]] || { usage >&2; return 64; }
        TOP_PROCS="$2"
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
  [[ "${TOP_PROCS}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Top invalide: %s\n' "${TOP_PROCS}" >&2
    return 64
  }

  show_identity
  show_uptime
  show_cpu_mem
  show_disks
  if [[ "${BRIEF}" -eq 0 ]]; then
    show_processes
    show_network
  fi
  return 0
}

main "$@"
