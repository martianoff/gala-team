#!/usr/bin/env node
// Pipe a captured claude stream-json file through the test driver
// and report what landed in the conversation log.
//
// Usage:
//   node scripts/leak_hunt.js <captured.jsonl>
//
// Emits commands on stdout to feed the gala_team test-mode driver.

const fs = require('fs');
const path = process.argv[2];
if (!path) {
  console.error('usage: leak_hunt.js <captured.jsonl>');
  process.exit(2);
}
const lines = fs.readFileSync(path, 'utf8').split('\n').filter(l => l.length > 0);
console.log('{"type":"key","char":"x"}');
console.log('{"type":"key","key":"Enter"}');
for (const l of lines) {
  console.log(JSON.stringify({type:"msg", name:"ChunkArrived", member:"Lead", line: l}));
}
console.log('{"type":"msg","name":"SessionFailed","member":"Lead","err":"EOF"}');
console.log('{"type":"snapshot","detail":"plain"}');
console.log('{"type":"quit"}');
