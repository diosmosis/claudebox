# example -- a worked claudebox plugin

The reference plugin, shipped so that adding another is a matter of copying a
directory rather than reading the launcher. It is already installed, because
being in `plugins/` is what installing means:

    claudebox plugins
    claudebox example:hello world
    claudebox example:versions
    claudebox example:where .

Nothing registers a plugin and nothing generates anything from it. `plugins/`
beside the launcher is searched by default; `BOX_PLUGIN_PATH` (colon-separated,
settable in `config`) replaces that list, so a plugin kept elsewhere joins by
naming its directory there.

## Layout

    example/
      commands/
        hello       ->  claudebox example:hello [args]
        versions    ->  claudebox example:versions
        where       ->  claudebox example:where [path]
      README.md     ->  ignored; only commands/ is looked at

A new plugin is `cp -r plugins/example plugins/<name>`, then rewrite the
commands. Keep them small: a plugin is a place to put a command, not a place to
put a program.

A command is any executable, in any language. The `# description:` line in its
first 20 lines is what `claudebox plugins` prints beside it.

## What a command is handed

Every setting the launcher resolved is exported, so a command sees the same box
the launcher does:

| Variable | |
|---|---|
| `BOX_WORKSPACE` | where the box sees the tree |
| `BOX_WORKSPACE_HOST` | the host directory bound there |
| `BOX_USER`, `BOX_UID`, `BOX_GID` | who the box runs as |
| `BOX_HOST_HOME`, `BOX_MKCERT_CA`, `BOX_DDEV_PROJECT` | the rest of the settings |
| `CLAUDEBOX_DIR` | the claudebox checkout |
| `CLAUDEBOX_CONTAINER`, `CLAUDEBOX_PROXY_CONTAINER` | container names |
| `CLAUDEBOX_COMPOSE_FILES` | newline-separated, both compose files |
| `CLAUDEBOX_PLUGIN`, `CLAUDEBOX_PLUGIN_COMMAND` | how it was invoked |
| `CLAUDEBOX_PLUGIN_DIR` | this directory -- where support files live |
| `CLAUDEBOX_PLUGIN_STATE` | a scratch directory under `plugin-state/`, gitignored, created only if asked for |
| `CLAUDEBOX_PLUGIN_API` | the shell helpers below |

A shell command can source the API for the rest:

    . "${CLAUDEBOX_PLUGIN_API}"

| Function | |
|---|---|
| `box_exec [-w dir] <cmd...>` | run in the box as the box user, in this directory's counterpart |
| `box_exec_root [-w dir] <cmd...>` | the same as root |
| `box_running` / `box_require_running` / `box_start` | is the box up; insist it is; bring it up |
| `box_wait_ready [tries]` | wait for the entrypoint to finish seeding |
| `box_compose <args...>` | docker compose against both files |
| `box_path <host>` / `host_path <box>` | translate between the two sides; fail if outside the workspace |
| `box_workdir [host dir]` | the counterpart of the cwd, or the tree root if outside it |
| `plugin_state` | create and print the scratch directory |
| `plugin_say` / `plugin_die` | stderr, prefixed with `claudebox: <plugin>:<command>:` |
