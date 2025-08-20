#!/usr/bin/env bash
# server-stats.sh — Basic server performance snapshot
# Compatible with most modern Linux distros. No root required for core stats.
#
# What it shows
#  - Total CPU usage (1s sample)
#  - Total memory usage (used vs free + %)
#  - Total disk usage across real filesystems (used vs free + %)
#  - Top 5 processes by CPU
#  - Top 5 processes by Memory
#
# Stretch stats (best effort)
#  - OS & kernel version
#  - Uptime & load average
#  - Logged-in users
#  - Failed SSH login attempts (if tools/logs available)
#
# Usage: ./server-stats.sh
#        ./server-stats.sh --no-color  (disable ANSI colors)
#
# Exit codes: 0 ok, 1 general error

set -o pipefail

# -------- Helpers --------
COLOR=true
if [[ "${1:-}" == "--no-color" ]]; then
  COLOR=false
fi

bold()   { $COLOR && printf "\033[1m%s\033[0m" "$1" || printf "%s" "$1"; }
blue()   { $COLOR && printf "\033[34m%s\033[0m" "$1" || printf "%s" "$1"; }
green()  { $COLOR && printf "\033[32m%s\033[0m" "$1" || printf "%s" "$1"; }
yellow() { $COLOR && printf "\033[33m%s\033[0m" "$1" || printf "%s" "$1"; }
red()    { $COLOR && printf "\033[31m%s\033[0m" "$1" || printf "%s" "$1"; }

hr() { printf "%s\n" "$(printf '—%.0s' $(seq 1 60))"; }

have() { command -v "$1" >/dev/null 2>&1; }

pct() {
  # percent = (num/den)*100, rounded to 1 decimal
  awk -v n="$1" -v d="$2" 'BEGIN { if (d==0) {print "0.0"} else { printf "%.1f", (n/d)*100 } }'
}

human_bytes() {
  # Render bytes in human-friendly units
  local bytes=$1
  awk -v b="$bytes" '
    function fmt(v,u){ printf("%.1f %s", v, u) }
    BEGIN{
      if (b < 1024) { fmt(b, "B"); exit }
      b/=1024; if (b < 1024) { fmt(b, "KiB"); exit }
      b/=1024; if (b < 1024) { fmt(b, "MiB"); exit }
      b/=1024; if (b < 1024) { fmt(b, "GiB"); exit }
      b/=1024; fmt(b, "TiB")
    }'
}

# -------- CPU --------
cpu_usage() {
  # Calculate CPU usage over ~1 second using /proc/stat
  local a b idle1 idle2 non1 non2 total1 total2 idled totald usage
  read -r a b < /proc/stat  # line like: cpu  3357 0 4313 1362393 0 0 0 0 0 0
  # shellcheck disable=SC2206
  local f1=($b) # split the rest of the fields
  idle1=$((f1[3] + f1[4]))                  # idle + iowait
  non1=$((f1[0] + f1[1] + f1[2] + f1[5] + f1[6] + f1[7]))
  total1=$((idle1 + non1))
  sleep 1
  read -r a b < /proc/stat
  # shellcheck disable=SC2206
  local f2=($b)
  idle2=$((f2[3] + f2[4]))
  non2=$((f2[0] + f2[1] + f2[2] + f2[5] + f2[6] + f2[7]))
  total2=$((idle2 + non2))
  idled=$((idle2 - idle1))
  totald=$((total2 - total1))
  usage=$(pct $((totald - idled)) "$totald")
  printf "%s\n" "$usage"
}

# -------- Memory --------
mem_usage() {
  # Use /proc/meminfo for best portability
  local total_kb avail_kb used_kb used_pct
  total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  if [[ -z "$total_kb" || -z "$avail_kb" ]]; then
    # Fallback to `free -k` if needed
    if have free; then
      total_kb=$(free -k | awk '/^Mem:/ {print $2}')
      avail_kb=$(free -k | awk '/^Mem:/ {print $7}')
    fi
  fi
  used_kb=$(( total_kb - avail_kb ))
  used_pct=$(pct "$used_kb" "$total_kb")
  local total_b=$(( total_kb * 1024 ))
  local used_b=$(( used_kb * 1024 ))
  local free_b=$(( total_b - used_b ))
  printf "%s|%s|%s\n" "$used_pct" "$used_b" "$free_b"
}

