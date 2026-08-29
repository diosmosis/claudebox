# Temporary egress: domains allowed only while they are still being used.
#
#   claudebox allow --for 15m example.com
#
# adds the domain to a managed block at the end of allowlist.conf and starts a
# small host-side reaper. The reaper watches the proxy's access log and drops
# the entry once the domain has gone unused for its idle window, so the hole
# closes by itself.
#
# Why an idle window rather than a deadline: the thing being guarded against is
# a hole left open by accident, and a deadline has to be guessed up front --
# guess short and it expires in the middle of the install it was opened for,
# guess long and it is a permanent entry with extra steps. "Nobody is using it
# any more" is the property that actually matters, and it needs no guess.
#
# The state lives in allowlist.conf itself rather than beside it, because that
# file is the one the proxy actually reads: an entry that is in the list is
# allowed and an entry that is not is denied, with no second file that can
# disagree with it. Each line carries when it was last active and how long it
# may idle, so an expiry is still computable after a reboot has killed the
# reaper.
#
# Sourced by "claudebox" (which has reload_proxy) and by "allow-reaper" (which
# does not). Functions and constants only -- nothing here runs at source time,
# and ALLOWLIST/PROXY/BOX_DIR must already be set.

# The markers delimiting the managed block, matched at the start of a line.
# Everything between them is generated; everything outside it is the user's.
ALLOW_TEMP_BEGIN='#>>> claudebox-temp'
ALLOW_TEMP_END='#<<< claudebox-temp'

# How long a temporary entry may go unused before it is dropped, when "--temp"
# is used without a duration. Overridable per machine as BOX_ALLOW_TEMP_IDLE.
ALLOW_TEMP_IDLE_DEFAULT='15m'

# Nothing shorter than this is accepted: the reaper only looks every
# ALLOW_REAPER_TICK seconds, so a window below that would expire at a time
# nobody could predict, and the first request would arrive after the entry had
# already gone.
ALLOW_TEMP_IDLE_MIN=60

ALLOW_REAPER_TICK="${ALLOW_REAPER_TICK:-30}"
ALLOW_REAPER_BIN="${BOX_DIR}/allow-reaper"
ALLOW_REAPER_LOCK="${BOX_DIR}/.allow-reaper.lock"
ALLOW_REAPER_PID="${BOX_DIR}/.allow-reaper.pid"
ALLOW_REAPER_LOG="${BOX_DIR}/.allow-reaper.log"
ALLOWLIST_LOCK="${ALLOWLIST}.lock"

# How much of the proxy's access log to read when working out when a domain was
# last used. Bounded because the log is never rotated by anything here; the tail
# is where recent activity is, and activity older than the largest sensible idle
# window cannot keep an entry alive anyway.
ALLOW_TEMP_LOG_BYTES=4000000

# ---------------------------------------------------------------------------
# Durations
# ---------------------------------------------------------------------------

# "90s", "15m", "2h", "1d" -- or a bare number, read as minutes, because that is
# what someone typing "claudebox allow --for 30" means. Prints seconds.
allow_duration_secs() {
    local s="${1}" n unit
    case "${s}" in
        '') return 1 ;;
        *[0-9]) n="${s}"; unit=m ;;
        *[smhdSMHD]) n="${s%?}"; unit="${s: -1}"; unit="${unit,,}" ;;
        *) return 1 ;;
    esac
    case "${n}" in ''|*[!0-9]*) return 1 ;; esac
    case "${unit}" in
        s) printf '%s' "$((10#${n}))" ;;
        m) printf '%s' "$((10#${n} * 60))" ;;
        h) printf '%s' "$((10#${n} * 3600))" ;;
        d) printf '%s' "$((10#${n} * 86400))" ;;
    esac
}

# Seconds back to the same spelling, for anything shown to a person.
allow_duration_human() {
    local s="${1}" parts=() out
    if [ "${s}" -le 0 ]; then
        printf '0s'
        return 0
    fi
    if [ "${s}" -ge 86400 ]; then parts+=("$((s / 86400))d"); s=$((s % 86400)); fi
    if [ "${s}" -ge 3600 ];  then parts+=("$((s / 3600))h");  s=$((s % 3600));  fi
    if [ "${s}" -ge 60 ];    then parts+=("$((s / 60))m");    s=$((s % 60));    fi
    if [ "${s}" -gt 0 ];     then parts+=("${s}s"); fi
    # Two units: exact where the difference matters ("1m30s") and short where it
    # does not ("2h" rather than "2h0m0s").
    out="${parts[0]}"
    if [ "${#parts[@]}" -gt 1 ]; then
        out="${out}${parts[1]}"
    fi
    printf '%s' "${out}"
}

