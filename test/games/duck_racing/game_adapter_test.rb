require 'fileutils'
require_relative '../../support/duck_game_adapter'
include DuckGameAdapterTest

checks = []
check = lambda do |name, &block|
  next if ENV['DUCK_ADAPTER_CASE'] && !name.include?(ENV['DUCK_ADAPTER_CASE'])
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  entry = {name: name, status: 'PASS'}
  begin
    block.call
  rescue StandardError => error
    entry.merge!(status: 'FAIL', error: "#{error.class}: #{error.message}", location: error.backtrace.first(4))
  ensure
    entry[:seconds] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(4)
    checks << entry
  end
end

check.call('options preserve stable selected IDs, language defaults and empty/unknown validation') do
  game = Harness.new.game
  defaults = game.default_options
  assert_equal(['quiz.wikidata'], defaults['question_sets'])
  assert_equal(LOGIC::Challenges::BY_ID.keys.sort, defaults['challenges'])
  ['pl-PL', 'en', 'ru-RU'].each do |language|
    normalized = game.normalize_options('question_language' => language)
    assert_equal(LOGIC::QuestionSets.defaults(language), normalized['question_sets'])
    assert_equal(nil, game.validation_error(normalized, player_count: 4))
  end
  selected = game.normalize_options('question_sets' => ['quiz.witcher.books.pl', 'quiz.wikidata'])
  assert_equal(['quiz.wikidata', 'quiz.witcher.books.pl'], selected['question_sets'])
  assert_equal(selected, game.options_from_json(JSON.generate(selected)))
  assert(game.validation_error(game.normalize_options('question_sets' => ['missing']), player_count: 2))
  assert(game.validation_error(game.normalize_options('challenges' => []), player_count: 2))
  assert(game.validation_error(game.normalize_options('challenges' => ['rock_paper_scissors']), player_count: 4))
  assert_equal(nil, game.validation_error(game.normalize_options('challenges' => ['copy_number']), player_count: 8))
  assert(game.validation_error(game.normalize_options('laps' => 0), player_count: 2))
  assert(game.validation_error(game.normalize_options('laps' => 11), player_count: 2))
  assert_equal({'question_sets' => LOGIC::QuestionSets.defaults('en')},
    game.option_editor_changes(defaults, defaults.merge('question_language' => 'en')))
  assert_equal({}, game.option_editor_changes(defaults, defaults.dup))
  invalid = GameRoomGames::DuckRacing.new
  assert(invalid.validation_error(invalid.normalize_options('question_sets' => []), player_count: 2),
    'No questions selected silently fell back to a set')
end

[2, 3, 4, 8].each do |count|
  check.call("#{count} players: action plans, full codec replay, private answers and quiet projections") do
    h = Harness.new(count: count)
    h.open_round
    initial = h.replay
    assert_equal(Array.new(count, 18), initial.state[:race][:racers].values.map { |racer| racer[:feathers] })
    assert_equal(count * 3 - 1, initial.state[:race][:racers].values.sum { |racer| racer[:hand].length })
    assert(h.game.save_game_error(initial), 'A challenge was allowed in a normal archive')
    h.begin_round
    before = h.replay
    protocol = before.state[:round][:private]
    foreign = h.game.action_for({'action' => 'ready', 'challenge' => before.state[:round][:challenge][:id]}, before,
      'Outsider', context: h.context('Outsider'))
    assert_equal(:not_your_turn, foreign.first)
    assert_equal({}, protocol[:reveals])
    assert_equal({}, protocol[:commitments])
    id = h.finish_private
    replay = h.replay
    assert_equal(count, replay.state[:last_resolution][:results].length)
    assert_equal(h.events, replay.accepted_events, 'Some completed action fragments were lost')
    assert_equal(DuckGameAdapterTest.semantic(replay), DuckGameAdapterTest.semantic(h.replay), 'Replay is not deterministic')
    assert_equal(0, replay.state[:last_resolution][:settlement].winner)
    assert_equal('guess_number', replay.state[:last_resolution][:kind])
    assert_equal(:invalid, h.plan({'action' => 'advance', 'challenge' => id}, author: h.owner).first,
      'A resolved challenge accepted a delayed advance')
    snapshot = Marshal.dump([h.session, h.events])
    assert_equal(nil, h.game.local_client)
    h.game.surface_spec(replay, 'Watcher')
    h.game.custom_game_shortcuts(replay, h.players.first)
    assert_equal(snapshot, Marshal.dump([h.session, h.events]), 'Presentation changed durable data')
    assert(h.decode.all? { |data, _actor, _batch| data['session'] == h.session['__id'] },
      'Adapter did not record the physical session in every logical action')
  end
