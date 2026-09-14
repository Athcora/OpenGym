import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../app/WaitlistApp.tsx',import.meta.url),'utf8');
const i18n=await readFile(new URL('../app/i18n.ts',import.meta.url),'utf8');
const advancedCss=await readFile(new URL('../app/advanced.css',import.meta.url),'utf8');

assert.match(app,/You do not need to sign up again\. You stay in line until you leave or move out of range of the facility\./);
assert.match(app,/Every time after you play, you MUST rejoin within five minutes to keep your place\./);
assert.doesNotMatch(app,/Only current-game players can press Next Game/);
assert.match(app,/Sit Out makes you skip one game\. After skipping that game, you receive priority for the following game\./);
assert.match(app,/Leave removes only you from the waitlist, so use it when you do not want to play anymore\./);
assert.match(app,/The players in this section are in the current game\. Only they are able to start the next game\./);
assert.doesNotMatch(app,/Everyone else keeps their order/);
assert.doesNotMatch(app,/Only they—and admins—can start the next game/);
assert.match(app,/After you play, you will be taken off the waitlist\. To keep your saved place, press Rejoin within five minutes\./);
assert.match(app,/className="next tutorial-rejoin-highlight"/);
assert.doesNotMatch(app,/className="admin-sitout-button">Sit out</);
assert.doesNotMatch(app,/className="neutral">Sit out</);
assert.match(advancedCss,/\.tutorial-rejoin-demo \{[^}]*top:max\(18px[^}]*bottom:auto/);
assert.match(app,/tutorial-rejoin-tour/);
assert.match(app,/className="tutorial-rejoin-arrow"[^>]*>↑<\/span>/);
assert.match(advancedCss,/\.tutorial-rejoin-arrow\{[^}]*padding-left:25%/);
assert.match(advancedCss,/\.court-team-rule\.tutorial-focus\{[^}]*width:100%[^}]*padding:8px 14px/);
assert.match(app,/keeping your spot for the following game/);
assert.match(app,/tutorial-host-demo queue-page/);
assert.match(app,/admin-tools host-tools single-court-tools/);
assert.match(app,/teams\?'teams-tools':'standard-tools'/);
assert.doesNotMatch(app,/youâ€™ll/);

for(const text of [
  'Sit Out makes you skip one game. After skipping that game, you receive priority for the following game.',
  'Leave removes only you from the waitlist, so use it when you do not want to play anymore.',
  'The players in this section are in the current game. Only they are able to start the next game.',
  'Rejoin after every game',
  'After you play, you will be taken off the waitlist. To keep your saved place, press Rejoin within five minutes.',
]){
  assert.equal(i18n.split(`'${text}'`).length-1,2,`expected Spanish and Chinese translations for: ${text}`);
}

console.log('tutorial copy and translations passed');
