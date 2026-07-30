#!/usr/bin/env bash
#
# Translate the user-editable allowlist into the ACL files Squid can match on.
#
#   allowlist build    regenerate the ACL files from allowlist.conf
#   allowlist reload   regenerate, validate, then apply without dropping egress
#
# Squid's dstdomain ACL has no wildcard syntax. "*.example.com" is taken as a
# literal hostname, matches nothing, and is not reported as an error -- an entry
# that looks like it works and silently does not. Rather than expect everyone to
# remember that, this accepts the wildcard spelling and emits what Squid
# actually understands:
#
#   example.com          exact host
#   .example.com         the domain and every subdomain (Squid's own syntax)
#   *.example.com        the same, spelled the way people expect
#   api-*.example.com    "*" inside a label -- emitted as an anchored dstdom_regex
#
# Outside a leading "*.", a "*" matches within one label only: it never crosses
# a dot, so a pattern cannot be widened by accident. Regexes are anchored at
# both ends, so "*.example.com" cannot be satisfied by "example.com.evil.net".
#
# Anything unusable is dropped with a message on stderr rather than in silence.
# That is the whole point: a rule that does not apply must never look like one
# that does.

set -uo pipefail

# Overridable so the expansion can be exercised outside the container; squid.conf
# reads the defaults.
SRC="${ALLOWLIST_SRC:-/etc/squid/allowlist.conf}"
DOM="${ALLOWLIST_DOMAINS:-/etc/squid/allowlist.domains}"
RE="${ALLOWLIST_REGEX:-/etc/squid/allowlist.regex}"
CONF=/etc/squid/squid.conf

# A host that cannot exist (.invalid is reserved by RFC 6761) and a regex no
# hostname can match. One of these is emitted when a section would otherwise be
# empty, so an empty allowlist denies everything by construction instead of
# depending on how Squid treats an ACL file with no values.
NEVER_DOMAIN='never.matches.invalid'
NEVER_REGEX='^$'

warn() { printf 'allowlist: %s\n' "$*" >&2; }

# Squid refuses to start at all if one dstdomain value is a subdomain of
# another: "ERROR: 'raw.githubusercontent.com' is a subdomain of
# '.githubusercontent.com' ... FATAL: Bungled squid.conf". Since ".example.com"
# already covers example.com and everything under it, the narrower entries are
# redundant -- fold them away rather than let a legal-looking allowlist take the
# proxy down. Reads entries on stdin, writes the survivors to stdout.
fold_domains() {
    local -a entries=()
    local e s drop folded=""

    while IFS= read -r e; do
        if [ -z "${e}" ]; then
            continue
        fi
        drop=0
        for s in ${entries[@]+"${entries[@]}"}; do
            if [ "${s}" = "${e}" ]; then
                drop=1
                break
            fi
        done
        if [ "${drop}" -eq 0 ]; then
            entries+=("${e}")
        fi
    done

    for e in ${entries[@]+"${entries[@]}"}; do
        drop=0
        for s in ${entries[@]+"${entries[@]}"}; do
            # Only a ".domain" entry can contain another one.
            if [ "${s}" = "${e}" ] || [ "${s#.}" = "${s}" ]; then
                continue
            fi
            # The apex itself, or anything ending in the suffix.
            if [ "${e}" = "${s#.}" ] || [ "${e}" != "${e%"${s}"}" ]; then
                drop=1
                break
            fi
        done
        if [ "${drop}" -eq 1 ]; then
            folded="${folded} ${e}"
        else
            printf '%s\n' "${e}"
        fi
    done

    if [ -n "${folded}" ]; then
        warn "already covered by a broader entry:${folded}"
    fi
}

