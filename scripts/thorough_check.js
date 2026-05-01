#!/usr/bin/env node
// Reads the thorough audit output and reports per-scenario findings.
const fs = require("fs");
const dir = process.argv[2] || (process.env.TEMP || "/tmp");
const outDirs = fs.readdirSync(dir).filter(d => d.startsWith("galateam_thorough_out_"));
const sorted = outDirs.sort((a, b) => fs.statSync(dir + "/" + b).mtimeMs - fs.statSync(dir + "/" + a).mtimeMs);
const target = dir + "/" + sorted[0];
console.log("Target dir:", target);

function frames(name) {
    const path = target + "/" + name + ".jsonl";
    if (!fs.existsSync(path)) return [];
    return fs.readFileSync(path, "utf8").split(/\r?\n/).filter(l => l.trim())
        .map(l => { try { return JSON.parse(l); } catch (e) { return null; } })
        .filter(o => o && o.type === "frame");
}

const findings = [];
function bug(scenario, severity, description, detail) {
    findings.push({ scenario, severity, description, detail });
    console.log(`  [${severity}] ${scenario}: ${description}`);
    if (detail) console.log("            " + detail);
}
function ok(scenario, msg) {
    console.log(`  ✓ ${scenario}: ${msg}`);
}

console.log("\n== A. fresh init ==");
{
    const fs1 = frames("A_init");
    if (fs1.length === 0) bug("A", "HIGH", "no frames produced", null);
    else {
        const f = fs1[0];
        if (!f.plain.includes("🍎")) bug("A", "MED", "header missing apple emoji");
        else ok("A", "header has apple emoji");
        if (f.state !== "Idle") bug("A", "HIGH", `initial state should be Idle, got ${f.state}`);
        else ok("A", "initial state Idle");
        const composerLine = f.plain.split("\n").find(l => l.includes("Type to "));
        if (!composerLine) bug("A", "HIGH", "composer placeholder not visible");
        else ok("A", "composer placeholder: " + composerLine.trim().slice(0, 50));
    }
}

console.log("\n== B. type 'hi' + submit ==");
{
    const fs1 = frames("B_hi_submit");
    if (fs1.length < 4) bug("B", "HIGH", `expected 4+ frames, got ${fs1.length}`);
    else {
        const afterTyping = fs1[2]; // initial + 'h' + 'i' = frame at index 2 (0-indexed initial, then 2 chars)
        // Actually: initial + char h + char i + snapshot + Enter + snapshot
        // Look for "hi" in the composer area
        const sawHi = fs1.some(f => f.plain && f.plain.includes("hi"));
        if (!sawHi) bug("B", "HIGH", "typed 'hi' never appeared in any frame");
        else ok("B", "typed 'hi' visible");
        const afterEnter = fs1[fs1.length - 1];
        const composerEmpty = !afterEnter.plain.match(/Type to .+▌/) || !afterEnter.plain.includes("hi▌");
        if (afterEnter.plain.includes("you: hi")) ok("B", "after Enter, 'you: hi' in transcript");
        else bug("B", "HIGH", "after Enter, 'you: hi' should appear in conversation log");
        if (afterEnter.state === "TLThinking") ok("B", "state advances to TLThinking after submit");
        else bug("B", "MED", `state should be TLThinking after Enter, got ${afterEnter.state}`);
    }
}

console.log("\n== C. TL responds with 'hello back' ==");
{
    const fs1 = frames("C_tl_text_response");
    const lastTwo = fs1.slice(-2);
    const last = lastTwo[lastTwo.length - 1];
    if (last && last.plain.includes("Lead: hello back")) ok("C", "TL response 'hello back' rendered");
    else bug("C", "HIGH", "TL response 'hello back' not visible in transcript");
    if (last && last.statuses && last.statuses.Lead === "idle") ok("C", "Lead status idle after EOF");
    else bug("C", "MED", `Lead final status should be idle, got ${JSON.stringify(last && last.statuses)}`);
}

console.log("\n== D. dispatch + member done + relay ==");
{
    const fs1 = frames("D_full_dispatch");
    const last = fs1[fs1.length - 1];
    if (last.statuses && last.statuses.Eng === "idle") ok("D", "Eng status idle after @finished + EOF");
    else bug("D", "HIGH", `Eng final status should be idle, got ${JSON.stringify(last.statuses)}`);
    if (last.plain && last.plain.includes("done it")) ok("D", "Eng deliverable rendered");
    else bug("D", "MED", "Eng deliverable 'done it' not in transcript");
}

console.log("\n== E. @summary triggers Approval ==");
{
    const fs1 = frames("E_approval");
    const last = fs1[fs1.length - 1];
    if (last.state === "Approval") ok("E", "state advances to Approval");
    else bug("E", "HIGH", `state should be Approval after @summary, got ${last.state}`);
    if (last.plain && last.plain.includes("Ready to ship")) ok("E", "approval banner visible");
    else bug("E", "MED", "approval banner 'Ready to ship' not visible");
}

