export LC_ALL=C
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin"
exec </dev/null

JSON=0
[ "${1:-}" = "--json" ] && JSON=1
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: $0 [--json]"; exit 0
fi

# storage: three parallel lists (section, key, value)
SECS=(); KEYS=(); VALS=()
add()  { SECS+=("$1"); KEYS+=("$2"); VALS+=("$3"); }
have() { command -v "$1" >/dev/null 2>&1; }

# 1. GENERAL INFO + PERMISSIONS
NOW=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)
add general hostname "$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)"
add general time "$NOW"
add general kernel "$(uname -r)"

add permissions user "$(id -un)"
if [ "$(id -u)" -eq 0 ]; then
    add permissions is_root "true"
    add permissions note "Running as root. Not needed: this script only reads."
else
    add permissions is_root "false"
    add permissions note "Not root: process names for listening ports are hidden."
fi

# 2. CONTAINER AWARENESS
IN_CONTAINER=false
if [ -n "${container:-}" ] || [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -n "${KUBERNETES_SERVICE_HOST:-}" ] \
   || grep -qE 'docker|kubepods|lxc|containerd' /proc/1/cgroup 2>/dev/null; then
    IN_CONTAINER=true
fi
add container in_container "$IN_CONTAINER"
if [ "$IN_CONTAINER" = true ]; then
    # Memory limit of the container (cgroup v2 file, then cgroup v1 file)
    for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        if [ -r "$f" ]; then
            limit=$(cat "$f")
            [ "$limit" != "max" ] && [ "${#limit}" -lt 14 ] && add container memory_limit_mb "$((limit / 1048576))"
            break
        fi
    done
    add container note "Inside a container, CPU/memory/load numbers below describe the HOST."
fi

# 3. CPU USAGE  (read /proc/stat twice, one second apart, and compare)
cpu_read() {   # sets TOTAL (all ticks) and IDLE (idle ticks) from the first line of /proc/stat
    local u n s i w irq sirq st
    read -r _ u n s i w irq sirq st _ < /proc/stat
    TOTAL=$((u+n+s+i+w+irq+sirq+st)); IDLE=$((i+w))
}
if [ -r /proc/stat ]; then
    cpu_read; t1=$TOTAL; i1=$IDLE
    sleep 1
    cpu_read; t2=$TOTAL; i2=$IDLE
    dt=$((t2 - t1)); di=$((i2 - i1))
    [ "$dt" -gt 0 ] && add cpu usage_percent "$(( 100 * (dt - di) / dt ))"
fi
CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
add cpu cores "$CORES"

# 4. UPTIME AND LOAD AVERAGE (compared with the number of cores)
if [ -r /proc/uptime ]; then
    up=$(cut -d. -f1 /proc/uptime)
    add load uptime "$((up / 86400)) days, $((up % 86400 / 3600)) hours, $((up % 3600 / 60)) minutes"
fi
if [ -r /proc/loadavg ]; then
    read -r l1 l5 l15 _ < /proc/loadavg
    add load load_1min "$l1"; add load load_5min "$l5"; add load load_15min "$l15"
    # ${l1%.*} drops the decimals, so 4.52 becomes 4
    if [ "${l1%.*}" -ge "$CORES" ]; then add load status "HIGH - load is at or above the core count ($CORES)"
    else add load status "OK (load is below the core count of $CORES)"; fi
fi

# 5. MEMORY AND SWAP (values come from /proc/meminfo, converted to MB)
if [ -r /proc/meminfo ]; then
    meminfo() { awk -v k="$1:" '$1 == k {print int($2 / 1024)}' /proc/meminfo; }
    total=$(meminfo MemTotal); avail=$(meminfo MemAvailable); free=$(meminfo MemFree)
    swap_total=$(meminfo SwapTotal); swap_free=$(meminfo SwapFree)
    add memory total_mb "$total"
    add memory used_mb "$((total - avail))"      # "used" = total minus AVAILABLE (cache is reusable)
    add memory free_mb "$free"
    add memory available_mb "$avail"
    add memory used_percent "$(( 100 * (total - avail) / total ))"
    add swap total_mb "$swap_total"
    add swap used_mb "$((swap_total - swap_free))"
fi

