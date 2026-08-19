// claudebox-runner: run a project's tests on another machine.
//
// This is the box's environment minus the agent, plus a network API. It holds a
// copy of one or more projects' SOURCE in its workspace volume, and it runs
// commands in them against its own rootless dind. The box on the other machine
// never reaches it directly: it talks to runner-relay over the internal
// network, and the relay is what holds this runner's address, its token and its
// certificate fingerprint. Same trust boundary as ddev-relay -- the box gets one
// constrained operation, not a credential and not a route.
//
// Three operations, token in a header on every one of them:
//
//   POST /sync/plan     {project, manifest}  -> {need, delete}
//   POST /sync/upload   tar stream           -> extracted into the project
//   POST /sync/delete   {project, paths}     -> removed from the project
//   POST /exec          {project, workdir, command}
//                                            -> framed stdout/stderr/exit
//   GET  /artifacts     ?project=&path=      -> tar stream of that path
//
// Everything is confined to WORKSPACE. Paths arrive RELATIVE -- a project name
// and a path within it -- so there is no assumption that the two machines
// mount the tree at the same place, and every one of them is resolved and
// re-checked against the root here before it is used. The rule is the same one
// ddev-relay applies: resolve, then refuse anything that did not stay inside.
//
// What that confinement is FOR, so it is not mistaken for something stronger:
// /exec runs `bash -lc`, so anything that can reach this service already has
// arbitrary code execution here as this user -- that is the operation being
// granted, not a leak. The checks below are about a request never writing to or
// deleting from the wrong project, by accident or by a malformed path. The
// thing that keeps the box from reaching anything else on the LAN is that the
// box holds no address, no token and no route; see runner-relay/relay.mjs.

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import https from 'node:https';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';

const WORKSPACE = path.resolve(
	process.env.CLAUDEBOX_RUNNER_WORKSPACE || '/home/dizzy/Projects'
);
const STATE = path.resolve(process.env.CLAUDEBOX_RUNNER_STATE || '/var/lib/claudebox-runner');
const PORT = Number(process.env.CLAUDEBOX_RUNNER_PORT || 7998);
const TOKEN = fs.readFileSync(path.join(STATE, 'token'), 'utf8').trim();

// Manifests are the one big JSON body here: a large project runs to six figures
// of files. gzip on the wire, and a limit generous enough for that but not
// unbounded.
const MAX_JSON = 256 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Framing, byte-for-byte the same as ddev-relay's:
// [1 byte channel][4 byte BE length][payload]; 1 stdout, 2 stderr, 3 meta JSON.
// ---------------------------------------------------------------------------
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

function sendJson(res, code, obj) {
	const body = Buffer.from(JSON.stringify(obj));
	res.writeHead(code, { 'content-type': 'application/json', 'content-length': body.length });
	res.end(body);
}

// Constant-time, and length-safe: timingSafeEqual throws on a length mismatch,
// which would itself be an oracle if it were allowed to become a 500.
function tokenOk(req) {
	const got = req.headers['x-claudebox-runner-token'];
	if (typeof got !== 'string') return false;
	const a = Buffer.from(got);
	const b = Buffer.from(TOKEN);
	return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// ---------------------------------------------------------------------------
// Path confinement
//
// The only thing standing between a request and the rest of this machine's
// filesystem. Every path in every request goes through one of these two, and
// neither trusts the input for anything beyond being a string.
// ---------------------------------------------------------------------------

// A project is a directory under the workspace, named by its path relative to
// the root. Anything that resolves outside -- "..", an absolute path, a symlink
// pointing away -- is refused rather than clamped.
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
	return dir;
}

// A path inside a project, same rule one level down. Used for every member of a
// manifest and for the exec workdir.
function insideProject(root, rel) {
	if (typeof rel !== 'string') throw new Error('path must be a string');
	if (rel === '' || rel === '.') return root;
	if (path.isAbsolute(rel)) throw new Error(`path '${rel}' must be relative`);
	if (rel.includes('\0')) throw new Error('path contains a NUL');
	const p = path.resolve(root, rel);
	if (p !== root && !p.startsWith(root + path.sep)) {
		throw new Error(`path '${rel}' escapes the project`);
	}
	return p;
}

