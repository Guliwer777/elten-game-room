require_relative '../support/session_runner'
require_relative '../support/elten_array_shuffle'
%w[domino mexican_train rummy scrabble taboo].each { |name| require_relative "../../games/#{name}" }

class NoPayloadEntropy
  def roll(**); raise 'Payload deal used local entropy'; end
end

[GameRoomGames::Domino, GameRoomGames::MexicanTrain, GameRoomGames::Rummy,
 GameRoomGames::Scrabble, GameRoomGames::Taboo].each do |klass|
  game = klass.new
  h = NativeRoomHarness.new(game: game)
  h.start
  ctx = GameRoomGames::ActionContext.new(random_source: NoPayloadEntropy.new, server_random: true,
    table_owner: 'Alice', now: Time.now.to_i)
  h.view('Alice').next_random_values = (1..16).to_a
  h.submit('Alice', game.automatic_action(h.replay('Alice'), 'Alice', context: ctx), context: ctx)
  h.assert_converged(game.id)
  events = h.events('Alice')
  assert(!events.empty? && h.replay('Alice').accepted_events.length == events.length, "#{game.id}: partial or rejected deal")
  assert(h.view('Alice').calls[:random] == 1, "#{game.id}: extra draw")
  assert(events.map { |e| e['move_id'] }.uniq.size == events.size, 'expanded fragments share an ID')
  legacy = events.map { |e| e.reject { |k, _| k == '__server_random' } }
  old = game.replay(h.session, legacy, h.repositories['Alice'])
  assert(GameRoomTest::ReplaySnapshot.capture(old).except(:accepted_events) ==
    GameRoomTest::ReplaySnapshot.capture(h.replay('Alice')).except(:accepted_events), "#{game.id}: archive dialect changed")
  # Plain client packets cannot substitute another shuffle, including the
  # compressed multi-fragment dialect used by these games.
  other = NativeRoomHarness.new(game: game)
  other.start
  before = other.core.entries.size
  begin
    other.write('Alice', legacy)
    raise "#{game.id}: accepted a client-authored deal"
  rescue ArgumentError => error
    raise unless error.message.include?('server draw')
  end
  assert(other.core.entries.size == before, 'rejected deal sent')

  if game.id == 'scrabble'
    current = h.replay('Alice').current_player
    rack = h.replay(current).state[:racks][current]
    h.view(current).next_random_values = Array.new(16, 5)
    h.submit(current, {'action'=>'exchange', 'tiles'=>[rack.first]}, context: ctx)
    h.assert_converged('server rack exchange')
    assert(h.view(current).calls[:random] == (current == 'Alice' ? 2 : 1), 'exchange not random')
  end
end

# A lost reply to a fragment-producing draw must recover that one request.
h = NativeRoomHarness.new(game: GameRoomGames::Rummy.new, users: %w[Alice Bob])
h.start
runner = runner_for(h)
h.broker.automatic_delivery = false
h.view('Alice').next_random_values = Array.new(16, 17)
h.view('Alice').fail_next_push = :after
begin
  h.as('Alice') do
    runner.submit(session: h.session, replay: h.replay('Alice'),
      selection: {'action'=>'deal'}, actor: 'Alice')
  end
rescue EltenAPI::LiveSessions::TimeoutError
end
h.transports['Alice'].reconcile(h.table['__id'])
h.broker.automatic_delivery = true
h.broker.deliver
step(h, runner)
h.assert_converged('lost payload reply')
assert(h.core.entries.count { |row| row['origin'] == 'server' } == 1,
  "payload recovery: #{h.core.entries.map { |row| [row['origin'], row.dig('packet', 'kind')] }.inspect}; #{h.replay('Alice').state[:phase]}")
assert(h.replay('Alice').accepted_events.size == h.events('Alice').size, 'partial payload confirmation')
runner.close
puts 'PASS server payloads: five games, atomic expansion, archive replay, exchange and lost acknowledgement'
