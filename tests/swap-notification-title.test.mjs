import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const app=fs.readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');

test('accepted or declined player swaps are labelled as swap updates',()=>{
  assert.match(app,/const isSwapUpdate=\/\\b\(\?:substitute\|swap\)\\b\/i\.test\(notification\.message\)/);
  assert.match(app,/isSwapUpdate\?'Swap update':'Group update'/);
});