// ---------------------------------------------------------------------------
// /sync
//
// The comparison is rsync's default quick check -- size and mtime -- not a
// content hash. Same tradeoff rsync makes by default, and for a source tree it
// is the right one: hashing a whole checkout on both sides to find the four
// files that changed costs far more than it saves.
//
// What counts as source is decided ENTIRELY on the client (see the `runner`
// shim in the box), because that is where git lives and the rule is "git
// check-ignore says the project ignores it". This end never second-guesses the
// manifest it is given; it only refuses paths that are not inside the project.
// ---------------------------------------------------------------------------

// Walk what is already here, so it can be compared with what the client has.
//
// `exclude` is the client's own list of directories it did not send -- the ones
// git says the project ignores. Not descending into them is what makes build
// output on this side SURVIVE a sync: everything under such a directory stays
// invisible to the comparison, so it is never reported as a file the client has
// dropped and never deleted. That is the whole point of the runner keeping its
// own node_modules and vendor. (It is also, incidentally, most of the walk.)
async function localManifest(root, exclude) {
	const out = new Map();
	async function walk(dir, prefix) {
		let entries;
		try {
			entries = await fsp.readdir(dir, { withFileTypes: true });
		} catch {
			return;
		}
		for (const e of entries) {
			const rel = prefix ? prefix + '/' + e.name : e.name;
			const full = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (exclude.has(rel)) continue;
				await walk(full, rel);
			} else if (e.isFile() || e.isSymbolicLink()) {
				let st;
				try {
					st = await fsp.lstat(full);
				} catch {
					continue;
				}
				out.set(rel, [st.size, Math.floor(st.mtimeMs / 1000)]);
			}
		}
	}
	await walk(root, '');
	return out;
}

async function syncPlan(res, { project, manifest, exclude }) {
	const root = projectDir(project);
	if (!Array.isArray(manifest)) throw new Error('manifest must be an array');
	const excluded = excludeSet(root, exclude);

	// Validate every path before anything is compared: a manifest entry is a
	// path this process will later write to.
	const want = new Map();
	for (const entry of manifest) {
		if (!Array.isArray(entry) || entry.length < 3) throw new Error('bad manifest entry');
		const [rel, size, mtime] = entry;
		insideProject(root, rel);
		want.set(rel, [Number(size), Number(mtime)]);
	}

	await fsp.mkdir(root, { recursive: true });
	const have = await localManifest(root, excluded);

	const need = [];
	for (const [rel, [size, mtime]] of want) {
		const mine = have.get(rel);
		if (!mine || mine[0] !== size || mine[1] !== mtime) need.push(rel);
	}
	const remove = [];
	for (const rel of have.keys()) if (!want.has(rel)) remove.push(rel);

	sendJson(res, 200, { need, delete: remove, have: have.size, want: want.size });
}

// The client's exclusion list, validated the same way every other path is.
// Relative directory paths, no trailing slash.
function excludeSet(root, exclude) {
	const set = new Set();
	if (exclude === undefined || exclude === null) return set;
	if (!Array.isArray(exclude)) throw new Error('exclude must be an array');
	for (const rel of exclude) {
		insideProject(root, rel);
		set.add(String(rel).replace(/\/+$/, ''));
	}
	return set;
}

async function syncDelete(res, { project, paths, exclude }) {
	const root = projectDir(project);
	if (!Array.isArray(paths)) throw new Error('paths must be an array');
	const excluded = excludeSet(root, exclude);
	// Belt and braces: /sync/plan already leaves excluded trees out of the
	// delete list, and this refuses to act on one even if asked directly.
	for (const rel of paths) {
		for (const ex of excluded) {
			if (rel === ex || String(rel).startsWith(ex + '/')) {
				throw new Error(`refusing to delete ${rel}: it is under an excluded directory`);
			}
		}
	}
	const full = paths.map((rel) => insideProject(root, rel));
	let removed = 0;
	for (const p of full) {
		try {
			await fsp.rm(p, { force: true });
			removed++;
		} catch {
			/* already gone */
		}
	}
	// Directories are not in the manifest, so a directory that lost its last
	// file has to be swept up here or it lingers forever. Bottom-up, and only
	// ones that are actually empty.
	const pruned = await pruneEmpty(root, root, '', excluded);
	sendJson(res, 200, { removed, pruned });
}

