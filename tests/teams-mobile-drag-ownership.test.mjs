import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../app/WaitlistApp.tsx', import.meta.url), 'utf8');
const king = app.match(/function KingBoard[\s\S]*?\r?\n}\r?\nfunction Modal/)?.[0] ?? '';
const queue = app.match(/function QueueCard[\s\S]*?\r?\n}\r?\nfunction teamLabel/)?.[0] ?? '';

test('Teams mobile drag uses the captured row as the active pointer owner', () => {
  assert.match(king, /row\.setPointerCapture\(state\.pointerId\)/);
  assert.match(king, /const moveDrag=.*event\.pointerType!==\'touch\'.*state\.active.*event\.preventDefault\(\).*positionPlayerDragPreview.*resolveTarget.*startAutoScroll/s);
  assert.match(king, /<KingTeamCard[^>]+moveDrag=\{moveDrag\}/);
  assert.match(app, /onPointerMove=\{event=>moveDrag\(event\)\}/);
  assert.match(queue, /onPointerMove=\{e=>\{const state=mobileDrag\.current[\s\S]*?e\.preventDefault\(\).*positionPlayerDragPreview/s);
});

test('Teams mobile drag arms a capture-phase non-passive touch blocker before hold activation', () => {
  assert.match(king, /document\.addEventListener\(\'touchmove\',preventNativeTouchScroll,\{passive:false,capture:true\}\);state\.timer=/);
  assert.match(king, /state\.active=true;document\.body\.classList\.add\(\'king-drag-holding\'\);setMobileAdminDragging/);
  assert.match(king, /document\.removeEventListener\(\'touchmove\',preventNativeTouchScroll,\{capture:true\}\)/);
});

test('Teams cancellation removes the preview and never commits a cancelled drop', () => {
  assert.match(king, /const finish=\(commit=true\)/);
  assert.match(king, /const target=commit&&state\.active/);
  assert.match(king, /const cancelPointer=\(\)=>finish\(false\)/);
  assert.match(king, /const cancelTouch=\(\)=>finish\(false\)/);
  assert.match(king, /document\.addEventListener\(\'pointercancel\',cancelPointer/);
  assert.match(king, /document\.addEventListener\(\'touchcancel\',cancelTouch/);
});