end

check.call('codec rejects partial, corrupt, reordered and cross-author fragments without changing replay') do
  h = Harness.new
  plan = h.start
  baseline = DuckGameAdapterTest.semantic(h.replay)
  original = Marshal.load(Marshal.dump(h.events))
  assert(h.events.length > 1, 'Fixture must really span several EventCommands')
  missing = h.events[0...-1]
  corrupt = Marshal.load(Marshal.dump(h.events))
  corrupt.last['value'] = corrupt.last['value'].sub(/.$/, '?')
  switched = Marshal.load(Marshal.dump(h.events))
  switched.last['__insertion_user'] = 'Bob'
  [missing, corrupt, switched, h.events.reverse].each do |events|
    replay = h.game.replay(h.session, events, h.repository)
    assert_equal(nil, replay.state[:race])
    assert_equal([], replay.accepted_events)
  end
  duplicate = h.game.replay(h.session, h.events + h.events, h.repository)
  assert_equal(baseline, DuckGameAdapterTest.semantic(duplicate), 'Duplicate event IDs applied a second action')
  assert_equal(original, h.events)
end

check.call('author and moderator authentication including spectator host and illegal claimed controller') do
  h = Harness.new(owner: 'Watcher')
  assert_equal('Alice', h.host_actor)
  assert_equal(:invalid, h.plan({'action' => 'start'}, actor: 'Alice').first, 'Ordinary player started without the host')
  h.start
  assert_equal('Watcher', h.events.first['__insertion_user'])
  assert_equal(true, h.events.first['__controller'])
  assert_equal('Alice', h.repository.actor_of(h.events.first, h.session))
  assert_equal(h.events, h.replay.accepted_events)
  forged = h.events.map { |event| event.merge('__insertion_user' => 'Intruder') }
  assert_equal([], h.game.replay(h.session, forged, h.repository).accepted_events,
    'Non-owner controlled another participant through a forged actor')
  forged = h.events.map { |event| event.merge('__controller' => false, '__insertion_user' => 'Bob', 'actor' => 'Alice') }
  assert_equal([], h.game.replay(h.session, forged, h.repository).accepted_events,
    'A claimed actor overrode authenticated author for moderation')
  assert_equal(:not_your_turn, h.plan({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Watcher').first)
  assert_equal(:invalid, h.plan({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Bob').first)
end

check.call('participant wrapper cancels affected private challenge and preserves immutable historical authors') do
  h = Harness.new(count: 3)
  h.open_round
  h.begin_round
  old_round = h.replay.state[:round]
  trace = h.private_traces.fetch(1)
  h.accept({'action' => 'submit_trace', 'challenge' => old_round[:challenge][:id], 'trace' => trace}, actor: 'Bob')
  before = Marshal.load(Marshal.dump(h.events))
  h.replace(1, 'Replacement')
  replay = h.replay
  assert_equal(:participant_changed, replay.state[:last_resolution][:cancelled])
  assert_equal(old_round[:balances], replay.state[:race][:racers].transform_values { |racer| racer[:feathers] })
  assert_equal(before, h.events, 'Participant replay rewrote accepted historical events')
  assert_equal(h.events, replay.accepted_events)
  assert_equal('Replacement', replay.players[1])
  assert_equal(nil, replay.state[:round])
  assert_equal(:not_your_turn, h.plan({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Bob').first)
  assert_equal(:invalid, h.plan({'action' => 'ready', 'challenge' => old_round[:challenge][:id],
    'fingerprint' => h.resources[:fingerprint]}, actor: 'Replacement').first)
  assert(replay.history.any? { |entry| entry.text.include?('Bob') }, 'Historical public text lost its original player')
end

check.call('replacing a nonparticipant does not cancel an unrelated two-player challenge') do
  h = Harness.new(count: 3)
  h.open_round(group: false)
  h.begin_round
  before = DuckGameAdapterTest.semantic(h.replay.state[:round])
  h.replace(2, 'Replacement')
  assert_equal(before, DuckGameAdapterTest.semantic(h.replay.state[:round]))
  assert_equal(nil, h.replay.state[:last_resolution])
  h.finish_private
end

check.call('host transfer during private answers preserves the round and rejects former moderator') do
  h = Harness.new
  h.open_round
  h.begin_round
  before = DuckGameAdapterTest.semantic(h.replay.state[:round])
  h.owner = 'Bob'
  assert_equal(before, DuckGameAdapterTest.semantic(h.replay.state[:round]))
  id = h.replay.state[:round][:challenge][:id]
  assert_equal(:invalid, h.plan({'action' => 'advance', 'challenge' => id}, actor: 'Alice').first)
  h.finish_private
  assert_equal(h.events, h.replay.accepted_events)
end

check.call('ordinary race hand exposes only own cards and preserves stable physical card IDs') do
  h = Harness.new(count: 4)
  h.start
  replay = h.replay
  all = replay.state[:race][:racers].values.flat_map { |racer| racer[:hand].map(&:id) }
  assert_equal(all.length, all.uniq.length)
  h.players.each_with_index do |user, seat|
    own = replay.state[:race][:racers][seat][:hand].map(&:id)
    spec = h.game.surface_spec(replay, user)
    hand = spec.parts.first.surface.zones.first
    assert_equal(own, hand.cards.map(&:id))
    assert_equal(own, hand.hand_order)
    assert_equal([], hand.cards.map(&:id) & (all - own), 'Another hand leaked into the viewer surface')
  end
  assert(!h.game.surface_spec(replay, 'Watcher').inspect.match?(/duck-card-/), 'Observer surface leaked a hand')
end

check.call('all 37 card and 30 board descriptions format and empty/preparing/finished surfaces are usable') do
  h = Harness.new
  assert(h.game.surface_spec(h.replay, 'Alice'))
  h.start
  replay = h.replay
  baseline = DuckGameAdapterTest.semantic(replay)
  descriptions = LOGIC::Cards::BY_ID.keys.map { |type| h.game.card_description(type) }
  assert_equal(37, descriptions.length)
  assert(descriptions.all? { |description| !description.empty? && !description.include?('%{') })
  (1..30).each do |square|
    description = h.game.square_text(replay, square)
    assert(description.include?(square.to_s) && !description.include?('%{'), 'Unformatted board description')
  end
  assert(h.game.custom_game_shortcuts(replay, 'Alice').any? { |shortcut| shortcut.key == 'v' })
  ended = Marshal.load(Marshal.dump(replay))
  ended.winner = 'Alice'
  assert(h.game.surface_spec(ended, 'Watcher'))
  assert_equal(baseline, DuckGameAdapterTest.semantic(replay), 'Description construction changed the race')
end

check.call('surface selections for each naturally dealt card use real target IDs and produce accepted plans') do
  LOGIC::Cards::BY_ID.each_key do |type|
    h = Harness.new(count: 4, options: {'laps' => 10})
    h.start(seed: h.seed_for(type))
    replay = h.replay
    hand = h.game.surface_spec(replay, 'Alice').parts.first.surface.zones.first
    physical = replay.state[:race][:racers][0][:hand].find { |card| card.type == type }
    card = hand.cards.find { |entry| entry.id == physical.id }
    values = card.choices.empty? ? [card.value] : card.choices.map(&:value)
    assert(!values.empty?, "No surface action for #{type}")
    values.each do |value|
      action = GameSurfaces::Action.new(kind: 'card', name: 'select', payload: {'card' => value})
      status, plan = h.game.action_for(action, replay, 'Alice', context: h.context('Alice'))
      assert_equal(:ok, status, "Surface produced an invalid #{type} selection: #{value}")
      events_before = Marshal.load(Marshal.dump(h.events))
      h.append(plan, actor: 'Alice')
      assert_equal(h.events.length, h.replay.accepted_events.length)
      h.events.replace(events_before)
    end
  end
end

check.call('spectator host can begin and close private answers without gaining a player seat') do
  h = Harness.new(count: 4, owner: 'Watcher')
  h.open_round
  h.begin_round
  assert_equal(nil, h.game.required_decision_key(h.replay, 'Watcher'))
  assert(!h.game.active_actors(h.replay).include?('Watcher'))
  h.finish_private
  assert_equal(4, h.replay.state[:last_resolution][:results].length)
  assert_equal(4, h.replay.players.length)
  assert_equal(h.events.length, h.replay.accepted_events.length)
end

check.call('archive validates without a live session ID then restores completed private round to a NEW session') do
  h = Harness.new
  h.open_round
  h.begin_round
  h.finish_private
  previous = h.reach_save_boundary
  saves, row = h.archive
  native, restored = h.restore_native(saves, row)
  after = native.replay(h.owner)
  new_session = native.session
  assert(new_session['__id'] != h.session['__id'], 'The archive did not create a different physical session')
  assert_equal(new_session['__id'], after.state[:session_id])
  assert_equal(restored[:events].length, after.accepted_events.length)
  assert(native.events(h.owner).all? { |event| event['__controller'] == true && event['move_id'].start_with?('archive:') },
    'The test bypassed the native archive import authentication path')
  assert_equal(DuckGameAdapterTest.semantic(previous.state[:race]), DuckGameAdapterTest.semantic(after.state[:race]))
  assert_equal(DuckGameAdapterTest.semantic(previous.state[:last_resolution]), DuckGameAdapterTest.semantic(after.state[:last_resolution]))
  assert(h.decode.any? { |data, _actor, _events| data['action'] == 'begin' && data['session'] == 91 })
  actor = after.current_player
  context = h.context(actor)
  context.session_id = new_session['__id']
  context.table_id = native.table['__id']
  context.now += 2
  status, plan = h.game.action_for({'action' => 'race', 'input' => {'kind' => 'roll'}}, after, actor, context: context)
  assert_equal(:ok, status, 'The restored session could not continue')
  native.write(actor, plan.events)
  continued = native.replay(h.owner)
  assert_equal(after.accepted_events.length + plan.events.length, continued.accepted_events.length)
  decoded = []
  GameRoomActionPayload.each(native.events(h.owner).last(plan.events.length), h.game.id,
    native.repositories.fetch(h.owner), new_session) { |data, *_| decoded << data }
  assert_equal([new_session['__id']], decoded.map { |data| data['session'] })
  native.assert_converged('restored private challenge and next real action')
end

check.call('archive preserves moderator decisions after a transfer to a non-first player') do
  h = Harness.new
  h.open_round
  h.begin_round
  h.owner = 'Bob'
  h.finish_private
  previous = h.reach_save_boundary
  saves, row = h.archive
  native, restored = h.restore_native(saves, row)
  after = native.replay(h.owner)
  assert_equal(restored[:events].length, after.accepted_events.length)
  assert_equal(DuckGameAdapterTest.semantic(previous.state[:race]), DuckGameAdapterTest.semantic(after.state[:race]))
  assert_equal(DuckGameAdapterTest.semantic(previous.state[:last_resolution]), DuckGameAdapterTest.semantic(after.state[:last_resolution]))
  native.assert_converged('restored transferred moderator decisions')
end

check.call('new private challenge after native restore uses its NEW physical session scope') do
  h = Harness.new
  h.open_round
  h.begin_round
  old_protocol = h.replay.state[:round][:private]
  h.finish_private
  h.reach_save_boundary
  native, = h.restore_native(*h.archive)
  now = h.now_ms + 1_000
  160.times do
    current = native.replay(h.owner)
    break if current.state[:round]
    assert(!current.finished?, 'The fixture finished before opening the next challenge')
    racer = current.state[:race][:racers].fetch(current.state[:race][:turn])
    if racer[:frozen_turns].positive? || racer[:skip_turns].positive?
      selection = {'action' => 'race', 'input' => {'kind' => 'skip'}}
      actor = h.owner
    else
      actor = current.current_player
      actions = h.game.legal_actions(current, actor)
      selection = actions.find do |action|
        card = racer[:hand].find { |copy| copy.id == action.dig('input', 'card') }
        card && %w[challenge super_challenge].include?(card.type)
      end || {'action' => 'race', 'input' => {'kind' => 'roll'}}
    end
    native.submit_at(selection, actor: actor, at: now += 100)
  end
  round = native.replay(h.owner).state[:round]
  assert(round, 'No deterministic challenge opened after restore')
  id = round[:challenge][:id]
  round[:challenge][:participants].each do |seat|
    actor = native.replay(h.owner).players.fetch(seat)
    native.submit_at({'action' => 'ready', 'challenge' => id, 'fingerprint' => h.resources[:fingerprint]},
      actor: actor, at: now += 100)
  end
  native.submit_at({'action' => 'begin', 'challenge' => id}, actor: h.owner, at: now += 100)
  protocol = native.replay(h.owner).state[:round][:private]
  assert(protocol, 'The restored fixture opened a non-private challenge')
  assert_equal(native.session.fetch('__id'), protocol[:session_id])
  assert(protocol[:session_id] != old_protocol[:session_id] && protocol[:tag] != old_protocol[:tag],
    'New challenge reused the old commitment scope')
  assert_equal(nil, LOGIC::PrivateRound.recover(protocol, seat: 0, user: 'Alice', vault: h.vault('Alice')),
    'Old locally saved trace became a response to the new challenge')
  native.assert_converged('new private challenge after restore')
  native.submit_at({'action' => 'cancel', 'challenge' => id, 'reason' => 'technical'},
    actor: native.replay(h.owner).players.fetch(round[:challenge][:participants].first), at: now += 100)
end

check.call('native human to bot to observer replacement preserves hand/history then survives a second archive') do
  h = Harness.new
  h.open_round
  h.begin_round
  h.finish_private
  h.reach_save_boundary
  native, = h.restore_native(*h.archive)
  original = native.replay('Alice')
  old_events = Marshal.load(Marshal.dump(native.events('Alice')))
  old_hand = original.state[:race][:racers][1][:hand]
  native.add_client('Watcher')
  assert(native.join('Watcher'))
  native.users << 'Watcher'
  native.as('Alice') do
    native.transports['Alice'].set_observer(native.table, true, actor: 'Alice', subject: 'Watcher')
    native.transports['Alice'].replace_game_player(native.table, session_id: native.session['__id'], player: 'Bob')
  end
  replaced = native.replay('Alice')
  bot = replaced.players.fetch(1)
  assert(GameRoomParticipants.bot?(bot), 'Replacement did not create a physical bot')
  assert_equal(old_hand, replaced.state[:race][:racers][1][:hand])
  native.as('Alice') do
    native.transports['Alice'].replace_game_player(native.table, session_id: native.session['__id'],
      player: bot, replacement: 'Watcher')
  end
  current = native.replay('Alice')
  assert_equal(%w[Alice Watcher], current.players)
  assert_equal(old_hand, current.state[:race][:racers][1][:hand])
  assert_equal(old_events, native.events('Alice'), 'Replacement changed the immutable action stack')
  assert_equal(original.history.map(&:to_h), current.history.map(&:to_h), 'Replacement rewrote public history')
  native.assert_converged('physical replacements')
  saves = SavedGames.new(Storage.new, owner: 'Alice')
  repository = native.repositories.fetch('Alice')
  row = saves.put(game: h.game, table: native.table.merge('owner' => 'Alice'),
    snapshot: repository.snapshot_for(native.session), repository: repository, now: GameRoomClock.now.to_i)
  assert_equal(2, row.fetch('seat_changes').length)
  second, = h.restore_native(saves, row)
  final = second.replay('Alice')
  assert_equal(%w[Alice Watcher], final.players)
  assert_equal(DuckGameAdapterTest.semantic(current.state[:race]), DuckGameAdapterTest.semantic(final.state[:race]))
  assert_equal(current.accepted_events.length, final.accepted_events.length)
  second.assert_converged('archive after native human/bot/human replacements')
end

report_dir = File.expand_path('../../../tmp/duck-racing', __dir__)
FileUtils.mkdir_p(report_dir)
path = File.join(report_dir, 'game-adapter-local.json')
report = File.file?(path) ? JSON.parse(File.read(path)) : {'runs' => []}
failures = checks.count { |entry| entry[:status] == 'FAIL' }
report['runs'] << {scope: 'Local real action plans/repository authentication/payload/participant wrapper/archive; no live account or physical input',
  cases: checks, failures: failures}
File.write(path, JSON.pretty_generate(report) + "\n")
checks.each { |entry| puts "#{entry[:status]} #{entry[:name]}#{entry[:error] ? ': ' + entry[:error] : ''}" }
raise "#{failures} Duck game adapter checks failed" unless failures.zero?
puts "PASS #{checks.length} Duck game adapter scenarios"
