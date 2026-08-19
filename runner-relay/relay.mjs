// claudebox runner relay.
//
// The box has no LAN access and no credential -- claudebox_inner is
// internal: true, so there is no default route off it at all. This process is
// what stands between that and a runner on another machine, in exactly the way
// ddev-relay stands between the box and the host Docker socket: it is on both
// networks, it holds the secrets, and it exposes one constrained thing.
//
// What it holds:      the runner's address, its token, its certificate fingerprint
// What it exposes:    five routes, forwarded verbatim, to that one runner
// What the box gets:  no token, no address, no route to anything else on the LAN
//
// So compromising the box does not yield the runner's credential or the ability
// to reach anything else on the network; it yields the ability to run commands
// on the runner, which is the operation being granted on purpose.
//
// Identity is the PINNED FINGERPRINT and nothing else. The certificate is
// self-signed (see runner/entrypoint.sh for why there is no CA), so the pin is
// done in two steps, and the order matters: a bare TLS handshake that carries
// no request is used to LEARN the certificate and check its fingerprint, and
// only a certificate that matched is then installed as the sole trust anchor
// for the requests that carry the token. There is no window in which anything
// is sent to a server whose key has not already been verified, and no reliance
// on when 'secureConnect' fires relative to the first write.

import http from 'node:http';
import https from 'node:https';
import tls from 'node:tls';

const PORT = Number(process.env.CLAUDEBOX_RUNNER_RELAY_PORT || 7997);
const TARGET = (process.env.CLAUDEBOX_RUNNER || '').trim();
const TOKEN = (process.env.CLAUDEBOX_RUNNER_TOKEN || '').trim();
const FINGERPRINT = (process.env.CLAUDEBOX_RUNNER_FINGERPRINT || '').trim().toUpperCase();

// Only these. A relay that forwarded any path would be a general HTTP proxy
// onto the LAN, which is the one thing this must not become.
const ROUTES = new Set([
	'GET /health',
	'POST /sync/plan',
	'POST /sync/delete',
	'POST /sync/upload',
	'POST /exec',
]);

function parseTarget(t) {
	if (!t) return null;
	const m = /^([A-Za-z0-9._-]+|\[[0-9A-Fa-f:]+\]):(\d{1,5})$/.exec(t);
	if (!m) return null;
	return { host: m[1].replace(/^\[|\]$/g, ''), port: Number(m[2]) };
}
const target = parseTarget(TARGET);

function fail(res, code, msg) {
	if (res.headersSent) return res.end();
	res.writeHead(code, { 'content-type': 'text/plain' });
	res.end(msg.endsWith('\n') ? msg : msg + '\n');
}

// The learn-and-check step. Opens a TLS connection that sends nothing, compares
// the certificate's fingerprint against the pinned one, and returns the
// certificate itself in PEM. Cached: the runner's certificate is generated once
// and lives in a volume, so this is one extra handshake per relay start, not
// per request.
let pinnedPem = null;
function pinnedCertificate() {
	if (pinnedPem) return Promise.resolve(pinnedPem);
	return new Promise((resolve, reject) => {
		const socket = tls.connect(
			{ host: target.host, port: target.port, rejectUnauthorized: false },
			() => {
				const cert = socket.getPeerCertificate();
				const got = (cert && cert.fingerprint256 ? cert.fingerprint256 : '').toUpperCase();
				socket.destroy();
				if (!got || got !== FINGERPRINT) {
					reject(
						new Error(
							`certificate fingerprint mismatch talking to ${TARGET}\n` +
								`  expected ${FINGERPRINT}\n` +
								`  got      ${got || '(none)'}\n` +
								`A rebuilt runner has a new certificate and has to be re-joined:\n` +
								`  claudebox runner add <host:port> <token> <fingerprint>`
						)
					);
					return;
				}
				pinnedPem =
					'-----BEGIN CERTIFICATE-----\n' +
					cert.raw.toString('base64').replace(/(.{64})/g, '$1\n').replace(/\n$/, '') +
					'\n-----END CERTIFICATE-----\n';
				resolve(pinnedPem);
			}
		);
		socket.setNoDelay(true);
		socket.once('error', reject);
	});
}

const server = http.createServer(async (req, res) => {
	const url = new URL(req.url, 'http://relay');
	const route = `${req.method} ${url.pathname}`;

	if (route === 'GET /relay-health') {
		return fail(res, target && TOKEN && FINGERPRINT ? 200 : 503, 'ok');
	}
	if (!ROUTES.has(route)) {
		return fail(res, 404, `claudebox runner relay: ${route} is not forwarded`);
	}
	if (!target || !TOKEN || !FINGERPRINT) {
		return fail(
			res,
			503,
			'claudebox runner relay: no runner is configured on this machine.\n' +
				'Start claudebox-runner on the other machine and run the join line it prints:\n' +
				'  claudebox runner add <host:port> <token> <fingerprint>\n'
		);
	}

	let ca;
	try {
		ca = await pinnedCertificate();
	} catch (e) {
		return fail(res, 502, `claudebox runner relay: ${e.message}`);
	}

	// Headers are rebuilt rather than forwarded: the box's request should not be
	// able to set anything upstream sees except the body and these few, and the
	// token is added here, never passed through.
	const headers = { 'x-claudebox-runner-token': TOKEN };
	for (const h of ['content-type', 'content-length', 'content-encoding']) {
		if (req.headers[h] !== undefined) headers[h] = req.headers[h];
	}

	const upstream = https.request({
		host: target.host,
		port: target.port,
		path: url.pathname + url.search,
		method: req.method,
		headers,
		agent: false,
		// The verified certificate is the ONLY trust anchor for this request, so
		// a substituted server fails the handshake before the token is sent.
		ca,
		// The pin is the identity. There is no name on a home LAN worth
		// checking -- the certificate names "claudebox-runner", and the address
		// it is reached at is whatever the join line said.
		checkServerIdentity: () => undefined,
	});

	upstream.on('response', (up) => {
		res.writeHead(up.statusCode, {
			'content-type': up.headers['content-type'] || 'application/octet-stream',
		});
		up.pipe(res);
	});
	upstream.on('error', (e) => {
		// A certificate error against the cached anchor means the runner was
		// re-issued one. Drop the cache so the next request re-learns it and
		// reports a fingerprint mismatch, which says what to do about it.
		if (e.code && String(e.code).startsWith('ERR_TLS')) pinnedPem = null;
		if (e.code === 'CERT_HAS_EXPIRED' || e.code === 'SELF_SIGNED_CERT_IN_CHAIN') pinnedPem = null;
		if (!res.headersSent) fail(res, 502, `claudebox runner relay: ${e.message}`);
		else res.end();
	});

	// A hang-up on either side tears down the other, so an interrupted test run
	// does not leave a command running on the runner with nowhere to report to.
	res.on('close', () => upstream.destroy());
	req.on('aborted', () => upstream.destroy());

	req.pipe(upstream);
});

server.listen(PORT, () => {
	console.error(
		target
			? `claudebox runner-relay listening on :${PORT}; runner=${TARGET}`
			: `claudebox runner-relay listening on :${PORT}; no runner configured`
	);
});
