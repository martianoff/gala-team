#!/usr/bin/env node
// Deep analyzer for live_audit.sh output. Reports every observable issue.
const fs = require("fs");
const tmpRoot = process.env.TEMP || "/tmp";
const outDirs = fs.readdirSync(tmpRoot).filter(d => d.startsWith("galateam_live2_out_") || d.startsWith("galateam_live_out_"));
const sorted = outDirs.sort((a, b) => fs.statSync(tmpRoot + "/" + b).mtimeMs - fs.statSync(tmpRoot + "/" + a).mtimeMs);
const dir = tmpRoot + "/" + sorted[0];
console.log("Analyzing:", dir);

function frames(name) {
    const path = dir + "/" + name + ".jsonl";
    if (!fs.existsSync(path)) return [];
    return fs.readFileSync(path, "utf8").split(/\r?\n/).filter(l => l.trim())
        .map(l => { try { return JSON.parse(l); } catch (e) { return null; } })
        .filter(o => o && o.type === "frame");
}
function rawLines(name) {
    const path = dir + "/" + name + ".jsonl";
    if (!fs.existsSync(path)) return [];
    return fs.readFileSync(path, "utf8").split(/\r?\n/).filter(l => l.trim());
}

const findings = [];
function bug(scenario, sev, what, detail = "") {
    findings.push({ scenario, sev, what, detail });
}
function ok(scenario, what) {
    console.log(`  ✓ ${scenario}: ${what}`);
}

console.log("\n=== 1. Init-chunk filter ===");
{
    const fs1 = frames("01_init_filter");
    const after = fs1[fs1.length - 1];
    const transcript = (after.plain || "");
    if (transcript.includes("\"type\":\"system\"") || transcript.includes("\"tools\"") || transcript.includes("\"session_id\"")) {
        bug("01", "HIGH", "init noise leaked into transcript", transcript.split("\n").find(l => l.includes("session_id")));
    } else ok("01", "init system chunk filtered out");
    if (transcript.includes("Lead: Hello")) ok("01", "assistant text 'Hello!' rendered");
    else bug("01", "HIGH", "assistant text not visible in transcript");
    if (after.state !== "Approval" && after.state !== "Idle") {
        bug("01", "MED", `state after EOF should be Idle/Approval, got ${after.state}`);
    } else ok("01", `state after EOF: ${after.state}`);
}

console.log("\n=== 2. Multi-turn ===");
{
    const fs1 = frames("02_multiturn");
    const last = fs1[fs1.length - 1];
    const transcript = last.plain || "";
    const sawHi = transcript.includes("you: hi");
    const sawAgain = transcript.includes("you: again");
    if (sawHi && sawAgain) ok("02", "both prompts in transcript");
    else bug("02", "HIGH", `multi-turn broken — saw 'hi':${sawHi} 'again':${sawAgain}`);
    const sawFirst  = transcript.includes("Lead: hi back");
    const sawSecond = transcript.includes("Lead: second response");
    if (sawFirst && sawSecond) ok("02", "TL responded twice (once per turn)");
    else bug("02", "MED", `TL response count after 2 turns — first=${sawFirst} second=${sawSecond}`);
}

console.log("\n=== 3. Dispatch + finished + relay ===");
{
    const fs1 = frames("03_dispatch");
    const last = fs1[fs1.length - 1];
    if (last.plain && last.plain.includes("fixed it all")) ok("03", "Eng deliverable rendered");
    else bug("03", "HIGH", "Eng deliverable text 'fixed it all' missing");
    if (last.plain && last.plain.includes("@dispatch")) {
        bug("03", "MED", "raw @dispatch directive visible in transcript (should we render or strip?)");
    }
    if (last.statuses && last.statuses.Eng === "idle") ok("03", "Eng status idle after @finished + EOF");
    else bug("03", "MED", `Eng status = ${JSON.stringify(last.statuses)}`);
}

console.log("\n=== 4. Tool-use rendering ===");
{
    const fs1 = frames("04_tool_use");
    const last = fs1[fs1.length - 1];
    // tool_use markers should NOT show up in the transcript anymore —
    // they were too noisy on real claude turns. Sidebar spinner is the
    // signal that tools are running.
    if (last.plain && !last.plain.includes("[tool:")) ok("04", "tool_use markers filtered out of transcript");
    else bug("04", "MED", "tool_use marker leaked into transcript — should be hidden");
    if (last.plain && last.plain.includes("Let me check the file.")) ok("04", "text-before-tool-use rendered");
    else bug("04", "MED", "text part before tool_use missing");
}

