import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import ts from 'typescript';

// Exercise the production restoration helper against the measured mobile layout sequence.
const source=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const implementation=source.slice(source.indexOf('function settleModeViewport('),source.indexOf('export default function App'));
const compiled=ts.transpileModule(implementation,{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
function setup({scrollHeight,innerHeight=844,scrollY=0}){
  const scrolls=[];
  const document={scrollingElement:{scrollHeight}};
  const window={innerHeight,scrollY,scrollTo(options){scrolls.push(options);this.scrollY=options.top}};
  const context={document,window};runInNewContext(compiled,context);
  return {...context,scrolls};
}

test('deep Rejoin to Teams waits through the measured intermediate mobile layout before settling',()=>{
  const s=setup({scrollHeight:3235,scrollY:4455.33});
  const pending={scrollY:4455.33,layoutRevision:7};
  assert.equal(s.settleModeViewport(pending,7),false);
  assert.equal(s.window.scrollY,2391);
  s.document.scrollingElement.scrollHeight=6767;
  assert.equal(s.settleModeViewport(pending,8),true);
  assert.equal(s.window.scrollY,4455.33);
});

test('a stale pre-replacement height cannot finalize restoration before the target layout revision',()=>{
  const s=setup({scrollHeight:5299.33,scrollY:4455.33});
  const pending={scrollY:4455.33,layoutRevision:7};
  assert.equal(s.settleModeViewport(pending,7),false);
  assert.equal(s.window.scrollY,4455.33);
});

test('deep Rejoin to Teams Rejoin reapplies the saved position after its target layout is ready',()=>{
  const s=setup({scrollHeight:3235,scrollY:4455.33});
  const pending={scrollY:4455.33,layoutRevision:12};
  assert.equal(s.settleModeViewport(pending,12),false);
  s.document.scrollingElement.scrollHeight=6767;
  assert.equal(s.settleModeViewport(pending,13),true);
  assert.equal(s.window.scrollY,4455.33);
});

test('a genuinely shorter final layout clamps once its refresh layout revision is complete',()=>{
  const s=setup({scrollHeight:3000,scrollY:4455.33});
  assert.equal(s.settleModeViewport({scrollY:4455.33,layoutRevision:4},5),true);
  assert.equal(s.window.scrollY,2156);
});

test('near-top and desktop transitions preserve their existing positions without waiting',()=>{
  const nearTop=setup({scrollHeight:6767,scrollY:18});
  assert.equal(nearTop.settleModeViewport({scrollY:18,layoutRevision:2},3),true);
  assert.equal(nearTop.window.scrollY,18);
  const desktop=setup({scrollHeight:5101,innerHeight:764,scrollY:1103.33});
  assert.equal(desktop.settleModeViewport({scrollY:1103.33,layoutRevision:9},10),true);
  assert.equal(desktop.window.scrollY,1103.33);
});

test('the mode effect stays pending until the completed refresh layout revision arrives',()=>{
  assert.match(source,/return layoutRevision>pending\.layoutRevision;/);
  assert.match(source,/if\(!settleModeViewport\(pending,modeLayoutRevision\)\)return;/);
  assert.match(source,/const frame=window\.requestAnimationFrame/);
  assert.match(source,/\},\[config\.mode,modeLayoutRevision\]\);/);
  assert.match(source,/setKingTeams[\s\S]*?setModeLayoutRevision\(revision=>revision\+1\);/);
});
