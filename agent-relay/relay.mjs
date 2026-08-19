// claudebox agent front door.
//
// What it is:         the only LAN-facing socket on this machine
// What it holds:      this machine's own identity -- a token and a certificate
// What it exposes:    one route, /run, forwarded to the box over the internal
//                     network
//
// THE MIRROR OF runner-relay
//
// runner-relay is OUTBOUND: it holds a credential for a machine somewhere else
// and lets the box reach exactly that one machine. This is INBOUND: it holds an
// identity that another machine pins, and lets that machine reach exactly one
// route in the box. Same shape, opposite direction, and the same reason for
// being a separate container either way -- the box gets no LAN socket, in or
// out.
//
// It exists so that a machine hosting a runner does not have to run an agent to
// get a one-off prompt answered. The runner machine is the box minus the agent
// and has no egress sandbox; running claude there would put an agent on the one
// machine deliberately built not to have one.
//
// WHAT PRESENTING THE TOKEN GETS YOU
//
// A `claude` process in this box, in a project of this workspace, with whatever
// flags were sent. That is the operation being granted, not a leak -- the same
// bargain runner.mjs's /exec makes in the other direction. It is bounded by the
// box being the box: same allowlist, same proxy, same workspace, same HOME. It
// is NOT bounded by the flags, so the token is a real credential and lives in
// ~/.claudebox/config on the other machine, 0600.

import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import crypto from 'node:crypto';

const STATE = path.resolve(process.env.CLAUDEBOX_AGENT_STATE || '/var/lib/claudebox-agent');
const PORT = Number(process.env.CLAUDEBOX_AGENT_RELAY_PORT || 7996);
// The box, by service name on the internal network. Not configurable to an
// arbitrary address on purpose: this forwards an authenticated request into one
// container, and a general destination-taking forwarder is a different and much
// larger thing to have on a LAN-facing port.
const BOX_HOST = process.env.CLAUDEBOX_AGENT_BOX_HOST || 'claude';
const BOX_PORT = Number(process.env.CLAUDEBOX_AGENT_BOX_PORT || 7995);
const TOKEN = fs.readFileSync(path.join(STATE, 'token'), 'utf8').trim();
const MAX_JSON = 1024 * 1024;

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
	const got = req.headers['x-claudebox-agent-token'];
	if (typeof got !== 'string') return false;
	const a = Buffer.from(got);
	const b = Buffer.from(TOKEN);
	return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// ---------------------------------------------------------------------------
// /enrol
//
// The bootstrap, and the only route that answers without the token -- it is
// where the token comes from. Identical in every respect to the runner's, down
// to burning the window after ten wrong guesses; see agent-relay/entrypoint.sh
// for what the code protects and what it does not.
//
// State is read from disk per request rather than cached, so
// `claudebox agent enrol` opening a new window takes effect without a restart.
// ---------------------------------------------------------------------------
const ENROL_CODE = path.join(STATE, 'enrol-code');
const ENROL_EXPIRES = path.join(STATE, 'enrol-expires');
const ENROL_FAILURES = path.join(STATE, 'enrol-failures');
const ENROLLED = path.join(STATE, 'enrolled');
const MAX_ENROL_FAILURES = 10;

function closeEnrolment() {
	for (const f of [ENROL_CODE, ENROL_EXPIRES, ENROL_FAILURES]) {
		try {
			fs.unlinkSync(f);
		} catch {
			/* already gone */
		}
	}
}

