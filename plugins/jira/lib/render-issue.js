#!/usr/bin/env node
//
// Turn one JIRA issue, as the REST API returns it, into the markdown file the
// box's agent is pointed at. Reads the JSON on stdin, writes markdown on stdout;
// no arguments, no dependencies, no network -- which is what lets it run either
// under the host's node or under the box's, whichever exists.
//
// The interesting half is the description. Jira Cloud's API v3 returns it as
// Atlassian Document Format: a tree of typed nodes, not text. There is no way to
// ask that endpoint for markdown, so this walks the tree.
//
// It is deliberately not a complete ADF implementation. It covers what bug
// reports are made of -- prose, lists, links, and above all code blocks, which
// carry the stack trace or the payload that makes an issue reproducible -- and
// an unknown node falls through to rendering its children rather than being
// dropped. Losing a paragraph because it was wrapped in something unexpected
// would be silent, and the agent reading the file would never know it was
// working from half a report.

const MARKS = {
    code:   (t) => '`' + t + '`',
    strong: (t) => '**' + t + '**',
    em:     (t) => '*' + t + '*',
    strike: (t) => '~~' + t + '~~',
};

// Escape only what would otherwise change the structure of the output. A bug
// report is full of *, _ and [ used as themselves; escaping them all would make
// the file harder to read than the ADF was.
function escapeText(text) {
    return text.replace(/^(\s*)(#{1,6}\s|>\s|[-*+]\s|\d+[.)]\s)/, '$1\\$2');
}

function inline(node) {
    if (node.type === 'text') {
        let out = node.text ?? '';
        const marks = node.marks ?? [];
        // A link wraps whatever the other marks produced, so it goes last.
        const link = marks.find((m) => m.type === 'link');
        for (const mark of marks) {
            if (mark.type === 'link') continue;
            const fn = MARKS[mark.type];
            if (fn) out = fn(out);
        }
        if (link && link.attrs && link.attrs.href) {
            out = '[' + out + '](' + link.attrs.href + ')';
        }
        return out;
    }
    if (node.type === 'hardBreak') return '\n';
    // @mentions and emoji carry their display text in attrs; the id behind them
    // is noise for a reader and for an agent alike.
    if (node.type === 'mention') return (node.attrs && node.attrs.text) || '@unknown';
    if (node.type === 'emoji') return (node.attrs && (node.attrs.text || node.attrs.shortName)) || '';
    if (node.type === 'inlineCard') return (node.attrs && node.attrs.url) || '';
    if (node.type === 'date') return (node.attrs && node.attrs.timestamp) || '';
    return (node.content ?? []).map(inline).join('');
}

function inlineOf(node) {
    return escapeText((node.content ?? []).map(inline).join(''));
}

function indent(text, prefix) {
    return text
        .split('\n')
        .map((line) => (line.length ? prefix + line : line))
        .join('\n');
}

// Returns a list of blocks; the caller joins them with blank lines. Keeping
// blocks separate rather than concatenating strings is what makes nesting --
// a code block inside a list item -- come out with the right indentation.
function block(node) {
    switch (node.type) {
        case 'doc':
            return (node.content ?? []).flatMap(block);

        case 'paragraph': {
            const text = inlineOf(node);
            return text.trim() ? [text] : [];
        }

        case 'heading': {
            const level = Math.min((node.attrs && node.attrs.level) || 1, 6);
            // Headings shift down one: the file's h1 is the issue summary, so a
            // description that starts at h1 would sit level with the title.
            return ['#'.repeat(Math.min(level + 1, 6)) + ' ' + inlineOf(node)];
        }

        case 'codeBlock': {
            const lang = (node.attrs && node.attrs.language) || '';
            const code = (node.content ?? []).map((c) => c.text ?? '').join('');
            // Widen the fence past any run of backticks in the code itself,
            // which is otherwise how a fenced block ends early and swallows the
            // rest of the issue.
            const longest = (code.match(/`+/g) ?? []).reduce((n, r) => Math.max(n, r.length), 0);
            const fence = '`'.repeat(Math.max(3, longest + 1));
            return [fence + lang + '\n' + code + '\n' + fence];
        }

        case 'blockquote':
            return [indent((node.content ?? []).flatMap(block).join('\n\n'), '> ')];

        case 'bulletList':
        case 'orderedList': {
            const ordered = node.type === 'orderedList';
            const start = (node.attrs && node.attrs.order) || 1;
            const items = (node.content ?? []).map((item, i) => {
                const marker = ordered ? `${start + i}. ` : '- ';
                const body = (item.content ?? []).flatMap(block).join('\n\n');
                // Continuation lines line up under the marker, so a nested list
                // or a code block stays inside its item.
                return marker + indent(body, ' '.repeat(marker.length)).slice(marker.length);
            });
            return [items.join('\n')];
        }

        case 'rule':
            return ['---'];

        case 'mediaSingle':
        case 'mediaGroup':
            // Attachments are not fetched: they live behind the same credential
            // this deliberately keeps out of the box. Say one was here, so the
            // agent knows the report is not complete rather than guessing.
            return ['*(attachment in JIRA, not downloaded)*'];

        case 'panel': {
            const kind = (node.attrs && node.attrs.panelType) || 'note';
            const body = (node.content ?? []).flatMap(block).join('\n\n');
            return [indent(`**${kind}:**\n` + body, '> ')];
        }

        case 'table': {
            const rows = (node.content ?? []).map((row) =>
                (row.content ?? []).map((cell) =>
                    (cell.content ?? []).flatMap(block).join(' ').replace(/\n/g, ' ').replace(/\|/g, '\\|')));
            if (!rows.length) return [];
            const width = Math.max(...rows.map((r) => r.length));
            const line = (cells) => '| ' + Array.from({ length: width }, (_, i) => cells[i] ?? '').join(' | ') + ' |';
            return [[line(rows[0]), line(Array(width).fill('---')), ...rows.slice(1).map(line)].join('\n')];
        }

        default: {
            // Unknown block: render what is inside it rather than dropping it.
            const kids = (node.content ?? []).flatMap(block);
            if (kids.length) return kids;
            const text = inlineOf(node);
            return text.trim() ? [text] : [];
        }
    }
}

function renderDescription(description) {
    if (!description) return '_(no description)_';
    // API v2, and some Cloud responses, give a plain string instead of ADF.
    if (typeof description === 'string') return description.trim() || '_(no description)_';
    const out = block(description).join('\n\n').replace(/\n{3,}/g, '\n\n').trim();
    return out || '_(no description)_';
}

function main(raw) {
    const issue = JSON.parse(raw);
    const fields = issue.fields ?? {};
    const key = issue.key ?? 'UNKNOWN';
    const summary = (fields.summary ?? '').trim() || '(no summary)';

    // The browse URL, rebuilt from the API's self link: it is the address a
    // person opens, and the one thing in the file that is not reproducible from
    // the issue text alone.
    let browse = '';
    if (issue.self) {
        try {
            browse = new URL(issue.self).origin + '/browse/' + key;
        } catch { /* a malformed self link is not worth failing the render over */ }
    }

    const meta = [
        ['Issue', browse ? `[${key}](${browse})` : key],
        ['Type', fields.issuetype && fields.issuetype.name],
        ['Status', fields.status && fields.status.name],
        ['Priority', fields.priority && fields.priority.name],
        ['Reporter', fields.reporter && fields.reporter.displayName],
        ['Created', fields.created],
    ].filter(([, v]) => v);

    const out = [
        `# ${key}: ${summary}`,
        meta.map(([k, v]) => `- **${k}:** ${v}`).join('\n'),
        '## Description',
        renderDescription(fields.description),
        // Says where this came from, for anyone who finds the file later in a
        // branch and wonders whether it is source or scratch.
        `---\n\n*Fetched from JIRA by \`claudebox jira:triage-issue ${key}\`.*`,
    ];
    process.stdout.write(out.join('\n\n') + '\n');
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
    try {
        main(input);
    } catch (err) {
        process.stderr.write('render-issue: could not render the issue: ' + err.message + '\n');
        process.exit(1);
    }
});
