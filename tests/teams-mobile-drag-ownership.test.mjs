import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../app/WaitlistApp.tsx', import.meta.url), 'utf8');
const css = readFileSync(new URL('../app/advanced.css', import.meta.url), 'utf8');
const king = app.match(/function KingBoard[\s\S]*?\r?\n}\r?\nfunction Modal/)?.[0] ?? '';
const teamCard = app.match(/function KingTeamCard[\s\S]*?\r?\n}\r?\nfunction TeamSubstituteRoster/)?.[0] ?? '';
const queue = app.match(/function QueueCard[\s\S]*?\r?\n}\r?\nfunction teamLabel/)?.[0] ?? '';

test('Teams keeps the source row mounted and gives it the same pointer ownership as Regular/Rejoin', () => {
  assert.match(teamCard, /const members=team\.members;/);
  assert.match(teamCard, /\$\{dragging===item\?\.id\?'dragging':''\}/);
  assert.match(teamCard, /onPointerMove=\{event=>\{if\(item&&item\.status!=='rejoin'&&operator\)_moveDrag\(event\)\}\}/);
  assert.match(teamCard, /onPointerUp=\{event=>\{if\(item&&item\.status!=='rejoin'&&operator\)_moveDrag\(event\)\}\}/);
  assert.match(king, /row\.setPointerCapture\(state\.pointerId\)/);
  assert.match(king, /document\.addEventListener\('touchmove',preventNativeTouchScroll,\{passive:false\}\)/);
  assert.match(queue, /row\.setPointerCapture\(e\.pointerId\)/);
  assert.match(queue, /onPointerMove=\{e=>\{const state=mobileDrag\.current[\s\S]*?e\.preventDefault\(\)/s);
});

test('Teams lets a normal swipe cancel the hold, then suppresses scrolling only after activation', () => {
  assert.match(king, /if\(!state\.active\)\{if\(state\.timer!==null&&Math\.hypot\(event\.clientX-state\.startX,event\.clientY-state\.startY\)>16\)/);
  assert.match(king, /if\(event\.type==='pointerup'\)\{finishDrag\(\);return;\}/);
  assert.match(king, /event\.preventDefault\(\);if\(state\.preview\)positionPlayerDragPreview/);
  assert.match(css, /body\.mobile-admin-dragging \.admin-row\[data-player-id\],body\.mobile-admin-dragging \.king-player-row\[data-player-id\]\{touch-action:none\}/);
});

test('Teams keeps a drag active over full or invalid targets and only commits a real drop', () => {
  assert.match(king, /target&&target\.members\.filter\(member=>member\.id!==dragRef\.current\.player\?\.id\)\.length<6/);
  assert.match(king, /if\(!card\)\{clearEmptyTarget\(\);if\(dropRef\.current\)\{dropRef\.current=null;setDrop\(null\)\}return;\}/);
  assert.doesNotMatch(king, /if\(!card\)[\s\S]{0,180}finishDrag\(/);
  assert.match(king, /const target=commit&&state\.active/);
  assert.match(king, /if\(playerId&&target\)void movePlayer/);
});