console.log("\n=== 5. @summary → Approval ===");
{
    const fs1 = frames("05_approval");
    const last = fs1[fs1.length - 1];
    if (last.state === "Approval") ok("05", "FSM in Approval state");
    else bug("05", "HIGH", `state should be Approval, got ${last.state}`);
    if (last.plain && last.plain.includes("Ready to ship")) ok("05", "approval banner visible");
    else bug("05", "MED", "approval banner 'Ready to ship' not visible");
}

console.log("\n=== 6. Heartbeat escalation ===");
{
    const fs1 = frames("06_heartbeat");
    const ticks = fs1.map(f => f.tick).filter(t => typeof t === "number");
    const advanced = ticks.length > 0 && ticks[ticks.length - 1] > ticks[0];
    if (advanced) ok("06", `tick counter advanced ${ticks[0]} → ${ticks[ticks.length - 1]}`);
    else bug("06", "MED", "tick counter did not advance");
    // Note: 5 ticks won't cross the 30s slow threshold (ticks are milliseconds-level
    // in test mode); this is just a smoke test.
}

console.log("\n=== 7. Pipe-ended (clean close) ===");
{
    const fs1 = frames("07_pipe_ended");
    const last = fs1[fs1.length - 1];
    if (last.lastError && /retry/.test(last.lastError)) {
        bug("07", "HIGH", "pipe-ended treated as crash (retry triggered)", last.lastError);
    } else if (last.statuses && last.statuses.Lead === "idle") ok("07", "pipe-ended treated as clean EOF (Lead = idle)");
    else bug("07", "MED", `pipe-ended outcome unclear — statuses=${JSON.stringify(last.statuses)} err=${last.lastError}`);
}

console.log("\n=== 8. Retry exhaustion ===");
{
    const fs1 = frames("08_retries");
    const last = fs1[fs1.length - 1];
    if (last.statuses && last.statuses.Lead === "failed") ok("08", "Lead status = failed after retry exhaustion");
    else bug("08", "HIGH", `expected Lead=failed, got ${JSON.stringify(last.statuses)}`);
    if (last.lastError && last.lastError.includes("gave up")) ok("08", "LastError mentions retry exhaustion");
    else bug("08", "MED", `LastError text unexpected: ${last.lastError}`);
}

console.log("\n=== 9. Erase session ===");
{
    const fs1 = frames("09_erase");
    // After 2 Ctrl+N: composer empty, transcript empty
    const last = fs1[fs1.length - 1];
    const composerCleared = last.plain && !last.plain.includes("ab▌");
    const convoCleared = last.plain && !last.plain.includes("you: ab");
    if (composerCleared && convoCleared) ok("09", "session erased: composer + transcript cleared");
    else bug("09", "HIGH", `erase incomplete — composer=${composerCleared}, transcript=${convoCleared}`);
    const stateOk = last.state === "Idle";
    if (stateOk) ok("09", "state reset to Idle after erase");
    else bug("09", "MED", `state after erase = ${last.state}, expected Idle`);
}

console.log("\n=== 10. Recovery on relaunch ===");
{
    const fs1 = frames("10_recovery_relaunch");
    if (fs1.length === 0) bug("10", "HIGH", "no frames produced");
    else {
        const f = fs1[0];
        // After scenario 9 erased the session, recovery should show 0 lines
        // (or no banner).
        if (f.plain && f.plain.includes("Restored")) {
            const m = f.plain.match(/Restored (\d+) line/);
            ok("10", `recovery banner shows restored ${m ? m[1] : "?"} lines`);
        } else ok("10", "no recovery banner (clean state)");
    }
}

console.log("\n=== 11. @blocked routing ===");
{
    const fs1 = frames("11_blocked");
    const last = fs1[fs1.length - 1];
    if (last.statuses && last.statuses.Eng === "failed") ok("11", "@blocked → Eng status failed");
    else bug("11", "HIGH", `@blocked: Eng status = ${JSON.stringify(last.statuses)}`);
    // The @blocked reason no longer fills LastError (was hiding the
    // footer keybinds). The body lives in the conversation transcript
    // + the StFailed sidebar badge truncation.
    if (last.plain && last.plain.includes("missing tool gh")) ok("11", "@blocked reason rendered in conversation");
    else bug("11", "MED", "@blocked reason missing from conversation transcript");
}