console.log("\n== F. terminal size sweep ==");
{
    const fs1 = frames("F_sizes");
    for (const f of fs1) {
        if (!f.term || !f.plain) continue;
        const lines = f.plain.split("\n").slice(0, 4); // header is rows 0..2
        const headerArea = lines.join(" ");
        const hasApple = headerArea.includes("🍎");
        const hasGalaTeam = headerArea.includes("gala_team");
        if (!hasGalaTeam && f.term.rows >= 8) bug("F", "HIGH", `'gala_team' branding missing at ${f.term.cols}x${f.term.rows}`, "header=" + headerArea.slice(0, 100));
        else if (!hasApple && f.term.rows >= 8) bug("F", "MED", `apple missing at ${f.term.cols}x${f.term.rows}`);
        else if (hasApple && hasGalaTeam) ok("F", `branding intact at ${f.term.cols}x${f.term.rows}`);
        // Check for layout truncation
        if (f.term.rows < 7 && lines.length > f.term.rows + 1) {
            // expected at very small sizes; not an error but worth noting
        }
    }
}

console.log("\n== G. focus toggle ==");
{
    const fs1 = frames("G_focus");
    // Test sequence: snapshot, CtrlL, snapshot, CtrlL, snapshot.
    // Auto-frame after each AppMsg + explicit snapshot frames →
    // 6 frames total. Frame 2 (post first CtrlL → sidebar focus)
    // and frame 4 (post second CtrlL → composer focus again).
    const sidebarFocused = fs1[2];
    const composerAfter = fs1[4] || fs1[fs1.length - 1];
    const sidebarHasMark = sidebarFocused && sidebarFocused.plain && sidebarFocused.plain.includes("▎");
    const composerHasMark = composerAfter && composerAfter.plain && composerAfter.plain.includes("▎");
    if (sidebarHasMark) ok("G", "cursor mark ▎ visible after first Ctrl+L");
    else bug("G", "MED", "cursor mark ▎ should be visible after first Ctrl+L");
    if (!composerHasMark) ok("G", "cursor mark hidden after second Ctrl+L (back to composer)");
    else bug("G", "MED", "cursor mark should hide when focus returns to composer");
}

console.log("\n== H. heartbeat ticks ==");
{
    const fs1 = frames("H_heartbeat");
    const last = fs1[fs1.length - 1];
    if (last.tick > 0) ok("H", "tick counter advances after tick storm");
    else bug("H", "MED", `tick counter should advance, got ${last.tick}`);
}

console.log("\n== I. Ctrl+N erase confirm ==");
{
    const fs1 = frames("I_erase_confirm");
    // After typing 'a', 'b': composer has 'ab'. After first Ctrl+N: warning. After second Ctrl+N: cleared.
    const afterFirstN = fs1.find(f => f.plain && f.plain.includes("Erase session?"));
    if (afterFirstN) ok("I", "Ctrl+N first press shows confirmation");
    else bug("I", "HIGH", "Ctrl+N first press should show 'Erase session?' warning");
    // After second Ctrl+N: composer should be empty + no conversation
    const last = fs1[fs1.length - 1];
    const composerEmpty = last.plain && !last.plain.includes("ab▌");
    if (composerEmpty) ok("I", "after second Ctrl+N, composer is cleared");
    else bug("I", "HIGH", "after second Ctrl+N, composer should be empty (was 'ab')");
}

console.log("\n== J. Ctrl+N + Esc cancel ==");
{
    const fs1 = frames("J_erase_cancel");
    const afterN = fs1.find(f => f.plain && f.plain.includes("Erase session?"));
    if (afterN) ok("J", "Ctrl+N shows confirmation");
    else bug("J", "MED", "Ctrl+N should show 'Erase session?' warning");
    const last = fs1[fs1.length - 1];
    const cancelled = last.plain && !last.plain.includes("Erase session?");
    if (cancelled) ok("J", "Esc cancels the confirmation");
    else bug("J", "HIGH", "Esc should clear EraseSessionPending");
    // Composer should still have 'x'
    const stillHasX = last.plain && last.plain.includes("x▌");
    if (stillHasX) ok("J", "composer text 'x' preserved through cancel");
    else bug("J", "HIGH", "composer 'x' should be preserved when Esc cancels");
}

console.log("\n=== SUMMARY ===");
console.log(`Total findings: ${findings.length}`);
const bySev = findings.reduce((acc, f) => { acc[f.severity] = (acc[f.severity] || 0) + 1; return acc; }, {});
for (const [sev, n] of Object.entries(bySev)) {
    console.log(`  ${sev}: ${n}`);
}
if (findings.length > 0) process.exit(1);