# ---------------------------------------------------------------------------
# The managed block
# ---------------------------------------------------------------------------

# Everything in allowlist.conf that is NOT the managed block -- i.e. the list as
# the user wrote it. Used both to rewrite the block and to answer "is this
# domain permanently allowed", which a temporary entry must never be mistaken
# for.
allow_temp_permanent() {
    [ -f "${ALLOWLIST}" ] || return 0
    awk -v b="${ALLOW_TEMP_BEGIN}" -v e="${ALLOW_TEMP_END}" '
        index($0, b) == 1 { inblk = 1; next }
        index($0, e) == 1 { inblk = 0; next }
        !inblk           { print }
    ' "${ALLOWLIST}"
}

# The managed block as "domain<TAB>since<TAB>idle" lines, where "since" is when
# the domain was last seen in use (or added, if it never has been) and "idle" is
# its window in seconds. Malformed lines are skipped rather than guessed at: a
# temporary entry whose expiry cannot be computed would otherwise be a permanent
# one that looks temporary.
allow_temp_entries() {
    [ -f "${ALLOWLIST}" ] || return 0
    awk -v b="${ALLOW_TEMP_BEGIN}" -v e="${ALLOW_TEMP_END}" '
        index($0, b) == 1 { inblk = 1; next }
        index($0, e) == 1 { inblk = 0; next }
        !inblk { next }
        {
            line = $0
            dom = line
            sub(/[ \t]*#.*$/, "", dom)
            gsub(/[ \t]/, "", dom)
            if (dom == "") next
            since = 0; idle = 0
            if (match(line, /since=[0-9]+/)) since = substr(line, RSTART + 6, RLENGTH - 6) + 0
            if (match(line, /idle=[0-9]+/))  idle  = substr(line, RSTART + 5, RLENGTH - 5) + 0
            if (since <= 0 || idle <= 0) next
            printf "%s\t%d\t%d\n", dom, since, idle
        }
    ' "${ALLOWLIST}"
}

# Replace the managed block with the "domain<TAB>since<TAB>idle" lines on stdin,
# dropping the block entirely when there are none so allowlist.conf goes back to
# looking untouched between uses.
#
# Written IN PLACE, over the same inode. allowlist.conf is bind-mounted into the
# proxy as a single file, and a mktemp-and-rename would leave the container
# holding the old inode -- the exact "allow reported success while the domain
# stayed blocked" failure allowlist_in_sync exists to catch. So the new contents
# are staged in a temp file and then copied over the original, which truncates
# and rewrites it without replacing it.
allow_temp_write() {
    local entries body tmp dom since idle
    entries="$(cat)"
    body="$(allow_temp_permanent)"
    # Trailing blank lines are the block's own separator coming back; without
    # this the file grows a blank line every time the block is rewritten.
    body="${body%"${body##*[![:space:]]}"}"

    # Every write here truncates the real allowlist, so an empty body coming
    # back from a file that is not empty is not a list with nothing in it -- it
    # is awk having failed, and going ahead would delete the user's allowlist
    # outright. Egress would fail closed rather than open, but the file would be
    # gone, which is its own kind of unrecoverable.
    if [ -z "${body}" ] && [ -s "${ALLOWLIST}" ]; then
        echo "allow-temp: refusing to rewrite ${ALLOWLIST}: it reads as empty" >&2
        return 1
    fi

    tmp="$(mktemp "${ALLOWLIST}.XXXXXX")"
    printf '%s\n' "${body}" > "${tmp}"
    if [ -n "${entries}" ]; then
        {
            printf '\n'
            printf '%s -- written by "claudebox allow --for"; edits here are overwritten.\n' \
                "${ALLOW_TEMP_BEGIN}"
            printf '# Each entry is dropped once the domain has gone unused for its idle window.\n'
            printf '# since = unix time it was last seen in use, idle = the window, in seconds.\n'
            while IFS=$'\t' read -r dom since idle; do
                [ -n "${dom}" ] || continue
                printf '%-31s # temporary: since=%s idle=%s\n' "${dom}" "${since}" "${idle}"
            done <<< "${entries}"
            printf '%s\n' "${ALLOW_TEMP_END}"
        } >> "${tmp}"
    fi
    cat -- "${tmp}" > "${ALLOWLIST}"
    rm -f -- "${tmp}"
}

# ---------------------------------------------------------------------------
# Locking
#
# The reaper rewrites allowlist.conf from a background process while "claudebox
# allow" may be rewriting it in the foreground, and the rewrite is a truncate
# followed by a write -- there is a window in which the file is empty, and an
# empty allowlist denies everything. flock closes it. Where flock is missing the
# work still goes ahead: a lost race costs one entry, refusing to run costs the
# feature.
# ---------------------------------------------------------------------------

# Nothing but the fd may be redirected on these two "exec"s. A bare exec applies
# its redirections to the shell itself and they OUTLIVE the call, so a
# "2>/dev/null" tacked on to quieten a failed open silently discards the stderr
# of everything that runs afterwards -- which, for a launcher that says
# everything it does on stderr, is the whole session going quiet.
allow_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    # Ordinary redirection, safe to guard: proves the lock file can be opened
    # before exec is asked to do it, since a failed exec redirection takes the
    # shell down with it.
    : >> "${ALLOWLIST_LOCK}" 2>/dev/null || return 0
    exec 8>>"${ALLOWLIST_LOCK}"
    flock -w 10 8 2>/dev/null || true
}

allow_unlock() {
    exec 8>&-
}

# ---------------------------------------------------------------------------
# When was a domain last used?
# ---------------------------------------------------------------------------

# "host last-seen-unix-time" for every host the proxy has logged recently. The
# log line is squid.conf's "claudebox" logformat: timestamp, client, result,
# method, request. The request is "host:443" for a CONNECT tunnel and a full URL
# for anything else, so both are reduced to a bare hostname here.
#
# Denied requests count as use. That sounds wrong and is not: a request only
# reaches this list while the domain is allowed, and a denial for one that is
# still in the block means the proxy has not caught up with the list yet -- not
# that nobody wants it.
#
# The one blind spot: squid writes a tunnel's log line when the tunnel CLOSES,
# so a single CONNECT held open for longer than the whole idle window looks
# idle the entire time it is downloading. Measured rather than assumed, that
# turns out to be survivable -- squid evaluates http_access when a request
# arrives and not again afterwards, so "squid -k reconfigure" does not touch a
# transfer already in flight, and it finishes. What the withdrawal costs is the
# NEXT request, which is denied and shows up in "claudebox denied". Anything
# that fetches more than one thing -- every package manager -- logs each one as
# it completes and keeps its entry alive normally.

# The log itself. Split out from the parsing below so the parsing can be run
# against a fixture without a container -- it is the part with the rules in it.
# A proxy that is down or has never logged anything yields nothing, and nothing
# is a valid answer: it means no temporary entry has been used lately.
allow_temp_access_log() {
    docker exec "${PROXY}" \
        tail -c "${ALLOW_TEMP_LOG_BYTES}" /var/log/squid/access.log 2>/dev/null \
        | tr -d '\000' || true
}

allow_temp_access() {
    allow_temp_access_log \
        | awk '
            NF >= 5 {
                ts = $1 + 0
                u = $5
                sub(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "", u)
                sub(/\/.*$/, "", u)
                sub(/@.*$/, "", u)
                sub(/:[0-9]+$/, "", u)
                if (u == "" || u == "-") next
                h = tolower(u)
                if (ts > seen[h]) seen[h] = ts
            }
            END { for (h in seen) printf "%s %d\n", h, seen[h] }
        ' || true
}

# Does one allowlist pattern cover one hostname? The same four spellings
# allowlist.sh expands for squid, applied here so that "allow --for '*.foo.com'"
# is kept alive by traffic to bar.foo.com. A "*" inside a label matches within
# that label only, exactly as it does there.
allow_host_matches() {
    local pat="${1,,}" host="${2,,}" rest re
    case "${pat}" in
        '*.'*) rest="${pat#\*.}" ;;
        '.'*)  rest="${pat#.}" ;;
        *)
            if [[ "${pat}" == *'*'* ]]; then
                re="$(printf '%s' "${pat}" | sed -e 's/[][^$.|?+(){}\\]/\\&/g' -e 's/\*/[^.]*/g')"
                [[ "${host}" =~ ^${re}$ ]]
                return
            fi
            [ "${host}" = "${pat}" ]
            return
            ;;
    esac
    # A suffix entry covers the apex as well as everything under it, which is
    # what squid's dstdomain does with the same value.
    if [[ "${rest}" == *'*'* ]]; then
        re="$(printf '%s' "${rest}" | sed -e 's/[][^$.|?+(){}\\]/\\&/g' -e 's/\*/[^.]*/g')"
        [[ "${host}" =~ ^(.+\.)?${re}$ ]]
        return
    fi
    [ "${host}" = "${rest}" ] || [ "${host}" != "${host%".${rest}"}" ]
}

