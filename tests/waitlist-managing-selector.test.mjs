import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const selectors=[...app.matchAll(/<select value=\{config\.mode\} onChange=\{e=>void changeWaitlistMode\(e\.target\.value as Config\['mode'\]\)\}>((?:<option[^>]*>[^<]*<\/option>)+)<\/select>/g)];

test('the retained Managing mode selector exposes Waitlist through the existing mutation path',()=>{
  assert.match(app,/facility-admin-context"><span>Managing<\/span>/);
  assert.equal(selectors.length,3,'Teams, standard, and Hybrid branches retain one mutually exclusive selector each');
  for(const [,options] of selectors){
    for(const option of ['regular','rejoin','teams','teams_rejoin','hybrid_waitlist']) assert.match(options,new RegExp(`value="${option}"`));
    assert.match(options,/value="hybrid_waitlist">Waitlist<\/option>/);
  }
  assert.match(app,/isTeamsMode\(config\.mode\)&&operator&&<section[\s\S]*<select value=\{config\.mode\}/);
  assert.match(app,/!isTeamsMode\(config\.mode\)&&!isHybridWaitlist&&operator&&<section[\s\S]*<select value=\{config\.mode\}/);
  assert.match(app,/isHybridWaitlist&&admin&&<section className="admin-tools hybrid-mode-selector"><select value=\{config\.mode\}/);
  assert.doesNotMatch(app,/Waitlist configuration/);
});
