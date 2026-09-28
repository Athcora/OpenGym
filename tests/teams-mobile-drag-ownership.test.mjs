import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../app/WaitlistApp.tsx', import.meta.url), 'utf8');
const king = app.match(/function KingBoard[\s\S]*?\r?\n}\r?\nfunction Modal/)?.[0] ?? '';
const queue = app.match(/function QueueCard[\s\S]*?\r?\n}\r?\nfunction teamLabel/)?.[0] ?? '';

test('Teams mobile drag uses the same stable document lifecycle as QueueCard', () => {
  assert.match(king, /const boardRef=useRef<HTMLDivElement\|null>\(null\)/);
  assert.match(king, /owner\.setPointerCapture\(event\.pointerId\)/);
  assert.match(king, /document\.addEventListener\('pointermove',moveActiveTouchDrag,\{passive:false,capture:true\}\)/);
  assert.doesNotMatch(king, /onPointerMove=\{event=>moveDrag\(event\)\}/);
  assert.match(king, /<KingTeamCard[^>]+moveDrag=\{moveDrag\}/);
  assert.match(queue, /onPointerMove=\{e=>\{const state=mobileDrag\.current[\s\S]*?e\.preventDefault\(\).*positionPlayerDragPreview/s);
});

test('Teams mobile drag arms a capture-phase non-passive touch blocker before hold activation', () => {
  assert.match(king, /else\{try\{owner\.setPointerCapture\(event\.pointerId\)\}catch\{\}traceDrag\('pointer-captured-at-down'/);
  assert.match(king, /document\.addEventListener\(\'touchmove\',preventNativeTouchScroll,\{passive:false,capture:true\}\);state\.timer=/);
  assert.match(king, /state\.active=true;traceDrag\('drag-activated'.*document\.body\.classList\.add\('king-drag-holding'\);setMobileAdminDragging/s);
  assert.match(king, /document\.removeEventListener\(\'touchmove\',preventNativeTouchScroll,\{capture:true\}\)/);
});

test('Teams cancellation removes the preview and never commits a cancelled drop', () => {
  assert.match(king, /const finish=\(commit=true\)/);
  assert.match(king, /const target=commit&&state\.active/);
  assert.match(king, /const cancelPointer=\(\)=>\{traceDrag\('pointercancel'\);finish\(false\)\}/);
  assert.match(king, /const cancelTouch=\(\)=>\{traceDrag\('touchcancel'\);finish\(false\)\}/);
  assert.match(king, /document\.addEventListener\(\'pointercancel\',cancelPointer/);
  assert.match(king, /document\.addEventListener\(\'touchcancel\',cancelTouch/);
});

test('Teams physical-touch diagnostic records stable-owner lifetime and premature termination facts', () => {
  assert.match(king, /window\.__openGymTeamDragTrace/);
  assert.match(king, /sequence:\+\+traceSequence\.current/);
  assert.match(king, /trace\.slice\(-240\)/);
  assert.match(king, /owner\.addEventListener\('lostpointercapture',lostCapture\)/);
  assert.match(king, /traceDrag\('post-activation-render'.*rowConnected:row\.isConnected.*previewConnected/s);
  assert.match(king, /source-row-unmounted/);
  assert.match(king, /board-render/);
  assert.match(king, /native-\$\{event\.type\}/);
  assert.match(king, /'pointerdown','pointermove','pointerup','pointercancel','lostpointercapture','touchstart','touchmove','touchend','touchcancel'/);
  assert.match(king, /traceDrag\('finish',\{commit,active:state\.active/);
  assert.match(king, /traceDrag\('pointercancel'\)/);
  assert.match(king, /traceDrag\('touchcancel'\)/);
});

test('Teams keeps the shared drag alive when a full or invalid team has no target', () => {
  assert.match(king, /target&&target\.members\.filter\(member=>member\.id!==dragRef\.current\.player\?\.id\)\.length<6/);
  assert.match(king, /if\(!card\)\{clearEmptyTarget\(\);if\(dropRef\.current\)\{dropRef\.current=null;setDrop\(null\)\}return;\}/);
  assert.doesNotMatch(king, /if\(!card\)[\s\S]{0,180}finish\(/);
});