function enrol(req, res, { code }) {
	const peer = req.socket.remoteAddress || '?';
	const closed =
		'claudebox-agent: enrolment is closed on this machine.\n' +
		'Open a window on the workstation with:  claudebox agent enrol\n';

	let want;
	try {
		want = fs.readFileSync(ENROL_CODE, 'utf8').trim();
	} catch {
		return fail(res, 403, closed);
	}
	const expires = Number(fs.readFileSync(ENROL_EXPIRES, 'utf8').trim() || 0);
	if (!want || !Number.isFinite(expires) || Date.now() / 1000 > expires) {
		closeEnrolment();
		console.error(`claudebox-agent: enrolment attempt from ${peer} after the window closed`);
		return fail(res, 403, closed);
	}

	const got = typeof code === 'string' ? code.trim() : '';
	const a = Buffer.from(got);
	const b = Buffer.from(want);
	const ok = a.length === b.length && crypto.timingSafeEqual(a, b);

	if (!ok) {
		let failures = 0;
		try {
			failures = Number(fs.readFileSync(ENROL_FAILURES, 'utf8').trim() || 0);
		} catch {
			/* first failure */
		}
		failures += 1;
		if (failures >= MAX_ENROL_FAILURES) {
			closeEnrolment();
			console.error(
				`claudebox-agent: ${failures} bad enrolment codes (last from ${peer}); window closed`
			);
		} else {
			fs.writeFileSync(ENROL_FAILURES, String(failures));
			console.error(`claudebox-agent: bad enrolment code from ${peer} (${failures})`);
		}
		return fail(res, 403, 'claudebox-agent: that enrolment code is not right');
	}

	closeEnrolment();
	try {
		fs.writeFileSync(ENROLLED, new Date().toISOString() + ' ' + peer + '\n');
	} catch {
		/* not fatal */
	}
	console.error(`claudebox-agent: enrolled ${peer}`);
	sendJson(res, 200, { token: TOKEN });
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
				resolve(Buffer.concat(chunks));
			} catch (e) {
				reject(e);
			}
		});
	});
}

// ---------------------------------------------------------------------------
// /run -> the box
//
// The body is passed through as bytes and the headers are REBUILT rather than
// forwarded, the rule runner-relay already follows: the far machine should not
// be able to set anything the box sees except the body it sent.
// ---------------------------------------------------------------------------
function forward(req, res, body) {
	const up = http.request(
		{
			host: BOX_HOST,
			port: BOX_PORT,
			path: '/run',
			method: 'POST',
			headers: { 'content-type': 'application/json', 'content-length': body.length },
		},
		(upRes) => {
			res.writeHead(upRes.statusCode || 502, {
				'content-type': upRes.headers['content-type'] || 'application/octet-stream',
			});
			upRes.pipe(res);
		}
	);
	up.on('error', (e) => {
		if (res.headersSent) return res.end();
		// The one failure worth naming: the box is up but its listener is not,
		// which is what a workstation that never set BOX_AGENT_SERVE looks like
		// from over here.
		fail(
			res,
			502,
			`claudebox-agent: the box did not answer (${e.message}).\n` +
				'Is the box running, and was it started with BOX_AGENT_SERVE=1?'
		);
	});
	// A hang-up on the LAN side has to reach the box, or a cancelled run keeps
	// going in there with nobody reading it.
	res.on('close', () => up.destroy());
	up.end(body);
}

const server = https.createServer(
	{
		key: fs.readFileSync(path.join(STATE, 'key.pem')),
		cert: fs.readFileSync(path.join(STATE, 'cert.pem')),
		minVersion: 'TLSv1.2',
	},
	async (req, res) => {
		const url = new URL(req.url, 'https://agent');

		// Before the token check, because this is the route that issues it.
		if (req.method === 'POST' && url.pathname === '/enrol') {
			try {
				return enrol(req, res, JSON.parse((await readJson(req)).toString('utf8')));
			} catch (e) {
				return fail(res, 400, `claudebox-agent: ${e.message}`);
			}
		}

		if (!tokenOk(req)) return fail(res, 401, 'claudebox-agent: bad or missing token');

		try {
			if (req.method === 'GET' && url.pathname === '/health') {
				return sendJson(res, 200, { ok: true });
			}
			if (req.method === 'POST' && url.pathname === '/run') {
				return forward(req, res, await readJson(req));
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
	}
);

server.listen(PORT, '0.0.0.0', () => {
	console.error(`claudebox-agent front door listening on :${PORT}; box=${BOX_HOST}:${BOX_PORT}`);
});