# -------- Disk --------
disk_usage() {
  # Sum real filesystems (exclude tmpfs, devtmpfs, squashfs, overlay upper dir counted once)
  # Using bytes for accuracy
  if have df; then
    # shellcheck disable=SC2016
    df -B1 -x tmpfs -x devtmpfs -x squashfs 2>/dev/null \
      | awk 'NR>1 {size+=$2; used+=$3} END { if (size==0) size=1; printf("%.1f|%d|%d\n", (used/size)*100, used, size-used) }'
  else
    printf "0.0|0|0\n"
  fi
}

# -------- Top processes --------
top5_cpu() {
  if have ps; then
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu | awk 'NR==1 || NR<=6 {printf "%-7s %-20s %6s %6s\n", $1, $2, $3, $4}'
  fi
}

top5_mem() {
  if have ps; then
    ps -eo pid,comm,%mem,%cpu --sort=-%mem | awk 'NR==1 || NR<=6 {printf "%-7s %-20s %6s %6s\n", $1, $2, $3, $4}'
  fi
}

# -------- Stretch stats --------
os_kernel() {
  local os="Unknown"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os=${PRETTY_NAME:-$NAME}
  fi
  printf "%s | kernel %s\n" "$os" "$(uname -r)"
}

uptime_load() {
  local up load1 load5 load15
  if have uptime; then
    up=$(uptime -p 2>/dev/null || true)
  fi
  read -r load1 load5 load15 _ < /proc/loadavg
  printf "%s | load avg: %s %s %s\n" "${up:-uptime unavailable}" "$load1" "$load5" "$load15"
}

logged_in_users() {
  if have who; then
    local count users
    count=$(who 2>/dev/null | wc -l | awk '{print $1}')
    users=$(who 2>/dev/null | awk '{print $1}' | sort -u | xargs echo)
    printf "%d user(s): %s\n" "${count:-0}" "${users:-none}"
  else
    printf "who not available\n"
  fi
}

failed_logins() {
  # Try `lastb` (utmp/wtmp), fallback to journalctl if available.
  if have lastb; then
    local total
    total=$(lastb -w 2>/dev/null | grep -v '^btmp begins' | wc -l | awk '{print $1}')
    printf "failed ssh logins (since last rotate): %s\n" "${total:-0}"
  elif have journalctl; then
    # Count since last boot for sshd.
    local total
    total=$(journalctl -b -u sshd 2>/dev/null | grep -Eci 'Failed|authentication failure|Invalid user' || true)
    printf "failed ssh logins (this boot): %s\n" "${total:-0}"
  else
    printf "failed ssh logins: tools unavailable\n"
  fi
}

# -------- Print Report --------
print_header() {
  hr
  printf "%s %s\n" "$(bold "Server Performance Report:")" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  hr
}

print_cpu() {
  local c
  c=$(cpu_usage)
  printf "%s %s%%\n" "$(blue "CPU Usage:")" "$c"
}

print_mem() {
  local p used free
  IFS='|' read -r p used free < <(mem_usage)
  printf "%s %s used, %s free (%s%% used)\n" \
    "$(blue "Memory:")" "$(green "$(human_bytes "$used")")" "$(green "$(human_bytes "$free")")" "$p"
}

print_disk() {
  local p used free
  IFS='|' read -r p used free < <(disk_usage)
  printf "%s %s used, %s free (%s%% used)\n" \
    "$(blue "Disk (all real FS):")" "$(green "$(human_bytes "$used")")" "$(green "$(human_bytes "$free")")" "$p"
}

print_top() {
  printf "%s\n" "$(blue "Top 5 by CPU:")"
  top5_cpu
  printf "\n%s\n" "$(blue "Top 5 by Memory:")"
  top5_mem
}

print_stretch() {
  printf "\n%s\n" "$(yellow "Stretch Stats")"
  printf "%s %s\n" "OS:" "$(os_kernel)"
  printf "%s %s\n" "Uptime/Load:" "$(uptime_load)"
  printf "%s %s\n" "Logged-in:" "$(logged_in_users)"
  printf "%s %s\n" "Security:" "$(failed_logins)"
}

main() {
  print_header
  print_cpu
  print_mem
  print_disk
  printf "\n"
  print_top
  print_stretch
}

# Run
if ! main; then
  red "Error generating report"; echo; exit 1
fi
