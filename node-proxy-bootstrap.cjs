// Preloaded into every Node process in the box via NODE_OPTIONS.
//
// The box has no route to the internet and no resolver of its own. Everything
// leaves through the Squid proxy, which resolves names on the box's behalf.
// That breaks Node programs in two distinct ways:
//
//  1) Proxying. Node ignores HTTP_PROXY/HTTPS_PROXY by default, for fetch() and
//     for the http/https core clients alike. Node 22.23 honours them -- and
//     NO_PROXY -- when NODE_USE_ENV_PROXY=1, which docker-compose.yaml sets.
//     That covers this case natively, so this file no longer installs
//     https-proxy-agent/http-proxy-agent over the global agents. Dropping that
//     also drops the hardcoded require anchor into one project's node_modules,
//     and it is strictly better behaved: overriding globalAgent sent NO_PROXY
//     hosts (dind, localhost) through the proxy too, where they fail.
//
//  2) DNS preflights, which nothing can fix generically. A library that calls
//     dns.resolve() to decide whether it is online gets a failure -- there is no
//     resolver -- and concludes it is offline, even though the proxy can reach
//     the host perfectly well. wp-env's canAccessWPORG() does exactly this.
//     Resolution is stubbed for the domains in CLAUDEBOX_DNS_STUB so those
//     checks pass. Nothing is bypassed: the connection that follows still goes
//     through the proxy and is still subject to the allowlist.
//
// CLAUDEBOX_DNS_STUB is a comma-separated suffix list (default "wordpress.org").
// "*" stubs every name; empty disables the shim entirely.
//
// This runs in EVERY node process in the box, Claude Code included, so it must
// never throw. Anything unexpected is reported and execution continues.

'use strict';

try {
	const dns = require('dns');

	// A stubbed name answers 127.0.0.1 -- enough for "am I online" checks, and
	// deliberately useless for anything trying to connect to the address
	// directly, which has no route out anyway.
	const ANSWER = ['127.0.0.1'];

	const raw = process.env.CLAUDEBOX_DNS_STUB;
	const spec = String(raw === undefined ? 'wordpress.org' : raw).trim();

	if (spec !== '') {
		const all = spec === '*';
		const suffixes = all
			? []
			: spec
					.split(',')
					.map((s) => s.trim().toLowerCase().replace(/^\.+/, ''))
					.filter(Boolean);

		const stubbed = (hostname) => {
			if (all) return true;
			const h = String(hostname).toLowerCase();
			return suffixes.some((s) => h === s || h.endsWith('.' + s));
		};

		// Callback-style dns.resolve (c-ares).
		const origResolve = dns.resolve;
		dns.resolve = function (hostname, ...args) {
			if (stubbed(hostname)) {
				const cb = args[args.length - 1];
				if (typeof cb === 'function') {
					process.nextTick(() => cb(null, ANSWER.slice()));
					return;
				}
			}
			return origResolve.call(this, hostname, ...args);
		};

		// Promise-style dns.promises.resolve -- this is the one wp-env uses.
		if (dns.promises && typeof dns.promises.resolve === 'function') {
			const origResolveP = dns.promises.resolve.bind(dns.promises);
			dns.promises.resolve = function (hostname, ...args) {
				if (stubbed(hostname)) {
					return Promise.resolve(ANSWER.slice());
				}
				return origResolveP(hostname, ...args);
			};
		}
	}

	// If this ever stops being set, Node silently goes back to ignoring the
	// proxy variables and every outbound request fails with EAI_AGAIN, which
	// looks like a DNS fault rather than a configuration one. Say so instead.
	if (process.env.NODE_USE_ENV_PROXY !== '1') {
		process.emitWarning(
			'claudebox: NODE_USE_ENV_PROXY is not set, so Node will ignore HTTPS_PROXY ' +
				'and outbound requests will fail. See docker-compose.yaml.'
		);
	}
} catch (err) {
	// Never take the process down: a broken shim here would break every node
	// program in the box, Claude Code included.
	try {
		process.emitWarning('claudebox proxy bootstrap failed: ' + (err && err.message));
	} catch (_) {
		/* nothing left to do */
	}
}