build() {
    local dom="${DOM}.new" re="${RE}.new" raw="${DOM}.raw"
    local line entry rest esc suffix f
    local dom_n=0 re_n=0

    if [ ! -r "${SRC}" ]; then
        warn "cannot read ${SRC}; denying everything"
        printf '%s\n' "${NEVER_DOMAIN}" > "${dom}"
        printf '%s\n' "${NEVER_REGEX}" > "${re}"
    else
        : > "${raw}"
        : > "${re}"

        # Word splitting below is wanted; globbing is not. Without this a bare
        # "*" expands to the filenames in squid's working directory and every
        # one of them lands in the allowlist as a domain.
        set -f

        while IFS= read -r line || [ -n "${line}" ]; do
            line="${line%%#*}"

            # Unquoted on purpose: Squid's own list files accept several entries
            # on one line, so this splits on whitespace the same way.
            for entry in ${line}; do
                entry="${entry,,}"

                case "${entry}" in
                    *[!a-z0-9.*_-]*)
                        warn "ignoring '${entry}': not a domain pattern"
                        continue
                        ;;
                esac

                # "*", "*.", "." and friends carry no hostname at all. Emitting
                # them would turn the gate off, which is never what was meant.
                if [ -z "${entry//[.*]/}" ]; then
                    warn "refusing '${entry}': it would allow every host"
                    continue
                fi

                suffix=""
                if [[ "${entry}" != *'*'* ]]; then
                    # Plain host or Squid's own ".domain" form -- pass through.
                    printf '%s\n' "${entry}" >> "${raw}"
                    suffix="${entry}"
                elif [[ "${entry}" == '*.'* && "${entry#\*.}" != *'*'* ]]; then
                    # The common case. dstdomain matches the apex too, so
                    # "*.example.com" covers example.com and every subdomain.
                    rest="${entry#\*.}"
                    printf '.%s\n' "${rest}" >> "${raw}"
                    suffix=".${rest}"
                else
                    # A "*" somewhere other than the front. Escape every regex
                    # metacharacter, then turn "*" into a single-label match.
                    esc="$(printf '%s' "${entry}" \
                        | sed -e 's/[][^$.|?+(){}\\]/\\&/g' -e 's/\*/[^.]*/g')"
                    printf '^%s$\n' "${esc}" >> "${re}"
                    re_n=$((re_n + 1))
                fi

                # ".com" and "*.com" allow an entire top-level domain. Legal,
                # occasionally deliberate, worth saying out loud.
                case "${suffix}" in
                    .*)
                        case "${suffix#.}" in
                            *.*) ;;
                            *) warn "'${entry}' allows an entire top-level domain" ;;
                        esac
                        ;;
                esac
            done
        done < "${SRC}"

        set +f

        fold_domains < "${raw}" > "${dom}"
        rm -f -- "${raw}"
        dom_n="$(grep -c . "${dom}" || true)"

        if [ "${dom_n}" -eq 0 ]; then
            printf '%s\n' "${NEVER_DOMAIN}" > "${dom}"
        fi
        if [ "${re_n}" -eq 0 ]; then
            printf '%s\n' "${NEVER_REGEX}" > "${re}"
        fi
        if [ "$((dom_n + re_n))" -eq 0 ]; then
            warn "no usable entries in ${SRC}; all egress is denied"
        fi
    fi

    # Keep the previous generation so a failed validation can be rolled back.
    for f in "${DOM}" "${RE}"; do
        if [ -f "${f}" ]; then
            cp -f -- "${f}" "${f}.bak"
        fi
    done
    mv -f -- "${dom}" "${DOM}"
    mv -f -- "${re}" "${RE}"

    warn "${dom_n} domain, ${re_n} regex entries"
    return 0
}

restore() {
    local f
    for f in "${DOM}" "${RE}"; do
        if [ -f "${f}.bak" ]; then
            mv -f -- "${f}.bak" "${f}"
        fi
    done
}

# Exit codes are load-bearing: the launcher restarts the proxy when a reload
# fails, and it must not do that after a validation failure -- a restart would
# rebuild from the same bad source and take squid down with it. 3 means "kept
# the old list, do not restart"; 4 means "list is fine, applying it failed".
reload() {
    build

    if ! squid -k parse -f "${CONF}" > /tmp/allowlist-parse.log 2>&1; then
        warn "generated config does not parse; keeping the previous allowlist"
        # "squid -k parse" echoes the whole config; show the complaint, not the
        # transcript.
        if ! grep -aE 'FATAL|ERROR|unrecognized|Bungled' /tmp/allowlist-parse.log \
            | sed -e 's/^/  /' >&2; then
            tail -n 10 /tmp/allowlist-parse.log | sed -e 's/^/  /' >&2
        fi
        restore
        return 3
    fi

    if ! squid -k reconfigure -f "${CONF}" 2>/dev/null; then
        warn "squid -k reconfigure failed"
        return 4
    fi
    return 0
}

case "${1:-build}" in
    build)  build ;;
    reload) reload ;;
    *)
        printf 'usage: allowlist [build|reload]\n' >&2
        exit 2
        ;;
esac
