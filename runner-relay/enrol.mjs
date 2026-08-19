// Trade a short enrolment code for a runner's token, and report the certificate
// that was on the other end of that exchange.
//
//   node enrol.mjs <host:port> <code>
//
// Run as a one-off container from the relay image, because this is the image
// that has node AND a route off this machine -- the box has neither, which is
// the whole point of the box. Prints two KEY=value lines on stdout for the
// launcher to read; anything else goes to stderr.
//
// Same two-step pin as relay.mjs, and for the same reason: learn the certificate
// on a handshake that carries nothing, then install it as the sole trust anchor
// for the request that carries the code. Nothing is sent to a server whose key
// has not already been read.
//
// What is NOT claimed: that the certificate is the RIGHT one. It is trusted on
// first sight and pinned from then on, exactly as ssh does with a host key. The
// code is what stops anyone else on the network enrolling; it is not what
// authenticates the runner.

import https from 'node:https';
import tls from 'node:tls';

const [target, code] = process.argv.slice(2);
const m = /^([A-Za-z0-9._-]+|\[[0-9A-Fa-f:]+\]):(\d{1,5})$/.exec(target || '');
if (!m || !code) {
	process.stderr.write('usage: enrol.mjs <host:port> <code>\n');
	process.exit(2);
}
const host = m[1].replace(/^\[|\]$/g, '');
const port = Number(m[2]);

function die(msg) {
	process.stderr.write(msg.endsWith('\n') ? msg : msg + '\n');
	process.exit(1);
}

function learnCertificate() {
	return new Promise((resolve, reject) => {
		const socket = tls.connect({ host, port, rejectUnauthorized: false }, () => {
			const cert = socket.getPeerCertificate();
			socket.destroy();
			if (!cert || !cert.raw) return reject(new Error('the runner presented no certificate'));
			resolve({
				fingerprint: (cert.fingerprint256 || '').toUpperCase(),
				pem:
					'-----BEGIN CERTIFICATE-----\n' +
					cert.raw.toString('base64').replace(/(.{64})/g, '$1\n').replace(/\n$/, '') +
					'\n-----END CERTIFICATE-----\n',
			});
		});
		socket.setNoDelay(true);
		socket.once('error', reject);
	});
}

const seen = await learnCertificate().catch((e) =>
	die(
		`claudebox: cannot reach a runner at ${target} (${e.message}).\n` +
			'Is claudebox-runner running there, and is the port open?'
	)
);

const body = Buffer.from(JSON.stringify({ code }));
const req = https.request({
	host,
	port,
	path: '/enrol',
	method: 'POST',
	agent: false,
	ca: seen.pem,
	checkServerIdentity: () => undefined,
	headers: { 'content-type': 'application/json', 'content-length': body.length },
});

req.on('response', (res) => {
	let text = '';
	res.setEncoding('utf8');
	res.on('data', (d) => (text += d));
	res.on('end', () => {
		if (res.statusCode !== 200) die(text.trim() || `enrolment refused (${res.statusCode})`);
		let token;
		try {
			token = JSON.parse(text).token;
		} catch {
			die(`unreadable reply from the runner: ${text.slice(0, 200)}`);
		}
		if (typeof token !== 'string' || !token) die('the runner returned no token');
		process.stdout.write(`TOKEN=${token}\nFINGERPRINT=${seen.fingerprint}\n`);
	});
});
req.on('error', (e) => die(`claudebox: enrolment failed (${e.message})`));
req.end(body);
