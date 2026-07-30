// claudebox ddev-exec relay.
//
// This process is the trust boundary that lets the isolated box run `ddev exec`
// without ever giving it the host Docker daemon. It holds the host docker
// socket; the box cannot reach that socket. All the box can do is POST a
// constrained {workdir, service, command} request to /exec on the internal
// network, and this code translates that into exactly one operation:
//
//     docker exec -w <mapped-dir> ddev-<project>-<service> bash -lc <command>
//
// for a <project> whose `.ddev/config.yaml` lives under the workspace and whose
// container carries that project's own DDEV label. Nothing else is reachable:
// no `docker run`, no host bind mounts, no exec into ddev-router / another
// project's containers, no host shell (docker is spawned with an argv array, so
// the command string is only ever a shell inside the web container -- which the
// box's own source tree already drives).
//
// Faithfulness: `ddev exec -s web '<cmd>'` is `docker exec -w /var/www/html
// ddev-<project>-web bash -lc '<cmd>'` (DDEV mounts the project root at
// /var/www/html). This relay reproduces that, mapping subdirectories through.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';

const WORKSPACE = path.resolve(
	process.env.CLAUDEBOX_WORKSPACE || '/home/dizzy/Projects'
);
const PORT = Number(process.env.CLAUDEBOX_RELAY_PORT || 7999);
const CONTAINER_ROOT = '/var/www/html'; // where DDEV mounts the project

// Response framing: [1 byte channel][4 byte BE length][payload].
// channel 1 = stdout, 2 = stderr, 3 = meta JSON ({exit} or {error}).
function frame(channel, buf) {
	const head = Buffer.allocUnsafe(5);
	head[0] = channel;
	head.writeUInt32BE(buf.length, 1);
	return Buffer.concat([head, buf]);
}

function fail(res, code, msg) {
	res.writeHead(code, { 'content-type': 'text/plain' });
	res.end(msg.endsWith('\n') ? msg : msg + '\n');
}

