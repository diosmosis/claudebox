// Send one headless run to a workstation's agent front door and stream back what
// it said.
//
//   <request on stdin>  node send.mjs
//
// Run as a one-off container from this image, on the RUNNER machine, by the
// `claudebox` launcher when it refuses to run an agent locally. Same reason the
// enrolment client runs this way: this image has node and a route to the other
// machine, and the host may have no node at all.
//
// THE REQUEST COMES IN ON STDIN, NOT ON ARGV, and that is deliberate: it carries
// the token, and every process's arguments are readable by every process on the
// machine -- `docker run -e TOKEN=...` would put it in the docker client's own
// command line. It also carries the prompt, which has no business in a
// scrollback either.
//
// NUL-separated fields, because the sender is a shell script and this way there
// is no JSON encoder in bash between a prompt and the wire:
//
//   mode \0 target \0 token \0 fingerprint \0 project \0 arg \0 arg ...
//
// mode is "run" or "health"; "health" ignores everything after the fingerprint
// and is what `claudebox agent test` uses.
//
// The reply is the shared framing -- [1 byte channel][4 byte BE length][payload],
// 1 stdout, 2 stderr, 3 meta JSON -- so a run's output arrives here as it is
// produced rather than at the end, and this process exits with the status the
// agent exited with.

import https from 'node:https';
import tls from 'node:tls';

function die(msg, code) {
	process.stderr.write(msg.endsWith('\n') ? msg : msg + '\n');
	process.exit(code == null ? 1 : code);
}

function readStdin() {
	return new Promise((resolve, reject) => {
		const chunks = [];
		process.stdin.on('data', (d) => chunks.push(d));
		process.stdin.on('error', reject);
		process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
	});
}

const fields = (await readStdin()).split('\0');
// A trailing NUL from printf leaves an empty last field; drop it rather than
// sending an empty argument the agent would have to make sense of.
if (fields.length && fields[fields.length - 1] === '') fields.pop();
const [mode, target, token, fingerprint, project, ...args] = fields;
const m = /^([A-Za-z0-9._-]+|\[[0-9A-Fa-f:]+\]):(\d{1,5})$/.exec(target || '');
if (!m || !token || !fingerprint || (mode !== 'run' && mode !== 'health')) {
	die('claudebox: incomplete request to the agent front door', 2);
}
if (mode === 'run' && (!project || args.length === 0)) {
	die('claudebox: a run needs a project and arguments', 2);
}
const host = m[1].replace(/^\[|\]$/g, '');
const port = Number(m[2]);

// The pin, in two steps and in this order -- the same dance runner-relay does.
// A bare handshake that carries nothing is used to LEARN the certificate and
// check its fingerprint, and only a certificate that matched is then installed
// as the sole trust anchor for the request that carries the token. Doing it as
// one https.request plus a secureConnect check would leave a window in which the
// token could go to the wrong server.
function pinnedCertificate() {
	return new Promise((resolve, reject) => {
		const socket = tls.connect({ host, port, rejectUnauthorized: false }, () => {
			const cert = socket.getPeerCertificate();
			socket.destroy();
			const got = (cert && cert.fingerprint256 ? cert.fingerprint256 : '').toUpperCase();
			if (!got) return reject(new Error('the workstation presented no certificate'));
			if (got !== String(fingerprint).toUpperCase()) {
				return reject(
					new Error(
						`certificate fingerprint mismatch talking to ${target}\n` +
							`  pinned: ${fingerprint}\n` +
							`  got:    ${got}\n` +
							'A rebuilt front door has a new certificate and must be re-joined:\n' +
							'  claudebox agent add <host:port> <code>'
					)
				);
			}
			resolve(
				'-----BEGIN CERTIFICATE-----\n' +
					cert.raw.toString('base64').replace(/(.{64})/g, '$1\n').replace(/\n$/, '') +
					'\n-----END CERTIFICATE-----\n'
			);
		});
		socket.setNoDelay(true);
		socket.once('error', reject);
	});
}

const ca = await pinnedCertificate().catch((e) =>
	die(
		`claudebox: ${e.message}\n` +
			`Is the box running on ${host} with BOX_AGENT_SERVE=1?`
	)
);

// "Is it there, does it know me" -- the pin has already been checked by the time
// either of these runs, so reaching the server at all means the address and the
// certificate still line up; the status says whether the token does too.
function healthCheck() {
	const probe = https.request(
		{
			host,
			port,
			path: '/health',
			method: 'GET',
			agent: false,
			ca,
			checkServerIdentity: () => undefined,
			headers: { 'x-claudebox-agent-token': token },
		},
		(res) => {
			let text = '';
			res.setEncoding('utf8');
			res.on('data', (d) => (text += d));
			res.on('end', () => {
				if (res.statusCode !== 200) {
					die(text.trim() || `claudebox: the workstation refused (${res.statusCode})`);
				}
				process.stdout.write(`the front door at ${target} answers, and the pin matches\n`);
			});
		}
	);
	probe.on('error', (e) => die(`claudebox: ${e.message}`));
	probe.end();
}

function runRemote() {
	const body = Buffer.from(JSON.stringify({ project, args }));
	const req = https.request({
		host,
		port,
		path: '/run',
		method: 'POST',
		agent: false,
		ca,
		// The pin is the identity. There is no name on a home LAN worth
		// verifying that an attacker could not also claim.
		checkServerIdentity: () => undefined,
		headers: {
			'content-type': 'application/json',
			'content-length': body.length,
			'x-claudebox-agent-token': token,
		},
	});

	req.on('response', (res) => {
		if (res.statusCode !== 200) {
			let text = '';
			res.setEncoding('utf8');
			res.on('data', (d) => (text += d));
			res.on('end', () =>
				die(text.trim() || `claudebox: the workstation refused (${res.statusCode})`)
			);
			return;
		}

		// Decode the frames as they arrive, holding back only a partial one.
		let buf = Buffer.alloc(0);
		let exit = null;
		res.on('data', (d) => {
			buf = Buffer.concat([buf, d]);
			for (;;) {
				if (buf.length < 5) return;
				const channel = buf[0];
				const len = buf.readUInt32BE(1);
				if (buf.length < 5 + len) return;
				const payload = buf.subarray(5, 5 + len);
				buf = buf.subarray(5 + len);
				if (channel === 1) process.stdout.write(payload);
				else if (channel === 2) process.stderr.write(payload);
				else if (channel === 3) {
					try {
						exit = JSON.parse(payload.toString('utf8')).exit;
					} catch {
						exit = 1;
					}
				}
			}
		});
		res.on('end', () => {
			// No meta frame means the stream was cut rather than closed -- the
			// run did not report a status, so neither does this.
			if (exit == null) die('claudebox: the connection to the workstation ended mid-run');
			process.exitCode = exit;
		});
	});
	req.on('error', (e) => die(`claudebox: the run could not be sent (${e.message})`));
	req.end(body);
}

if (mode === 'health') healthCheck();
else runRemote();
