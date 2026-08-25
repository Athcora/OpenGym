import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const i18n=await readFile(new URL('../app/i18n.ts',import.meta.url),'utf8');

assert.match(app,/You do not need to sign up again\. You stay in line until you leave or move out of range of the facility\./);
assert.match(app,/\{rejoin&&<> <strong>\{permission\}<\/strong><\/>\}/);
assert.match(app,/Sit Out makes you skip one game\. After skipping that game, you receive priority for the following game\./);
assert.match(app,/Leave removes only you from the waitlist, so use it when you do not want to play anymore\./);
assert.match(app,/The players in this section are in the current game\. Only they are able to start the next game\./);
assert.doesNotMatch(app,/Everyone else keeps their order/);
assert.doesNotMatch(app,/Only they—and admins—can start the next game/);

for(const text of [
  'Sit Out makes you skip one game. After skipping that game, you receive priority for the following game.',
  'Leave removes only you from the waitlist, so use it when you do not want to play anymore.',
  'The players in this section are in the current game. Only they are able to start the next game.',
]){
  assert.equal(i18n.split(`'${text}'`).length-1,2,`expected Spanish and Chinese translations for: ${text}`);
}

console.log('tutorial copy and translations passed');
