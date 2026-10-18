require_relative '../../support/mille_bornes'
include MilleBornesTest

fixture = Fixture.new
reads = []
original = fixture.game.method(:replay)
fixture.game.define_singleton_method(:replay) do |session, events, repository|
  reads << events.length
  original.call(session, events, repository)
end

before = fixture.start
equal([0, 1], reads, 'default helper still rebuilds before and after a write')
reads.clear
after = fixture.act('Alice', {'kind' => 'command', 'action' => 'draw'}, before: before)
equal([2], reads, 'provided current prefix still performs a full replay of every event after the action')
equal(2, after.accepted_events.length, 'draw was accepted by the real replay')

[before, after.dup.tap { |replay| replay.session_identity = 99 }].each do |stale|
  events = JSON.generate(fixture.events)
  reads.clear
  begin
    fixture.act('Alice', fixture.game.legal_actions(after, 'Alice').first, before: stale)
    raise 'stale provided replay was not refused'
  rescue RuntimeError => error
    equal('provided replay is not the current event prefix', error.message, 'only the intended precondition failed')
  end
  equal(events, JSON.generate(fixture.events), 'stale prefix did not append an event')
  equal([], reads, 'stale prefix was refused before planning or replay')
end

reads.clear
selection = fixture.game.legal_actions(after, 'Alice').first
final = fixture.act('Alice', selection, before: after)
equal([3], reads, 'rejected helper call did not spoil the subsequent full replay')
equal(3, final.accepted_events.length, 'normal next action still accepted')
reads.clear
equal(final.state, fixture.replay.state, 'separate cold reconstruction agrees')
equal([3], reads, 'the explicit replay remains a cold read')
puts 'PASS Mille fixture replay reuse: one full log reconstruction per action, stale/session refusal and unchanged default'