# 6. DISK USAGE PER FILESYSTEM
if have df; then
    # "timeout" stops df from hanging forever on a dead network drive
    if have timeout; then out=$(timeout 10 df -P -h 2>/dev/null); else out=$(df -P -h 2>/dev/null); fi
    while read -r fs size used avail pct mnt; do
        case "$fs" in Filesystem|tmpfs|devtmpfs|udev|shm|none|squashfs) continue;; esac
        flag=""; [ "${pct%\%}" -ge 90 ] 2>/dev/null && flag=" [WARNING: almost full]"
        add disk "$mnt" "$pct used, $avail free, size $size$flag"
    done < <(printf '%s\n' "$out")
else
    add disk note "df not found - skipped"
fi

# 7. TOP PROCESSES (highest CPU and highest memory)
if have ps && ps -eo pid,pcpu,pmem,comm --sort=-pcpu >/dev/null 2>&1; then
    n=0
    while read -r pid cpu mem comm; do
        n=$((n + 1)); add top_cpu "$n" "$comm (pid $pid) cpu=$cpu% mem=$mem%"
    done < <(ps -eo pid,pcpu,pmem,comm --sort=-pcpu --no-headers | head -n 5)
    n=0
    while read -r pid cpu mem comm; do
        n=$((n + 1)); add top_memory "$n" "$comm (pid $pid) mem=$mem% cpu=$cpu%"
    done < <(ps -eo pid,pcpu,pmem,comm --sort=-pmem --no-headers | head -n 5)
    add processes zombies "$(ps -eo stat --no-headers | grep -c '^Z')"
else
    add top_cpu note "ps (procps version) not found - skipped"
fi

# 8. NETWORK (IP addresses, listening ports, connections)
if have ip; then
    while read -r _ ifname _ addr _; do add network "ip_$ifname" "$addr"; done < <(ip -o -4 addr show)
elif have hostname; then
    add network ip_addresses "$(hostname -I 2>/dev/null)"
fi

if have ss; then
    ports=$(ss -tuln | awk 'NR>1 {n=split($5, a, ":"); print a[n]}' | sort -nu | tr '\n' ' ')
    add network listening_ports "$ports"
    add network established_connections "$(ss -tan | grep -c ESTAB)"
elif have netstat; then
    add network listening_ports "$(netstat -tuln | awk 'NR>2 {n=split($4, a, ":"); print a[n]}' | sort -nu | tr '\n' ' ')"
else
    add network note "ss/netstat not found - ports skipped"
fi

# 9. LOGGED-IN USERS
if have who; then
    count=$(who | wc -l)
    add users logged_in "$count"
    n=0
    while read -r user tty d t _; do
        n=$((n + 1)); add users "session_$n" "$user on $tty since $d $t"
    done < <(who)
fi

# 10. EXTRA CHECKS (failed services, pending reboot)
if [ -d /run/systemd/system ] && have systemctl; then
    add extra failed_services "$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)"
fi
[ -f /var/run/reboot-required ] && add extra reboot_required "true"

# OUTPUT: print the stored results as JSON or as plain text
json_escape() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    printf '%s' "$s"
}

if [ "$JSON" -eq 1 ]; then
    printf '{\n  "generated_at": "%s"' "$NOW"
    prev=""
    for i in "${!KEYS[@]}"; do
        if [ "${SECS[i]}" != "$prev" ]; then
            [ -n "$prev" ] && printf '\n  }'
            printf ',\n  "%s": {\n' "${SECS[i]}"
            first=1; prev="${SECS[i]}"
        fi
        [ "$first" -eq 0 ] && printf ',\n'
        first=0
        v=${VALS[i]}
        if [[ $v =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || [ "$v" = true ] || [ "$v" = false ]; then
            printf '    "%s": %s' "$(json_escape "${KEYS[i]}")" "$v"
        else
            printf '    "%s": "%s"' "$(json_escape "${KEYS[i]}")" "$(json_escape "$v")"
        fi
    done
    printf '\n  }\n}\n'
else
    prev=""
    for i in "${!KEYS[@]}"; do
        if [ "${SECS[i]}" != "$prev" ]; then
            printf '\n== %s ==\n' "${SECS[i]}"; prev="${SECS[i]}"
        fi
        printf '  %-24s %s\n' "${KEYS[i]}" "${VALS[i]}"
    done
fi
exit 0
