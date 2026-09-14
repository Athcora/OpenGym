import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const layout=fs.readFileSync(new URL('../app/layout.tsx',import.meta.url),'utf8');
const globals=fs.readFileSync(new URL('../app/globals.css',import.meta.url),'utf8');

test('production fonts never depend on build-machine file URLs',()=>{
  assert.doesNotMatch(layout,/next\/font/);
  assert.doesNotMatch(layout,/geistSans|geistMono/);
  assert.match(globals,/--font-sans: Inter, ui-sans-serif, system-ui/);
});
