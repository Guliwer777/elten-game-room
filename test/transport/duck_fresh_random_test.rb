require_relative '../support/session_runner'
require_relative '../support/elten_array_shuffle'
require_relative '../../games/duck_racing'
require_relative '../support/duck_game_adapter'

logic = GameRoomDuckRacing
game = GameRoomGames::DuckRacing.new
%w[dice_duel risky_dice].each do |kind|
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob], options: game.default_options.merge('challenges'=>[kind]))
  h.start
  context = ->(user) { GameRoomGames::ActionContext.new(session_id:h.session['__id'], table_id:h.table['__id'],
    now:Time.now.to_f, table_owner:h.core.owner, random_source:GameRoomRandom::LocalSecureSource.new,
    local_data:{'duck_host'=>user == h.core.owner}) }
  seed = (0..1000).find do |value|
    race = logic::Race.start(player_count:2,laps:3,enabled_challenges:[kind],seed:value)
    race[:racers][race[:turn]][:hand].any? { |card| card.type == 'super_challenge' }
  end
  h.view('Alice').next_random_values = Array.new(16) { |i| ((seed >> (8 * (15-i))) & 255) + 1 }
  h.submit('Alice', {'action'=>'start'}, context:context.call('Alice'))
  replay = h.replay('Alice')
  actor = replay.current_player
  card = replay.state[:race][:racers][replay.state[:race][:turn]][:hand].find { |c| c.type == 'super_challenge' }
  h.submit(actor, {'action'=>'race','input'=>{'kind'=>'play','card'=>card.id,'target'=>replay.state[:race][:turn]}}, context:context.call(actor))
  h.users.each do |user|
    s = h.replay(user).state
    h.submit(user, {'action'=>'ready','challenge'=>s[:round][:challenge][:id],'fingerprint'=>s[:fingerprint]}, context:context.call(user))
  end
  s = h.replay('Alice').state
  assert(s[:round][:phase] == :playing, 'challenge did not begin')
  seat = logic::ChallengeEngine.current_turn(s[:round][:engine])
  actor = h.users[seat]
  selected = {'action'=>'input', 'challenge'=>s[:round][:challenge][:id], 'input'=>{'kind'=>'roll','press_id'=>1}}
  h.view(actor).next_random_values = Array.new(16, 72)
  before = h.view(actor).calls[:random]
  h.submit(actor, selected, context:context.call(actor))
  assert(h.view(actor).calls[:random] == before + 1, 'roll did not use one server request')
  snapshots = h.users.map { |user| DuckGameAdapterTest.semantic(h.replay(user)) }
  differences = snapshots.first.last.keys.select { |key| snapshots.map { |state| state.last[key] }.uniq.size > 1 }
  assert(differences.empty?, "#{kind}: #{differences.map { |key| [key, snapshots.map { |s| s.last[key] }] }.inspect}")
  state = h.replay(actor).state
  rolls = state.dig(:round,:engine,:model,:players,seat,:rolls)
  if rolls
    seed = Array.new(16, 71).reduce(0) { |sum,v| sum * 256 + v }
    expected = Random.new(seed).rand(6) + 1
    assert(rolls.last.first == expected, 'challenge ignored fresh receipt')
  end
  # A plain client payload cannot smuggle a chosen replacement seed.
  before = h.core.entries.size
  data = nil
  GameRoomActionPayload.each(h.events(actor), game.id, h.repositories[actor], h.session) { |row, _, _| data = row if row['action'] == 'input' }
  begin
    h.write(actor, GameRoomActionPayload.commands(game.id, data.merge('seed'=>0)))
    raise 'client-authored roll accepted'
  rescue ArgumentError => error
    raise unless error.message.include?('server draw')
  end
  assert(h.core.entries.size == before, 'forged roll wrote a record')
  next unless kind == 'dice_duel'

  previous = h.replay('Alice').state[:round]
  expire_at = previous[:started_at] + previous[:engine][:model][:deadline_ms] + 1
  h.view('Alice').next_random_values = Array.new(16, 102)
  before = h.view('Alice').calls[:random]
  ctx = context.call('Alice')
  ctx.now = expire_at / 1000.0
  h.submit('Alice', {'action'=>'advance', 'challenge'=>previous[:challenge][:id]}, context:ctx)
  assert(h.view('Alice').calls[:random] == before + 1, 'automatic roll did not request fresh entropy')
  packets = []
  GameRoomActionPayload.each(h.events('Alice'),game.id,h.repositories['Alice'],h.session) do |row, _, batch|
    packets << [row,batch] if row['action'] == 'advance'
  end
  data, batch = packets.last
  expected_seed = Array.new(16,101).reduce(0) { |sum,v| sum * 256 + v }
  assert(data['seed'] == expected_seed && batch.any? { |row| row['__server_random'] }, 'automatic roll lost receipt')
  engine = logic::Session.copy(previous[:engine])
  seat = logic::ChallengeEngine.current_turn(engine)
  generator = Random.new(expected_seed)
  streams = engine[:participants].to_h { |member| [member,Random.new(generator.rand(1 << 128))] }
  expected = streams.fetch(seat).rand(engine[:model][:dice].fetch(seat)[:die_sides]) + 1
  logic::ChallengeEngine.expire(engine, now_ms:expire_at - previous[:started_at], seed:expected_seed)
  assert(engine[:model][:players].fetch(seat)[:rolls].last == [expected], 'automatic roll used old public seed')
  snapshots = h.users.map { |user| DuckGameAdapterTest.semantic(h.replay(user)) }
  assert(snapshots.uniq.size == 1, 'automatic roll diverged')
end
puts 'PASS Duck Racing: independent action and challenge-roll receipts, single request, native authentication and convergence'