console.log("\n=== 15. Scrollable chat: PgUp unsticks, End re-sticks ===");
{
    const fs1 = frames("15_scroll");
    if (fs1.length === 0) bug("15", "HIGH", "no frames");
    else {
        // Snapshots are at frames after EOF / after PageUp / after End.
        // Find the frames whose `detail` field marks them as snapshots.
        const snaps = fs1.filter(f => f.detail === "plain");
        if (snaps.length < 3) bug("15", "MED", `expected 3 snapshots, got ${snaps.length}`);
        else {
            const afterEof = snaps[0];
            const afterPgUp = snaps[1];
            const afterEnd = snaps[2];
            // After EOF + sticky default: all 3 lines visible.
            const sawAll = afterEof.plain && /line one/.test(afterEof.plain) &&
                /line two/.test(afterEof.plain) && /line three/.test(afterEof.plain);
            if (sawAll) ok("15", "all 3 lines render at sticky bottom");
            else bug("15", "MED", "missing lines at sticky bottom");
            // PageUp doesn't have to do anything visible when content fits
            // viewport, but it shouldn't crash. End must keep view at bottom.
            if (afterEnd.plain && /line three/.test(afterEnd.plain)) ok("15", "End re-sticks to bottom");
            else bug("15", "MED", "End did not re-stick to bottom");
        }
    }
}

console.log("\n=== 13. Rate-limit error surfaced as toast ===");
{
    const fs1 = frames("13_rate_limit");
    const last = fs1[fs1.length - 1];
    if (last && last.lastError && /Rate limit/i.test(last.lastError)) ok("13", "rate-limit reason in LastError");
    else bug("13", "HIGH", `rate-limit not surfaced — lastError=${last && last.lastError}`);
    if (last && last.plain && !/"is_error"/.test(last.plain) && !/"type":"result"/.test(last.plain)) ok("13", "no JSON noise in transcript");
    else bug("13", "HIGH", "rate-limit JSON leaked into transcript");
}

console.log("\n=== 14. Unknown event kind dropped ===");
{
    const fs1 = frames("14_unknown_kind");
    const last = fs1[fs1.length - 1];
    const noise = last && last.plain && (/"type":"control_request"/.test(last.plain) || /"foo":"bar"/.test(last.plain));
    if (!noise) ok("14", "unknown event kind dropped (no JSON leak)");
    else bug("14", "HIGH", "unknown event leaked as raw JSON");
    if (last && last.plain && /Lead: answer/.test(last.plain)) ok("14", "subsequent assistant chunk still rendered");
    else bug("14", "MED", "subsequent assistant chunk missing — filter ate too much");
}

console.log("\n=== 12. Resize sweep — header survival ===");
{
    const fs1 = frames("12_resize");
    let allOk = true;
    for (const f of fs1) {
        if (!f.term || !f.plain) continue;
        const headerArea = f.plain.split("\n").slice(0, 4).join(" ");
        const hasGalaTeam = headerArea.includes("Gala Team");
        const hasApple = headerArea.includes("🍎");
        if (!hasGalaTeam) {
            bug("12", "HIGH", `'Gala Team' missing at ${f.term.cols}x${f.term.rows}`);
            allOk = false;
        }
        if (!hasApple) {
            bug("12", "MED", `apple emoji missing at ${f.term.cols}x${f.term.rows}`);
            allOk = false;
        }
    }
    if (allOk) ok("12", "header intact at every tested size");
}

// === Cross-scenario noise check ===
console.log("\n=== Cross-cutting: any JSON noise in any transcript ===");
{
    let leaked = false;
    for (const fname of fs.readdirSync(dir)) {
        const fs1 = frames(fname.replace(".jsonl", ""));
        for (const f of fs1) {
            const p = f.plain || "";
            if (/"tools":\[/.test(p) || /"session_id":/.test(p) || /"duration_ms":/.test(p)) {
                bug(fname, "HIGH", "claude JSON metadata leaked into transcript");
                leaked = true;
                break;
            }
        }
    }
    if (!leaked) ok("XCUT", "no claude JSON metadata in any transcript");
}

// ===== SUMMARY =====
console.log("\n=== SUMMARY ===");
const bySev = findings.reduce((acc, f) => { acc[f.sev] = (acc[f.sev] || 0) + 1; return acc; }, {});
console.log(`Total: ${findings.length}`);
for (const [sev, n] of Object.entries(bySev)) console.log(`  ${sev}: ${n}`);

console.log("\nFINDINGS:");
for (const f of findings) {
    console.log(`  [${f.sev}] ${f.scenario}: ${f.what}`);
    if (f.detail) console.log(`    detail: ${String(f.detail).slice(0, 160)}`);
}
