import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const app=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const selectors=[...app.matchAll(/const modeSelect=<select value=\{waitlistNew\?'waitlist_new':config\.mode\} onChange=\{e=>void chooseWaitlistMode\(e\.target\.value\)\}>((?:<option[^>]*>[^<]*<\/option>)+)<\/select>;/g)];

test('the retained Managing mode selector exposes Waitlist and Waitlist (New) through one shared selector',()=>{
  assert.match(app,/facility-admin-context"><span>Managing<\/span>/);
  assert.equal(selectors.length,1,'one shared selector definition');
  const [,options]=selectors[0];
  for(const option of ['regular','rejoin','teams','teams_rejoin','hybrid_waitlist','waitlist_new']) assert.match(options,new RegExp(`value="${option}"`));
  assert.match(options,/value="hybrid_waitlist">Waitlist<\/option>/);
  assert.match(options,/value="waitlist_new">Waitlist \(New\)<\/option>/);
  assert.match(app,/isTeamsMode\(config\.mode\)&&operator&&<section[\s\S]*\{admin&&modeSelect\}/);
  assert.match(app,/!isTeamsMode\(config\.mode\)&&!isHybridWaitlist&&operator&&<section[\s\S]*\{admin&&modeSelect\}/);
  assert.match(app,/isHybridWaitlist&&admin&&<section className="admin-tools hybrid-mode-selector">\{modeSelect\}<\/section>/);
  // Other modes still go through the existing mutation path.
  assert.match(app,/async function chooseWaitlistMode\(value:string\)\{[\s\S]*?await changeWaitlistMode\(value as Config\['mode'\]\);/);
  assert.doesNotMatch(app,/Waitlist configuration/);
});
