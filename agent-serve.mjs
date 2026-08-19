// The box's side of the inbound agent door (baked in as
// /usr/local/lib/claudebox/agent-serve.mjs, started by entrypoint.sh).
//
// One route, POST /run {project, args}: run `claude` in a project of this
// workspace and stream what it says back. It is what lets a machine that hosts
// a runner send a one-off headless prompt here instead of running an agent on
// itself -- see the runner-machine half in `claudebox`.
//
// WHY THIS IS A SEPARATE LISTENER AND NOT A PORT ON THE RELAY
//
// agent-relay terminates TLS and checks the token, and is the only thing here
// with a LAN-facing socket. This binds on the internal network only, so the box
// still has no listener anything on the LAN can reach and still opens no
// connection to it -- the same division as runner-relay, which exists so that
// the box holds no address, no token and no route.
//
// It follows that THIS process trusts its caller completely: anything that can
// reach it can run the agent here with any flags it likes. That is the
// operation being granted, and the check that gates it lives in agent-relay.
// What is enforced here is narrower and worth having anyway: the request names
// a project, and a project is a directory inside this workspace or the request
// is refused.
//
// Only started when CLAUDEBOX_AGENT_SERVE is set, so a claudebox that does not
// use this grows no listener at all.

import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { spawn } from 'node:child_process';

const WORKSPACE = path.resolve(process.env.CLAUDEBOX_WORKSPACE || '/home/dizzy/Projects');
const PORT = Number(process.env.CLAUDEBOX_AGENT_PORT || 7995);
const MAX_JSON = 1024 * 1024;

// Framing, byte-for-byte the same as runner.mjs's and ddev-relay's:
// [1 byte channel][4 byte BE length][payload]; 1 stdout, 2 stderr, 3 meta JSON.
// The client on the other machine already knows how to read it.
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

// A project is a directory under the workspace, named by its path relative to
// the root. Anything that resolves outside -- "..", an absolute path -- is
// refused rather than clamped. The same rule, and the same wording, as
// runner.mjs's projectDir: this is the other end of the same idea.
function projectDir(project) {
	if (typeof project !== 'string' || project === '' || project.length > 4096) {
		throw new Error('missing project');
	}
	if (path.isAbsolute(project)) throw new Error(`project '${project}' must be relative`);
	const dir = path.resolve(WORKSPACE, project);
	if (dir !== WORKSPACE && !dir.startsWith(WORKSPACE + path.sep)) {
		throw new Error(`project '${project}' is outside the workspace`);
	}
	if (dir === WORKSPACE) throw new Error('project must name a directory inside the workspace');
	// The whole contract with the sending machine: the tree is expected to be
	// here already. Saying which path was looked for is the difference between
	// "sync it" and a puzzle -- the two machines need not agree on where the
	// workspace lives, so the sender cannot print this itself.
	if (!fs.existsSync(dir)) {
		throw new Error(
			`project '${project}' is not on this machine (looked in ${WORKSPACE}). ` +
				'Check it out there, or name another with --project.'
		);
	}
	return dir;
}

// The argument list, forwarded as an argv array and never as a shell string --
// it came off the network, and the one thing that must not happen is a prompt
// being re-parsed by a shell here.
function checkArgs(args) {
	if (!Array.isArray(args) || args.length === 0) throw new Error('no arguments');
	if (args.length > 256) throw new Error('too many arguments');
	for (const a of args) {
		if (typeof a !== 'string') throw new Error('arguments must be strings');
		if (a.length > 1_000_000) throw new Error('argument too long');
	}
	// The sending side only forwards headless runs, and a run that waits for a
	// terminal here would hang until the caller gave up. Refuse rather than
	// hang, and say which flag was expected.
	if (!args.includes('-p') && !args.includes('--print')) {
		throw new Error('only headless runs (-p/--print) can be sent here');
	}
	return args;
}

function runAgent(res, { project, args }) {
	const cwd = projectDir(project);
	const argv = checkArgs(args);

	res.writeHead(200, {
		'content-type': 'application/octet-stream',
		'x-claudebox-agent': '1',
	});

	// CLAUDEBOX_AGENT_RUN marks the session as one that arrived over the wire,
	// for anything here that wants to tell the difference. stdin is /dev/null:
	// there is no terminal on this end and a prompt that waited for one would
	// never be answered.
	const child = spawn('claude', argv, {
		cwd,
		env: { ...process.env, CLAUDEBOX_AGENT_RUN: '1' },
		stdio: ['ignore', 'pipe', 'pipe'],
	});

	child.stdout.on('data', (b) => res.write(frame(1, b)));
	child.stderr.on('data', (b) => res.write(frame(2, b)));

	let finished = false;
	const finish = (exit) => {
		if (finished) return;
		finished = true;
		res.write(frame(3, Buffer.from(JSON.stringify({ exit }))));
		res.end();
	};
	child.on('close', (code, signal) => finish(code == null ? (signal ? 128 : 1) : code));
	child.on('error', (e) => {
		res.write(frame(2, Buffer.from(`claudebox-agent: could not start claude: ${e.message}\n`)));
		finish(1);
	});
	// The caller hanging up is the only stop signal there is from over there,
	// so it has to actually stop the agent -- otherwise a cancelled run keeps
	// working, and paying, in a container nobody is watching.
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

function readJson(req) {
	return new Promise((resolve, reject) => {
		const chunks = [];
		let len = 0;
		req.on('data', (d) => {
			len += d.length;
			if (len > MAX_JSON) {
				req.destroy();
				reject(new Error('request too large'));
				return;
			}
			chunks.push(d);
		});
		req.on('error', reject);
		req.on('end', () => {
			try {
				resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
			} catch (e) {
				reject(new Error(`invalid request body: ${e.message}`));
			}
		});
	});
}

const server = http.createServer(async (req, res) => {
	const url = new URL(req.url, 'http://agent');
	try {
		if (req.method === 'GET' && url.pathname === '/health') {
			res.writeHead(200, { 'content-type': 'application/json' });
			return res.end(JSON.stringify({ ok: true, workspace: WORKSPACE }));
		}
		if (req.method === 'POST' && url.pathname === '/run') {
			return runAgent(res, await readJson(req));
		}
		return fail(res, 404, 'claudebox-agent: not found');
	} catch (e) {
		if (res.headersSent) {
			try {
				res.end();
			} catch {
				/* already gone */
			}
			return;
		}
		return fail(res, 400, `claudebox-agent: ${e.message}`);
	}
});

// The internal network only. Binding 0.0.0.0 inside a container on an
// internal:true network amounts to the same thing today, but this is the line
// that would have to be edited to make the box LAN-reachable, and it should be
// a decision rather than an accident.
server.listen(PORT, '0.0.0.0', () => {
	console.error(`claudebox-agent listening on :${PORT}; workspace=${WORKSPACE}`);
});