# ---------------------------------------------------------------------------
# The passes
# ---------------------------------------------------------------------------

# Names the reap dropped, for the caller to report. Set by allow_temp_reap.
ALLOW_TEMP_DROPPED=""

# One expiry pass: refresh every entry's "since" from the access log, drop the
# ones that have gone quiet for longer than their window, and rewrite the block.
#
# Deliberately does NOT reload the proxy -- the caller does, once, after
# whatever else it was going to change. Returns 0 when the file changed.
allow_temp_reap() {
    local entries access now dom since idle last stale host ts kept="" changed=0
    ALLOW_TEMP_DROPPED=""
    entries="$(allow_temp_entries)"
    [ -n "${entries}" ] || return 1
    now="$(date +%s)"
    access="$(allow_temp_access)"

    while IFS=$'\t' read -r dom since idle; do
        [ -n "${dom}" ] || continue
        last="${since}"
        if [ -n "${access}" ]; then
            while read -r host ts; do
                [ -n "${host}" ] || continue
                if [ "${ts}" -gt "${last}" ] && allow_host_matches "${dom}" "${host}"; then
                    last="${ts}"
                fi
            done <<< "${access}"
        fi
        # A clock that went backwards, or a log line from the future, would
        # otherwise pin an entry open forever.
        if [ "${last}" -gt "${now}" ]; then
            last="${now}"
        fi
        if [ "$((now - last))" -ge "${idle}" ]; then
            ALLOW_TEMP_DROPPED="${ALLOW_TEMP_DROPPED}${dom} "
            changed=1
            continue
        fi
        # Writing the refreshed timestamp back is what lets an expiry still be
        # computed after the reaper has been killed -- but a domain in steady
        # use would otherwise rewrite the file on every tick, so only record it
        # once it has drifted far enough to be worth the write.
        stale=$((idle / 4))
        if [ "${stale}" -lt 60 ]; then
            stale=60
        fi
        if [ "$((last - since))" -ge "${stale}" ]; then
            changed=1
        else
            last="${since}"
        fi
        kept="${kept}${dom}"$'\t'"${last}"$'\t'"${idle}"$'\n'
    done <<< "${entries}"

    [ "${changed}" -eq 1 ] || return 1
    # A write that refused itself has withdrawn nothing, and saying otherwise
    # would have the caller reload a proxy that is still serving the domain and
    # report it as gone. Report no change instead: the reaper tries again on the
    # next tick, and the guard has already said why on stderr.
    if ! printf '%s' "${kept}" | allow_temp_write; then
        ALLOW_TEMP_DROPPED=""
        return 1
    fi
    ALLOW_TEMP_DROPPED="${ALLOW_TEMP_DROPPED% }"
    return 0
}

