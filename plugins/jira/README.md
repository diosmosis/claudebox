# jira -- triage an issue in the box

```
claudebox jira:config                       set the site, account and API token
claudebox jira:triage-issue AS-345          fetch it, then have the box triage it
```

`jira:triage-issue` does two things, and the line between them is the design:

| | |
|---|---|
| **on the host** | fetch the issue with the API token and write it into the project as `AS-345.md` |
| **in the box** | a headless `claude` session, in auto mode, handed the issue text **in its prompt**, that decides whether the bug is real and writes a failing regression test on a new branch |

Claude's answer is printed when it finishes, and kept in
`plugin-state/jira/runs/`.

Nothing prints while it runs, because `claude -p` is print mode — it emits its
answer at the end and nothing before. So the command prints `still running
(2m30s)` every thirty seconds, and `claudebox ps` on the machine actually
running it shows which project it is in and what it is executing. Interrupting
stops the session rather than just stopping the wait.

The issue goes into the prompt itself rather than as a path to open, so the run
is self-contained: the agent has the whole report before it starts instead of a
filename it has to decide to read. `<KEY>.md` is still written — it is the
artefact, and `--fetch-only` produces nothing else — but nothing in the prompt
depends on it. It is delimited with a tag rather than a code fence, since issues
routinely contain fences of their own and a fence here would end at the first
one in a stack trace.

The exception is an issue too big to fit: `execve` caps a single argument at
128KB and a prompt is one argument, so past ~100KB the command degrades and says
so. The alternative is `docker: Argument list too long`, which says nothing
about issues or prompts.

How it degrades depends on which machine will answer. Normally it points the
prompt at the file, which loses nothing since the file is right there. On a
machine that **hosts a runner** the session is answered on the workstation while
the file stays here, so it sends the first 100KB with a note that the rest was
cut — a path would point at nothing over there. Issues get large because of a
pasted log, which is at the end; the report is at the top.

That is also why this plugin works on a runner machine at all: it fetches with a
credential that lives there, and the headless run it asks for is forwarded. The
prompt carrying the issue rather than a path is what makes the two halves able
to be on different machines.

## The token stays on this machine

A plugin command runs on the host, so the API call does too. What crosses into
the box is the issue text, in a prompt and in a file in the project -- and
nothing else. Three things keep it that way, and none of them depend on the box
being asked to behave:

- The credential lives in `plugin-state/jira/credentials` (`0600`, in a `0700`
  directory). **No container mounts that path.** The box's binds are the
  workspace, `allowlist.conf`, `media/`, the mkcert CA, `plans/`, and the host's
  `~/.claude` and `~/.claude.json` read-only -- which is why the credential must
  never be written under `~/.claude` or into the workspace.
- Every compose `environment:` block is an explicit list of names. Nothing here
  is a launcher setting and nothing names it in a compose file, so no
  container's environment carries it.
- `allowlist.conf` has no Atlassian entry, so the box has no route to JIRA to
  spend a token on even if one reached it. **Do not add one** -- nothing in the
  box needs to reach JIRA, and the absence is part of the design.

The token is also kept out of the process table: `curl` reads it from a config
file on stdin (`-K -`) rather than from `-u`, because every process's arguments
are readable by every process on the machine. For the same reason there is no
`--token` flag -- it is prompted for without echo, or read with `--token-stdin`.

Check any of this yourself:

```sh
docker exec claudebox env | grep -i jira            # nothing
claudebox shell -c 'cat ~/.claudebox/plugin-state/jira/credentials'   # no such file
```

## Setting it up

```sh
claudebox jira:config set        # prompts for site, account email and token
claudebox jira:config            # shows what is set; never the token
claudebox jira:config test       # asks JIRA who the credential belongs to
claudebox jira:config forget     # deletes it (does not revoke it)
```

The token is an **API token** from
<https://id.atlassian.com/manage-profile/security/api-tokens>, not the account
password, and the email must be that account's own address -- Jira Cloud
authenticates as `email:api_token`.

`--issue-dir` sets where `<KEY>.md` is written, relative to the project. The
default is the project root; `--dir` overrides it for one run.

## Triaging

```sh
cd ~/Projects/matomo
claudebox jira:triage-issue MWP-123
claudebox jira:triage-issue AS-345 --project ~/Projects/matomo --dir .jira
claudebox jira:triage-issue AS-345 --fetch-only     # write the markdown, stop there
```

The project must be a git repository (claude is asked to branch) and must be
inside the workspace, since that is the only host tree the box can see. A dirty
tree is a warning, not an error -- but a branch made over one carries the
changes along.

## Layout

    jira/
      commands/
        config          ->  claudebox jira:config
        triage-issue    ->  claudebox jira:triage-issue
      lib/
        jira.sh         credential storage and the API call
        render-issue.js Atlassian Document Format -> markdown

Only `commands/` is dispatched on, so `lib/` is support code and never becomes a
command.

`render-issue.js` exists because Jira Cloud's API v3 returns the description as
ADF -- a tree of typed nodes, not text -- and there is no way to ask that
endpoint for markdown. It covers what bug reports are made of, above all code
blocks, since that is where the stack trace or the payload lives. An unknown
node renders its children rather than being dropped: losing part of a report
silently would leave the agent working from half of it. It is a plain
stdin-to-stdout filter with no dependencies, so it runs under the host's node,
or the box's node 22 when the host has none -- which is a real case, since node
installed through nvm is absent from a non-interactive `PATH`.