// Resolve and validate a request into a concrete, safe exec target. Throws a
// plain Error (its message is shown to the box) on any refusal.
function resolveTarget({ workdir, service, command }) {
	if (typeof command !== 'string' || command.trim() === '') {
		throw new Error('empty command');
	}
	if (command.length > 100_000) throw new Error('command too long');

	const svc = service === undefined || service === null ? 'web' : service;
	if (typeof svc !== 'string' || !/^[a-z0-9]+$/.test(svc)) {
		throw new Error(`invalid service '${svc}'`);
	}

	if (typeof workdir !== 'string' || workdir === '') {
		throw new Error('missing workdir');
	}
	const wd = path.resolve(workdir);
	if (wd !== WORKSPACE && !wd.startsWith(WORKSPACE + path.sep)) {
		throw new Error(`workdir ${wd} is outside the workspace`);
	}

	// Climb to the nearest ancestor holding .ddev/config.yaml, staying inside
	// the workspace the whole way.
	let dir = wd;
	let root = null;
	for (;;) {
		if (fs.existsSync(path.join(dir, '.ddev', 'config.yaml'))) {
			root = dir;
			break;
		}
		if (dir === WORKSPACE) break;
		const parent = path.dirname(dir);
		if (parent === dir) break;
		dir = parent;
		if (dir !== WORKSPACE && !dir.startsWith(WORKSPACE + path.sep)) break;
	}
	if (!root) {
		throw new Error(`no .ddev/config.yaml at or above ${wd}`);
	}

	const cfg = fs.readFileSync(path.join(root, '.ddev', 'config.yaml'), 'utf8');
	const m = cfg.match(
		/^\s*name:\s*["']?([A-Za-z0-9][A-Za-z0-9_-]*)["']?\s*$/m
	);
	if (!m) throw new Error(`could not read project name from ${root}/.ddev/config.yaml`);
	const name = m[1].toLowerCase();
	if (!/^[a-z0-9][a-z0-9-]*$/.test(name)) {
		throw new Error(`invalid project name '${name}'`);
	}

	const container = `ddev-${name}-${svc}`;

	// Bind the container to THIS project: it must exist, be running, and carry
	// the project's own DDEV label. This is what stops the box coercing us into
	// any other container even if it could influence the derived name.
	const insp = spawnSync(
		'docker',
		[
			'inspect',
			'--format',
			'{{index .Config.Labels "com.ddev.site-name"}}|{{.State.Running}}',
			container,
		],
		{ encoding: 'utf8' }
	);
	if (insp.status !== 0) {
		throw new Error(
			`container ${container} not found -- is the DDEV project '${name}' running?`
		);
	}
	const [label, running] = insp.stdout.trim().split('|');
	if (label !== name) {
		throw new Error(
			`refusing ${container}: not a DDEV container for project '${name}'`
		);
	}
	if (running !== 'true') {
		throw new Error(`container ${container} is not running`);
	}

	// Map the box's working directory into the container.
	const rel = path.relative(root, wd).split(path.sep).join('/');
	const containerWorkdir =
		rel === '' ? CONTAINER_ROOT : path.posix.join(CONTAINER_ROOT, rel);
	if (
		containerWorkdir !== CONTAINER_ROOT &&
		!containerWorkdir.startsWith(CONTAINER_ROOT + '/')
	) {
		throw new Error('bad workdir mapping');
	}

	return { name, container, containerWorkdir, command };
}

function runExec(res, target) {
	res.writeHead(200, {
		'content-type': 'application/octet-stream',
		'x-claudebox-relay': '1',
	});

	// argv array: the command string is a single argument, so it is only ever a
	// shell INSIDE the web container. -l so PATH matches `ddev exec` (node/nvm,
	// composer, etc.).
	const child = spawn(
		'docker',
		['exec', '-w', target.containerWorkdir, target.container, 'bash', '-lc', target.command],
		{ stdio: ['ignore', 'pipe', 'pipe'] }
	);

	child.stdout.on('data', (b) => res.write(frame(1, b)));
	child.stderr.on('data', (b) => res.write(frame(2, b)));

	let finished = false;
	const finish = (exit) => {
		if (finished) return;
		finished = true;
		res.write(frame(3, Buffer.from(JSON.stringify({ exit }))));
		res.end();
	};
	child.on('close', (code, signal) =>
		finish(code == null ? (signal ? 128 : 1) : code)
	);
	child.on('error', (e) => {
		res.write(frame(2, Buffer.from(`relay: could not start docker exec: ${e.message}\n`)));
		finish(1);
	});

	// If the box hangs up, don't leave the exec running.
	res.on('close', () => {
		if (!finished) {
			try {
				child.kill('SIGKILL');
			} catch {
				/* already gone */
			}
		}
	});
}

const server = http.createServer((req, res) => {
	if (req.method === 'GET' && req.url === '/health') {
		res.writeHead(200, { 'content-type': 'text/plain' });
		res.end('ok\n');
		return;
	}
	if (req.method !== 'POST' || req.url !== '/exec') {
		return fail(res, 404, 'not found');
	}

	let body = '';
	req.setEncoding('utf8');
	req.on('data', (d) => {
		body += d;
		if (body.length > 200_000) req.destroy();
	});
	req.on('end', () => {
		let parsed;
		try {
			parsed = JSON.parse(body);
		} catch {
			return fail(res, 400, 'claudebox ddev relay: invalid JSON request');
		}
		let target;
		try {
			target = resolveTarget(parsed);
		} catch (e) {
			return fail(res, 400, `claudebox ddev relay: ${e.message}`);
		}
		runExec(res, target);
	});
});

server.listen(PORT, () => {
	console.error(
		`claudebox ddev-relay listening on :${PORT}; workspace=${WORKSPACE}`
	);
});
