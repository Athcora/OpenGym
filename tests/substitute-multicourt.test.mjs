import assert from 'node:assert/strict'

function swapPlacement(first, second) {
  const fields = ['status', 'position', 'court', 'sitoutPriority', 'sitoutFromGame']
  for (const field of fields) [first[field], second[field]] = [second[field], first[field]]
}

for (let firstCourt = 1; firstCourt <= 12; firstCourt += 1) {
  for (let secondCourt = 1; secondCourt <= 12; secondCourt += 1) {
    const first = { status: 'current', position: firstCourt * 12, court: firstCourt, sitoutPriority: false, sitoutFromGame: null }
    const second = { status: 'current', position: (secondCourt - 1) * 12 + 1, court: secondCourt, sitoutPriority: false, sitoutFromGame: null }
    const originalFirst = { ...first }
    const originalSecond = { ...second }
    swapPlacement(first, second)
    assert.deepEqual(first, originalSecond)
    assert.deepEqual(second, originalFirst)
  }
}

const courtPlayer = { status: 'current', position: 24, court: 2, sitoutPriority: false, sitoutFromGame: null }
const waitingPlayer = { status: 'waiting', position: 37, court: null, sitoutPriority: false, sitoutFromGame: null }
swapPlacement(courtPlayer, waitingPlayer)
assert.deepEqual(courtPlayer, { status: 'waiting', position: 37, court: null, sitoutPriority: false, sitoutFromGame: null })
assert.deepEqual(waitingPlayer, { status: 'current', position: 24, court: 2, sitoutPriority: false, sitoutFromGame: null })

const sittingOut = { status: 'sitout', position: 42, court: null, sitoutPriority: true, sitoutFromGame: 9 }
const courtThree = { status: 'current', position: 31, court: 3, sitoutPriority: false, sitoutFromGame: null }
swapPlacement(sittingOut, courtThree)
assert.deepEqual(courtThree, { status: 'sitout', position: 42, court: null, sitoutPriority: true, sitoutFromGame: 9 })
assert.deepEqual(sittingOut, { status: 'current', position: 31, court: 3, sitoutPriority: false, sitoutFromGame: null })

function groupRemainsContiguous(positions, statuses, courts) {
  return new Set(statuses).size === 1 && new Set(courts.map(value => value ?? 0)).size === 1 && Math.max(...positions) - Math.min(...positions) + 1 === positions.length
}

assert.equal(groupRemainsContiguous([13, 14, 15], ['waiting', 'waiting', 'waiting'], [null, null, null]), true)
assert.equal(groupRemainsContiguous([14, 15, 17], ['waiting', 'waiting', 'waiting'], [null, null, null]), false)
assert.equal(groupRemainsContiguous([11, 12, 13], ['current', 'current', 'waiting'], [1, 1, null]), false)

console.log('substitute multi-court stress test passed (all 144 court pairs, court/waitlist, sit-out, and group separation)')
