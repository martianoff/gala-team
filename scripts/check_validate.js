#!/usr/bin/env node
// Asserts on the validation output and prints findings.
const fs = require("fs");
const dir = "/tmp/galateam_validate_out";
const tempDir = process.env.TEMP || "C:/Users/maxmr/AppData/Local/Temp";
const realDir = fs.existsSync(dir) ? dir : tempDir + "/galateam_validate_out";

function readFrames(path) {
    return fs.readFileSync(path, "utf8")
        .split(/\r?\n/)
        .filter(l => l.trim())
        .map(l => { try { return JSON.parse(l); } catch (e) { return { _raw: l }; } });
}

const findings = [];
function fail(scenario, expectation, got) {
    findings.push({ scenario, expectation, got });
}
function ok(scenario, msg) {
    console.log("  ✓ " + scenario + ": " + msg);
}

// ===== (1) init full flow =====
{
    const sc = "01_init_full_flow";
    const frames = readFrames(realDir + "/01_init_full_flow.jsonl").filter(f => f.type === "frame");
    if (frames.length === 0) {
        fail(sc, "frames produced", "0 frames");
    } else {
        // After typing fix + Enter, we should see "you: fix" in some frame.
        const sawUserPrompt = frames.some(f => f.plain && f.plain.includes("you: fix"));
        if (!sawUserPrompt) fail(sc, "user prompt 'fix' echoed in transcript", "not found");
        else ok(sc, "user prompt echoed in transcript");

        // After Lead emits @dispatch + EOF, status for Lead should be Idle.
        const lastLeadStatus = frames.slice().reverse().find(f => f.statuses && "Lead" in f.statuses);
        if (lastLeadStatus) {
            ok(sc, `Lead final status = '${lastLeadStatus.statuses.Lead}'`);
            if (lastLeadStatus.statuses.Lead !== "idle") {
                fail(sc, "Lead final status idle after EOF", lastLeadStatus.statuses.Lead);
            }
        }

        // After Eng emits @finished + EOF, transcript should contain 'on it'.
        const sawEngWork = frames.some(f => f.plain && f.plain.includes("on it"));
        if (!sawEngWork) fail(sc, "Eng output 'on it' in transcript", "not found");
        else ok(sc, "Eng output rendered in transcript");
    }
}

// ===== (2b) recovery banner =====
{
    const sc = "02b_recovery";
    const frames = readFrames(realDir + "/02b_recovery.jsonl").filter(f => f.type === "frame");
    if (frames.length > 0) {
        const f = frames[0];
        const plain = f.plain || "";
        if (plain.includes("Restored")) ok(sc, "recovery banner visible");
        else fail(sc, "recovery banner '↻ Restored ... lines'", "not found in first frame");

        // The recovery should report at least 1 agent recovered.
        const m = plain.match(/Restored (\d+) line/);
        if (m) ok(sc, `restored ${m[1]} lines`);
        else fail(sc, "Restored N lines text", plain.split("\n").slice(0, 6).join(" | "));
    } else {
        fail(sc, "recovery scenario produced frames", "0");
    }
}

// ===== (3) error display =====
{
    const sc = "03_errors";
    const frames = readFrames(realDir + "/03_errors.jsonl").filter(f => f.type === "frame");
    const errs = frames.map(f => f.lastError).filter(Boolean);
    if (errs.length === 0) {
        fail(sc, "lastError surface for SessionFailed non-EOF", "no error in any frame");
    } else {
        ok(sc, `lastError captured: ${errs[0]}`);
        // The pipe-ended error should NOT trigger retry (it's a clean close).
        const pipeFrame = frames.find(f => f.lastError && f.lastError.includes("pipe has been ended"));
        if (pipeFrame) {
            fail(sc, "pipe-ended treated as EOF (no retry text)", pipeFrame.lastError);
        } else {
            ok(sc, "pipe-ended error NOT retried (treated as clean close)");
        }
    }
}

// ===== Summary =====
console.log("");
if (findings.length === 0) {
    console.log("ALL CHECKS PASSED");
} else {
    console.log(`${findings.length} FAILURES:`);
    for (const f of findings) {
        console.log(`  ✗ [${f.scenario}] expected: ${f.expectation}`);
        console.log(`         got: ${f.got}`);
    }
    process.exit(1);
}