# Add or refresh one temporary entry. Sets ALLOW_TEMP_REFRESHED=1 when the
# domain was already in the block, so the caller can say which happened.
ALLOW_TEMP_REFRESHED=0
allow_temp_add() {
    local domain="${1}" idle="${2}" now entries out="" dom since old
    ALLOW_TEMP_REFRESHED=0
    now="$(date +%s)"
    entries="$(allow_temp_entries)"
    while IFS=$'\t' read -r dom since old; do
        [ -n "${dom}" ] || continue
        if [ "${dom}" = "${domain}" ]; then
            ALLOW_TEMP_REFRESHED=1
            out="${out}${dom}"$'\t'"${now}"$'\t'"${idle}"$'\n'
        else
            out="${out}${dom}"$'\t'"${since}"$'\t'"${old}"$'\n'
        fi
    done <<< "${entries}"
    if [ "${ALLOW_TEMP_REFRESHED}" -eq 0 ]; then
        out="${out}${domain}"$'\t'"${now}"$'\t'"${idle}"$'\n'
    fi
    printf '%s' "${out}" | allow_temp_write
}

# Drop one entry from the block, for a domain that is being made permanent.
# Returns 0 when it was there.
allow_temp_remove() {
    local domain="${1}" entries out="" dom since idle found=1
    entries="$(allow_temp_entries)"
    [ -n "${entries}" ] || return 1
    while IFS=$'\t' read -r dom since idle; do
        [ -n "${dom}" ] || continue
        if [ "${dom}" = "${domain}" ]; then
            found=0
        else
            out="${out}${dom}"$'\t'"${since}"$'\t'"${idle}"$'\n'
        fi
    done <<< "${entries}"
    [ "${found}" -eq 0 ] || return 1
    printf '%s' "${out}" | allow_temp_write
}

