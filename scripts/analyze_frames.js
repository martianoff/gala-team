#!/usr/bin/env node
// Reads /tmp/ui_audit.*.jsonl and produces a bug survey.
const fs = require("fs");
const path = require("path");
const dir = process.env.TEMP || "C:/Users/maxmr/AppData/Local/Temp";
const files = fs.readdirSync(dir).filter(f => f.startsWith("ui_audit.") && f.endsWith(".jsonl")).sort();

const findings = [];

function scanFrame(scenario, idx, frame) {
    const plain = frame.plain || "";
    const lines = plain.split("\n");
    const cols = frame.term ? frame.term.cols : null;
    const rows = frame.term ? frame.term.rows : null;
    // Title row should contain 🍎 and gala_team
    if (lines.length > 0) {
        const title = lines[0];
        if (!title.includes("🍎")) {
            findings.push({scenario, idx, severity: "MED", bug: "header missing 🍎 emoji", row: title.slice(0, 100)});
        }
        if (cols && title.length > cols) {
            findings.push({scenario, idx, severity: "HIGH", bug: `title row exceeds terminal width (${title.length} > ${cols})`, row: title.slice(0, cols + 5)});
        }
        // Check truncation: title should NOT end with cut-off text in middle of word/desc
        if (title.match(/[a-zA-Z]$/) && title.length === cols) {
            findings.push({scenario, idx, severity: "MED", bug: "title row likely truncated mid-word", row: title.slice(-50)});
        }
    }
    // Check rendered conversation lines for overflow
    for (let i = 0; i < lines.length; i++) {
        if (cols && lines[i].length > cols + 1) { // +1 for trailing newline tolerance
            findings.push({scenario, idx, severity: "HIGH", bug: `row ${i} exceeds terminal width (${lines[i].length} > ${cols})`, row: lines[i].slice(0, 80)});
        }
    }
    // Total rendered height
    const trueRows = lines.length - 1; // last line might be blank
    if (rows && trueRows > rows + 2) {
        findings.push({scenario, idx, severity: "MED", bug: `rendered ${trueRows} rows but term is ${rows}`, row: "(layout overflow)"});
    }
    // Check if "agent doesn't work" indicators appear
    if (frame.lastError && /pipe has been ended|broken pipe|failed to/.test(frame.lastError)) {
        findings.push({scenario, idx, severity: "HIGH", bug: "agent failure surfaced in lastError", row: frame.lastError});
    }
}

for (const f of files) {
    const lines = fs.readFileSync(path.join(dir, f), "utf8").split(/\r?\n/).filter(l => l.trim());
    let idx = 0;
    for (const ln of lines) {
        let o;
        try { o = JSON.parse(ln); } catch (e) {
            findings.push({scenario: f, idx, severity: "HIGH", bug: "non-JSON output line", row: ln.slice(0, 200)});
            idx++;
            continue;
        }
        if (o.type === "frame") {
            scanFrame(f, idx, o);
        } else if (o.type === "error") {
            findings.push({scenario: f, idx, severity: "HIGH", bug: "harness emitted error", row: o.reason});
        }
        idx++;
    }
}

// Print findings grouped by bug
const byBug = {};
for (const f of findings) {
    const key = f.bug;
    byBug[key] = byBug[key] || [];
    byBug[key].push(f);
}

console.log(`# UI audit — ${findings.length} findings across ${files.length} scenarios\n`);
const sortedBugs = Object.entries(byBug).sort((a, b) => b[1].length - a[1].length);
for (const [bug, occurrences] of sortedBugs) {
    console.log(`## [${occurrences[0].severity}] ${bug}  ×${occurrences.length}`);
    const examples = occurrences.slice(0, 3);
    for (const ex of examples) {
        console.log(`  - ${ex.scenario.replace("ui_audit.", "").replace(".jsonl", "")} @${ex.idx}: ${ex.row.slice(0, 120)}`);
    }
    if (occurrences.length > 3) console.log(`  - …and ${occurrences.length - 3} more`);
    console.log();
}