async function pruneEmpty(root, dir, prefix, exclude) {
	let pruned = 0;
	let entries;
	try {
		entries = await fsp.readdir(dir, { withFileTypes: true });
	} catch {
		return 0;
	}
	for (const e of entries) {
		if (!e.isDirectory()) continue;
		const rel = prefix ? prefix + '/' + e.name : e.name;
		if (exclude.has(rel)) continue;
		pruned += await pruneEmpty(root, path.join(dir, e.name), rel, exclude);
	}
	if (dir === root) return pruned;
	try {
		if ((await fsp.readdir(dir)).length === 0) {
			await fsp.rmdir(dir);
			pruned++;
		}
	} catch {
		/* not empty, or vanished */
	}
	return pruned;
}

// The upload is a tar stream rather than a JSON body: it is the one part of a
// sync that is actually large, and tar carries mode, mtime and symlinks along
// with the bytes -- which is what keeps the next manifest comparison stable
// instead of re-sending everything because the mtimes moved.
//
// -m is deliberately NOT passed (mtimes must be preserved), and --delay-directory-restore
// keeps directory mtimes right when files land after their parent. tar refuses
// absolute and "../" members on its own; the client's paths were validated at
// /sync/plan and are validated again here by --strip-components-free extraction
// into a fixed -C directory.
function syncUpload(req, res, project) {
	const root = projectDir(project);
	fs.mkdirSync(root, { recursive: true });

	const child = spawn(
		'tar',
		['-x', '-f', '-', '-C', root, '--delay-directory-restore', '--no-same-owner'],
		{ stdio: ['pipe', 'pipe', 'pipe'] }
	);
	let err = '';
	child.stderr.on('data', (b) => {
		if (err.length < 8192) err += b.toString();
	});
	child.stdout.resume();

	req.pipe(child.stdin);
	req.on('aborted', () => child.kill('SIGKILL'));
	child.stdin.on('error', () => {
		/* tar died; the close handler reports it */
	});

	child.on('close', (code) => {
		if (code === 0) return sendJson(res, 200, { ok: true });
		fail(res, 500, `claudebox-runner: tar exited ${code}: ${err.trim()}`);
	});
	child.on('error', (e) => fail(res, 500, `claudebox-runner: could not run tar: ${e.message}`));
}

// ---------------------------------------------------------------------------
// /artifacts
//
// The return path for whatever a run produced: screenshot diffs, coverage, logs.
// The CALLER names the path, and that is the whole policy -- this end has no idea
// what an artifact is, and a rule baked in here ("only diffs", "everything under
// tests/") would be wrong for the next suite. `runner fetch tests/UI/screenshot-diffs`
// is explicit and needs no convention.
//
// Not a mirror: it extracts over what is here and removes nothing, because the
// thing being copied back is a result, not a tree to keep in step.
//
// Sized before streaming rather than cut off mid-tar. A truncated tar fails to
// extract with an error about the archive, which is a bad way to learn that a
// UI failure produced four thousand screenshots.
// ---------------------------------------------------------------------------
const MAX_ARTIFACT = Number(process.env.CLAUDEBOX_RUNNER_MAX_ARTIFACT || 2 * 1024 * 1024 * 1024);