# ---------------------------------------------------------------------------
# The reaper
#
# A detached host-side process, not a container one: the expiry has to rewrite
# allowlist.conf, and that file is the host's -- the container sees a bind mount
# of it and writing back through that mount is the direction this codebase has
# already been bitten by.
#
# It exits on its own once the block is empty, so there is no daemon to manage
# and nothing running on a machine that has never used the feature.
# ---------------------------------------------------------------------------

allow_reaper_running() {
    local pid
    [ -f "${ALLOW_REAPER_PID}" ] || return 1
    pid="$(cat "${ALLOW_REAPER_PID}" 2>/dev/null || true)"
    case "${pid}" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "${pid}" 2>/dev/null || return 1
    # A pid file outlives the process that wrote it, and pids are reused. Where
    # the command line can be read, check it is still the reaper.
    if [ -r "/proc/${pid}/cmdline" ]; then
        tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -q 'allow-reaper' || return 1
    fi
    return 0
}

# Start one if the block is not empty and none is running. Safe to call on any
# path: it does nothing at all when there are no temporary entries, and the
# reaper itself refuses to start a second copy.
allow_reaper_ensure() {
    if [ -z "$(allow_temp_entries)" ]; then
        return 0
    fi
    if allow_reaper_running; then
        return 0
    fi
    if [ ! -x "${ALLOW_REAPER_BIN}" ]; then
        echo "claudebox: ${ALLOW_REAPER_BIN} is missing or not executable; temporary" >&2
        echo "claudebox: entries will only expire when a claudebox command next runs" >&2
        return 1
    fi
    # setsid so it survives the terminal this was typed in. Where it is missing,
    # a plain background job with stdin closed is close enough.
    if command -v setsid >/dev/null 2>&1; then
        setsid "${ALLOW_REAPER_BIN}" >>"${ALLOW_REAPER_LOG}" 2>&1 </dev/null &
    else
        "${ALLOW_REAPER_BIN}" >>"${ALLOW_REAPER_LOG}" 2>&1 </dev/null &
    fi
    disown 2>/dev/null || true
    return 0
}

# The whole of it, for a command that is about to read or reload the allowlist:
# expire what has gone quiet, and make sure something is watching the rest.
# Prints what it dropped.
#
# Returns 0 only when a domain was actually withdrawn, which is the only case
# the proxy has to be told about -- a refreshed timestamp changes the file but
# not the set of hosts squid allows.
allow_temp_sync() {
    allow_lock
    allow_temp_reap || true
    allow_unlock
    allow_reaper_ensure || true
    if [ -n "${ALLOW_TEMP_DROPPED}" ]; then
        echo "claudebox: temporary access expired: ${ALLOW_TEMP_DROPPED}" >&2
        return 0
    fi
    return 1
}
