# shellcheck shell=bash
#
# Shared by the jira plugin's commands: where the credential lives, how it is
# read and written, and the one function that talks to the API.
#
# lib/ rather than commands/, because only commands/ is what "claudebox
# <plugin>:<command>" dispatches on -- a file in here is a support file and
# never becomes a command by accident.
#
# ---------------------------------------------------------------------------
# The credential, and why it is here
#
# The token is a bearer credential for a JIRA site, and the box must not be able
# to use it. Two things keep it out, and both are properties of where this file
# writes rather than of anything the box is asked to respect:
#
#   - ${CLAUDEBOX_PLUGIN_STATE} is plugin-state/<plugin>/ beside the launcher,
#     and NOTHING mounts it. The box's binds are the workspace, allowlist.conf,
#     media/, the mkcert CA, plans/ and the host's ~/.claude and ~/.claude.json
#     (read-only, at /host/...) -- so this must never be written under ~/.claude,
#     which the box can read, and never into the workspace.
#   - Every compose "environment:" block is an explicit list of names. Nothing
#     here is exported to the launcher's settings or named in a compose file, so
#     no container's environment can carry it.
#
# The API call is made by this script, on the host, which is the whole reason a
# plugin command runs here rather than in the box. The box never sees the token,
# only the markdown file the call produced. Note also that allowlist.conf has no
# Atlassian entry: even handed the token, the box has no route to spend it on.
# Do not add one to "make jira work" -- nothing in the box needs to reach JIRA.
# ---------------------------------------------------------------------------

JIRA_CREDENTIALS="${CLAUDEBOX_PLUGIN_STATE}/credentials"

# Settings, empty until jira_config_load fills them in.
JIRA_URL=""
JIRA_EMAIL=""
JIRA_TOKEN=""
JIRA_ISSUE_DIR=""

jira_config_load() {
    [ -f "${JIRA_CREDENTIALS}" ] || return 0
    # shellcheck source=/dev/null
    . "${JIRA_CREDENTIALS}" || plugin_die "${JIRA_CREDENTIALS} failed to parse; fix it or run 'claudebox jira:config forget'"
}

# Rewrite one setting, atomically, with the file never readable by anyone else.
#
# The same shape as the launcher's config_set: drop any existing assignment and
# re-add it at the end, so setting a value twice replaces rather than shadows.
# %q on the value, because a token is opaque and a naive write would break on
# the first one containing a quote.
jira_config_set() {
    local key="${1}" value="${2}" dir tmp
    dir="$(plugin_state)" || return 1
    # 0700 as well as 0600: a directory listing is not a secret, but there is no
    # reason for anything but this user to read either.
    chmod 0700 "${dir}"
    [ -f "${JIRA_CREDENTIALS}" ] || {
        printf '# claudebox jira plugin. Written by "claudebox jira:config set".\n' \
            > "${JIRA_CREDENTIALS}"
        chmod 0600 "${JIRA_CREDENTIALS}"
    }
    tmp="$(mktemp "${JIRA_CREDENTIALS}.XXXXXX")"
    chmod 0600 "${tmp}"
    grep -vE "^[[:space:]]*${key}=" "${JIRA_CREDENTIALS}" > "${tmp}" || true
    if [ -n "${value}" ]; then
        printf '%s=%q\n' "${key}" "${value}" >> "${tmp}"
    fi
    mv -- "${tmp}" "${JIRA_CREDENTIALS}"
}

jira_require_config() {
    jira_config_load
    if [ -z "${JIRA_URL}" ] || [ -z "${JIRA_EMAIL}" ] || [ -z "${JIRA_TOKEN}" ]; then
        plugin_say "no JIRA credential yet -- run 'claudebox jira:config set'"
        exit 1
    fi
}

# GET a path under the configured site, printing the response body.
#
# The credential goes to curl on STDIN as a config file (-K -), not as -u on the
# command line: every argument of every process on this machine is world
# readable through /proc, and "claudebox jira:triage-issue" is exactly the sort
# of thing that sits in a scrollback or a CI log. --fail-with-body keeps the
# body on an error status, because JIRA explains itself there and the status
# alone rarely says which of several things went wrong.
#
# Sets JIRA_HTTP_STATUS. Returns non-zero on anything but 2xx, having already
# said what the status means.
jira_api() {
    local path="${1}" body status
    body="$(printf 'user = "%s:%s"\n' "${JIRA_EMAIL}" "${JIRA_TOKEN}" \
        | curl -sS -K - \
            --fail-with-body \
            --max-time 60 \
            -H 'Accept: application/json' \
            -w '\n%{http_code}' \
            "${JIRA_URL}${path}" 2>&1)" || true

    status="${body##*$'\n'}"
    body="${body%$'\n'*}"
    JIRA_HTTP_STATUS="${status}"

    case "${status}" in
        2??) printf '%s' "${body}"; return 0 ;;
        401) plugin_say "JIRA rejected the credential (401). The email must be the account's"
             plugin_say "own address and the token an API token from id.atlassian.com, not a password." ;;
        403) plugin_say "JIRA refused (403): the account is authenticated but not permitted." ;;
        404) plugin_say "no such issue, or the account cannot see it (404). JIRA answers the same"
             plugin_say "way for both, so check the key and the account's project access." ;;
        000|"") plugin_say "could not reach ${JIRA_URL}. Check the site URL and this machine's network."
             plugin_say "(the box's proxy is not involved here: this call is made on the host)" ;;
        *)   plugin_say "JIRA answered ${status}" ;;
    esac
    # The body is where JIRA says which field it disliked; print it when there is
    # one, rather than making the user re-run with curl by hand.
    #
    # curl's own stderr is captured into it too, and is dropped again for every
    # status this already explained -- "curl: (22) ... error: 404" underneath a
    # sentence about 404 is noise. The exception is a transport failure, where
    # curl's message is the only diagnosis there is.
    if [ -n "${body}" ] && [ "${body}" != "${status}" ]; then
        case "${status}" in
            000|"") printf '%s\n' "${body}" | head -5 >&2 ;;
            *)      printf '%s\n' "${body}" | grep -v '^curl: ' | head -5 >&2 || true ;;
        esac
    fi
    return 1
}
