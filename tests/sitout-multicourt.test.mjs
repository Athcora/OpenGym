import assert from 'node:assert/strict'

const COURT_SIZE = 12

function fillCourt(waiting, court) {
  while (court.players.length < COURT_SIZE && waiting.length) {
    waiting.sort((a, b) => Number(b.priority) - Number(a.priority) || a.position - b.position)
    court.players.push(waiting.shift())
  }
}

function runScenario(courtCount, waitingCount) {
  const courts = Array.from({ length: courtCount }, (_, index) => ({
    number: index + 1,
    game: 101 + index,
    players: Array.from({ length: COURT_SIZE }, (_, seat) => ({
      id: `court-${index + 1}-${seat + 1}`,
      position: index * COURT_SIZE + seat + 1,
      priority: false,
    })),
  }))
  const waiting = Array.from({ length: waitingCount }, (_, index) => ({
    id: `waiting-${index + 1}`,
    position: courtCount * COURT_SIZE + index + 1,
    priority: false,
  }))
  const sittingOut = []

  // One player from every active court sits out. Their marker must use that
  // court's game, never the maximum global game number.
  for (const court of courts) {
    const player = court.players.shift()
    sittingOut.push({ ...player, priority: true, skippedGame: court.game })
    fillCourt(waiting, court)
    assert.equal(court.players.length, COURT_SIZE)
  }

  for (const court of courts) {
    // Ending this court releases every completed sit-out before its 12 newly
    // open seats are filled. Priority players must be selected first.
    const released = sittingOut.filter(player => player.skippedGame <= court.game)
    for (const player of released) {
      waiting.push(player)
      sittingOut.splice(sittingOut.indexOf(player), 1)
    }
    court.players = []
    fillCourt(waiting, court)
    assert.equal(court.players.length, COURT_SIZE)
    if (released.length) {
      assert.ok(released.every(player => court.players.some(chosen => chosen.id === player.id)))
    }
  }

  return { courts, waiting, sittingOut }
}

for (const courtCount of [1, 2, 3, 6, 12]) {
  const result = runScenario(courtCount, 240)
  assert.equal(result.courts.length, courtCount)
  assert.ok(result.courts.every(court => court.players.length === COURT_SIZE))
  assert.equal(result.sittingOut.length, 0)
}

console.log('sit-out multi-court stress test passed (1, 2, 3, 6, and 12 courts; 240 waiting players)')
