import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import ts from 'typescript';

// Execute the real drag-lock implementation with a small DOM stand-in.
const source=readFileSync(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const implementation=source.slice(source.indexOf('let activeMobileDragScrollY='),source.indexOf('function scrollActiveMobileDrag('));
const compiled=ts.transpileModule(implementation,{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
function setup(){
  const classes=()=>{const values=new Set();return {contains:value=>values.has(value),toggle(value,on){if(on)values.add(value);else values.delete(value)}}};
  const scrolls=[];
  const body={classList:classes(),style:{},scrollHeight:5000,getBoundingClientRect:()=>({height:5000})};
  const document={body,documentElement:{classList:classes(),scrollHeight:5000},querySelector:()=>null};
  const window={scrollY:1600,innerHeight:900,scrollTo(options){scrolls.push(options);this.scrollY=options.top}};
  const context={document,window};runInNewContext(compiled,context);
  return {...context,scrolls,set:context.setMobileAdminDragging};
}
test('idle drag cleanup does not reset a populated mode-switch viewport',()=>{
  const s=setup();s.set(false);s.set(false);
  assert.equal(s.window.scrollY,1600);assert.equal(s.scrolls.length,0);
});
test('active drag restores its pickup position once, then idle cleanup preserves later scrolling',()=>{
  const s=setup();s.set(true,1600);assert.equal(s.document.body.style.position,'fixed');
  s.window.scrollY=0;s.set(false);assert.equal(s.window.scrollY,1600);assert.equal(s.scrolls.length,1);
  s.window.scrollY=2400;s.set(false);assert.equal(s.window.scrollY,2400);assert.equal(s.scrolls.length,1);
});