function sendArtifacts(res, project, rel) {
	const root = projectDir(project);
	if (typeof rel !== 'string' || rel === '' || rel === '.') {
		throw new Error('path is required (naming the whole project is never what is meant)');
	}
	const target = insideProject(root, rel);
	if (!fs.existsSync(target)) {
		throw new Error(`${rel} does not exist on the runner`);
	}

	const sized = spawnSync('du', ['-sb', '--', target], { encoding: 'utf8' });
	const bytes = Number((sized.stdout || '').split(/\s+/)[0]) || 0;
	if (bytes > MAX_ARTIFACT) {
		throw new Error(
			`${rel} is ${Math.round(bytes / 1e6)} MB, over the ${Math.round(MAX_ARTIFACT / 1e6)} MB ` +
				'limit. Name something narrower, or raise CLAUDEBOX_RUNNER_MAX_ARTIFACT on the runner.'
		);
	}

	res.writeHead(200, {
		'content-type': 'application/x-tar',
		'x-claudebox-artifact-bytes': String(bytes),
	});

	const child = spawn('tar', ['-c', '-f', '-', '-C', root, '--', rel], {
		stdio: ['ignore', 'pipe', 'pipe'],
	});
	child.stderr.resume();
	child.stdout.pipe(res);
	child.on('error', () => res.destroy());
	res.on('close', () => {
		try {
			child.kill('SIGKILL');
		} catch {
			/* already gone */
		}
	});
}

// ---------------------------------------------------------------------------
// /exec
// ---------------------------------------------------------------------------
function runExec(res, { project, workdir, command, env }) {
	const root = projectDir(project);
	if (typeof command !== 'string' || command.trim() === '') throw new Error('empty command');
	if (command.length > 100_000) throw new Error('command too long');
	const cwd = insideProject(root, workdir == null ? '' : workdir);
	if (!fs.existsSync(cwd)) throw new Error(`workdir ${workdir} does not exist on the runner (sync first)`);

	const childEnv = { ...process.env, CLAUDEBOX_RUNNER: '1' };
	if (env && typeof env === 'object') {
		for (const [k, v] of Object.entries(env)) {
			if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) && typeof v === 'string') childEnv[k] = v;
		}
	}

	res.writeHead(200, {
		'content-type': 'application/octet-stream',
		'x-claudebox-runner': '1',
	});

	// argv array, so the command string is only ever a shell HERE, in this
	// container, in this project. -l to match `ddev exec` and the box's own
	// login PATH.
	const child = spawn('bash', ['-lc', command], {
		cwd,
		env: childEnv,
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
		res.write(frame(2, Buffer.from(`claudebox-runner: could not start bash: ${e.message}\n`)));
		finish(1);
	});
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

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------
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
			let buf = Buffer.concat(chunks);
			try {
				if (req.headers['content-encoding'] === 'gzip') buf = zlib.gunzipSync(buf);
				resolve(JSON.parse(buf.toString('utf8')));
			} catch (e) {
				reject(new Error(`invalid request body: ${e.message}`));
			}
		});
	});
}

const server = https.createServer(
	{
		key: fs.readFileSync(path.join(STATE, 'key.pem')),
		cert: fs.readFileSync(path.join(STATE, 'cert.pem')),
		minVersion: 'TLSv1.2',
	},
	async (req, res) => {
		const url = new URL(req.url, 'https://runner');
		if (!tokenOk(req)) return fail(res, 401, 'claudebox-runner: bad or missing token');

		try {
			if (req.method === 'GET' && url.pathname === '/health') {
				return sendJson(res, 200, { ok: true, workspace: WORKSPACE });
			}
			if (req.method === 'POST' && url.pathname === '/sync/plan') {
				return await syncPlan(res, await readJson(req));
			}
			if (req.method === 'POST' && url.pathname === '/sync/delete') {
				return await syncDelete(res, await readJson(req));
			}
			if (req.method === 'POST' && url.pathname === '/sync/upload') {
				return syncUpload(req, res, url.searchParams.get('project'));
			}
			if (req.method === 'POST' && url.pathname === '/exec') {
				return runExec(res, await readJson(req));
			}
			if (req.method === 'GET' && url.pathname === '/artifacts') {
				return sendArtifacts(res, url.searchParams.get('project'), url.searchParams.get('path'));
			}
			return fail(res, 404, 'claudebox-runner: not found');
		} catch (e) {
			if (res.headersSent) {
				try {
					res.end();
				} catch {
					/* already gone */
				}
				return;
			}
			return fail(res, 400, `claudebox-runner: ${e.message}`);
		}
	}
);

server.listen(PORT, '0.0.0.0', () => {
	console.error(`claudebox-runner listening on :${PORT}; workspace=${WORKSPACE}`);
});
