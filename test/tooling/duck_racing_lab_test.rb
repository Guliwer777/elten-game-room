require_relative '../support/ui'
require_relative '../../lib/game_surfaces'
require_relative '../support/duck_game_adapter'
require_relative '../../tools/support/release_files'
include DuckGameAdapterTest

# Capture a normal table before installing the optional hooks in this process.
ordinary = Harness.new
ordinary.start
ordinary_before = DuckGameAdapterTest.semantic(ordinary.replay)
ordinary_options = ordinary.game.default_options
ordinary_legal = ordinary.game.legal_actions(ordinary.replay, 'Alice')
require_relative '../../tools/duck-racing-lab'
LAB = GameRoomDuckRacingLab

checks = []
check = lambda do |name, &block|
  next if ENV['DUCK_LAB_CASE'] && !name.include?(ENV['DUCK_LAB_CASE'])
  entry = {name: name, status: 'PASS'}
  begin
    block.call
  rescue StandardError => error
    entry.merge!(status: 'FAIL', error: "#{error.class}: #{error.message}", location: error.backtrace.first(10))
  ensure
    checks << entry
  end
end

def laboratory(count: 2, **options)
  Harness.new(count: count, **options, options: {
    LAB::OPTION => true, 'challenges' => LOGIC::Challenges::BY_ID.keys
  }).tap(&:start)
end

def launch(h, kind, seats: (0...h.players.length).to_a, actor: h.owner)
  h.accept(LAB.selection(h.replay, kind, seats), actor: actor)
  h.replay.state[:round][:challenge]
end

def forge(h, selection, actor:, author: actor, **changes)
  data = selection.slice('action', 'input').merge('revision' => h.replay.state[:revision],
    'session' => h.session['__id'], 'at' => h.now_ms + 1).merge(changes)
  plan = GameRoomGames::ActionPlan.new(events: GameRoomActionPayload.commands(h.game.id, data))
  h.append(plan, actor: actor, author: author)
end

def finish_again(h)
  id = h.replay.state[:round][:challenge][:id]
  h.private_traces.each do |seat, trace|
    h.accept({'action' => 'submit_trace', 'challenge' => id, 'trace' => trace}, actor: h.players.fetch(seat))
  end
  assert_equal(:revealing, h.replay.state[:round][:private][:phase])
  h.replay.state[:round][:challenge][:participants].each do |seat|
    actor = h.players.fetch(seat)
    protocol = h.replay.state[:round][:private]
    prepared = LOGIC::PrivateRound.recover(protocol, seat: seat, user: actor, vault: h.vault(actor))
    prepared.reveal_pages.each do |page|
      h.accept({'action' => 'reveal', 'challenge' => id, 'page' => page}, actor: actor)
    end
  end
  assert_equal(id, h.replay.state[:last_resolution][:id])
  assert(h.replay.state[:last_resolution][:settlement])
end

check.call('ordinary tables and package allowlist are unchanged; repeated installation is inert') do
  assert_equal(ordinary_options, ordinary.game.default_options)
  assert_equal(ordinary_before, DuckGameAdapterTest.semantic(ordinary.replay))
  assert_equal(ordinary_legal, ordinary.game.legal_actions(ordinary.replay, 'Alice'))
  assert_equal(ordinary_legal, ordinary.game.legal_actions(ordinary.replay, 'Alice', context: ordinary.context('Alice')))
  assert(!GameRoomReleaseFiles.allowed?('tools/duck-racing-lab.rb'))
  assert(!GameRoomReleaseFiles.allowed?('test/tooling/duck_racing_lab_test.rb'))
  load File.expand_path('../../tools/duck-racing-lab.rb', __dir__)
  assert_equal(1, GameRoomGames::DuckRacing.ancestors.count(LAB::GameHook))
  assert_equal(1, LOGIC::Session.singleton_class.ancestors.count(LAB::SessionHook))
  assert_equal(1, GameRoomActionPayload.singleton_class.ancestors.count(LAB::PayloadHook))
  assert_equal(1, ordinary.game.effective_option_definitions.count { |item| item.key == LAB::OPTION })
  selection = LAB.selection(ordinary.replay, 'copy_number', [0, 1])
  assert_equal(:invalid, ordinary.plan(selection).first)
  before = DuckGameAdapterTest.semantic(ordinary.replay)
  forge(ordinary, selection, actor: 'Alice')
  assert_equal(before, DuckGameAdapterTest.semantic(ordinary.replay), 'Ordinary replay accepted a lab packet')
end

[2, 3, 4, 8].each do |count|
  check.call("#{count} players: 18 choices use the ordinary challenge lifecycle and durable decoder") do
    h = laboratory(count: count)
    spec = h.game.surface_spec(h.replay, h.owner)
    assert_equal(LOGIC::Challenges::TYPES.map(&:id), spec.zones.first.cards.map(&:id))
    LOGIC::Challenges::TYPES.each_with_index do |type, index|
      seats = type.maximum_players == 2 ? [count - 2, count - 1] : (0...count).to_a
      challenge = launch(h, type.id, seats: seats)
      assert_equal(index + 1, challenge[:id])
      assert_equal(type.id, challenge[:kind])
      assert_equal(seats, challenge[:participants])
      assert_equal(:laboratory, challenge[:trigger])
      pending = LAB.selection(h.replay, 'copy_number', (0...count).to_a)
      assert_equal(:invalid, h.plan(pending).first, 'A second challenge replaced an active one')
      h.begin_round
      state = h.replay.state[:round]
      if LOGIC::ChallengeEngine::REALTIME.include?(type.id)
        assert_equal(nil, state[:engine])
        assert_equal(nil, state[:private])
      elsif LOGIC::ChallengeEngine::SHARED.include?(type.id)
        assert_equal(type.id, state[:engine][:kind])
      elsif LOGIC::ChallengeEngine::FIRST_ANSWER.include?(type.id)
        assert_equal({}, state[:attempts])
        assert_equal(nil, state[:private])
      elsif LOGIC::ChallengeEngine::LOCAL_SCORES.include?(type.id)
        assert_equal({}, state[:results])
        assert_equal(nil, state[:private])
      else
        assert_equal(:collecting, state[:private][:phase])
        assert_equal(seats, state[:private][:seats])
      end
      # This case tests launch/cancel, not a fake completed game or score.
      h.accept({'action' => 'cancel', 'challenge' => challenge[:id], 'reason' => 'technical'},
        actor: h.players.fetch(seats.first))
      assert_equal(nil, h.replay.state[:round])
      assert_equal(:technical, h.replay.state[:last_resolution][:cancelled])
      assert_equal(Array.new(count, 18), h.replay.state[:race][:racers].values.map { |r| r[:feathers] })
    end
    clone = h.game.build_session_game
    other = clone.replay(h.session, h.events, h.repository)
    assert_equal(DuckGameAdapterTest.semantic(h.replay), DuckGameAdapterTest.semantic(other))
    assert_equal(h.events, other.accepted_events)
    assert_equal(nil, LAB.scope)
  end
end

check.call('actual list surface selects a group directly and a pair in a second list') do
  h = laboratory(count: 4)
  surface = GameSurfaces.build(h.game.surface_spec(h.replay, h.owner))
  actions = []
  surface.on_action { |action| actions << action }
  field = surface.fields.first
  group_index = LOGIC::Challenges::TYPES.index { |type| type.id == 'copy_number' }
  field.trigger(:select, [group_index])
  assert_equal(1, actions.length)
  assert_equal([0, 1, 2, 3], actions.first.to_h['card']['input']['seats'])
  assert_equal(:ok, h.plan(actions.shift).first)
  pair_index = LOGIC::Challenges::TYPES.index { |type| type.id == 'rock_paper_scissors' }
  field.trigger(:select, [pair_index])
  assert_equal([], actions)
  assert_equal(6, field.options.length)
  assert_equal('Carol / Dave', field.options.last)
  field.trigger(:select, [5])
  assert_equal([2, 3], actions.first.to_h['card']['input']['seats'])
  h.accept(actions.shift)
  assert_equal([2, 3], h.replay.state[:round][:challenge][:participants])
end

check.call('guest and spectator-host rejected in both planning and replay, including forged controller action') do
  h = laboratory
  selection = LAB.selection(h.replay, 'copy_number', [0, 1])
  assert_equal(:invalid, h.plan(selection, actor: 'Bob').first)
  assert_equal(:invalid, h.plan(selection, actor: 'Bob', local: {'duck_host' => true}).first)
  assert_equal(:invalid, h.plan(selection, actor: 'Watcher').first)
  before = DuckGameAdapterTest.semantic(h.replay)
  forge(h, selection, actor: 'Bob')
  forge(h, selection, actor: 'Alice', author: 'Bob')
  assert_equal(before, DuckGameAdapterTest.semantic(h.replay))

  watcher = laboratory(owner: 'Watcher')
  selection = LAB.selection(watcher.replay, 'copy_number', [0, 1])
  assert_equal(:invalid, watcher.plan(selection, actor: 'Alice', author: 'Watcher',
    local: {'duck_host' => true, 'duck_seat' => nil}).first)
  before = DuckGameAdapterTest.semantic(watcher.replay)
  forge(watcher, selection, actor: 'Alice', author: 'Watcher')
  assert_equal(before, DuckGameAdapterTest.semantic(watcher.replay))
  assert(watcher.game.surface_spec(watcher.replay, 'Watcher').zones.first.cards.empty?)
end

check.call('wrong or repeated seats, unknown/disabled kinds and partial groups cannot open a challenge') do
  h = laboratory(count: 4)
  invalid = [['missing', [0, 1]], ['copy_number', [0, 1]], ['rock_paper_scissors', [0, 1, 2]],
    ['rock_paper_scissors', [1, 1]], ['rock_paper_scissors', [1, 0]], ['rock_paper_scissors', [0, 4]]]
  invalid.each do |kind, seats|
    before = DuckGameAdapterTest.semantic(h.replay)
    selection = LAB.selection(h.replay, kind, seats)
    assert_equal(:invalid, h.plan(selection).first)
    forge(h, selection, actor: h.owner)
    assert_equal(before, DuckGameAdapterTest.semantic(h.replay))
  end
  restricted = Harness.new(options: {LAB::OPTION => true}).tap(&:start)
  selection = LAB.selection(restricted.replay, 'simon', [0, 1])
  assert_equal(:invalid, restricted.plan(selection).first)
  before = DuckGameAdapterTest.semantic(restricted.replay)
  forge(restricted, selection, actor: restricted.owner)
  assert_equal(before, DuckGameAdapterTest.semantic(restricted.replay))
end

check.call('full private attempts settle normally, then a second challenge uses a new scope on the same table') do
  h = laboratory
  launch(h, 'guess_number')
  stale = LAB.selection(h.replay, 'copy_number', [0, 1])
  h.begin_round
  h.finish_private
  first = h.replay.state[:last_resolution]
  assert_equal(0, first[:settlement].winner)
  assert(first[:settlement].transfers.any?)
  assert_equal(:invalid, h.plan(stale).first)
  launch(h, 'rock_paper_scissors')
  h.begin_round
  second_scope = h.replay.state[:round][:private]
  assert_equal('2', second_scope[:round_id])
  finish_again(h)
  assert_equal(nil, h.replay.state[:round])
  assert_equal(2, h.replay.state[:last_resolution][:id])
  assert_equal(18, h.game.surface_spec(h.replay, h.owner).zones.first.cards.length)
  assert_equal(h.events, h.replay.accepted_events)
end

check.call('first correct copy-number answer returns to the lab without waiting for private reveals') do
  h = laboratory
  challenge = launch(h, 'copy_number')
  h.begin_round
  seat, trace = h.private_traces.first
  h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace},
    actor: h.players.fetch(seat))
  assert_equal(nil, h.replay.state[:round])
  assert_equal(seat, h.replay.state[:last_resolution][:settlement].winner)
  assert_equal('attempt', h.decode.last[0]['action'])
  assert_equal(18, h.game.surface_spec(h.replay, h.owner).zones.first.cards.length)
end

check.call('empty feathers freeze normally but do not exclude the player from subsequent lab tests') do
  h = laboratory
  6.times do
    launch(h, 'rock_paper_scissors')
    h.begin_round
    finish_again(h)
  end
  racer = h.replay.state[:race][:racers][1]
  assert_equal(0, racer[:feathers])
  assert(racer[:frozen_turns].positive?)
  frozen = racer[:frozen_turns]
  launch(h, 'copy_number')
  assert_equal([0, 1], h.replay.state[:round][:challenge][:participants])
  assert_equal({0 => 36, 1 => 0}, h.replay.state[:round][:balances])
  assert_equal(frozen, h.replay.state[:race][:racers][1][:frozen_turns])
end

check.call('race actions and automatic bot rolls are stopped between tests, not during challenges') do
  h = laboratory
  assert_equal([], h.game.active_actors(h.replay))
  assert_equal([], h.game.legal_actions(h.replay, 'Alice'))
  assert_equal(nil, h.game.automatic_action(h.replay, 'Alice', context: h.context('Alice')))
  %w[roll skip].each do |kind|
    selection = {'action' => 'race', 'input' => {'kind' => kind}}
    assert_equal(:invalid, h.plan(selection).first)
    before = DuckGameAdapterTest.semantic(h.replay)
    forge(h, selection, actor: 'Alice')
    assert_equal(before, DuckGameAdapterTest.semantic(h.replay))
  end
  h.replace(1, GameRoomParticipants.bot_id(41, 1))
  assert_equal([], h.game.active_actors(h.replay))
  launch(h, 'copy_number')
  assert_equal('ready', h.game.automatic_action(h.replay, 'Alice', context: h.context('Alice'))['action'])
end

check.call('real coordinator keeps an idle bot stopped and completes its quiz with two humans') do
  h = laboratory(count: 3)
  bot = GameRoomParticipants.bot_id(41, 1)
  h.replace(2, bot)
  coordinator = GameRoomBots::Coordinator.new
  context = h.context(h.owner)
  assert_equal(nil, coordinator.decide(game: h.game, replay: h.replay, actor: bot, context: context))
  assert_equal(nil, coordinator.decide_next(game: h.game, replay: h.replay, context: context))

  id = launch(h, 'quiz')[:id]
  h.players.each do |actor|
    h.accept({'action' => 'ready', 'challenge' => id, 'fingerprint' => h.resources[:fingerprint]},
      actor: actor, author: actor == bot ? h.owner : actor)
  end
  assert_equal([0, 1, 2], h.replay.state[:round][:ready].keys.sort)
  assert_equal(:playing, h.replay.state[:round][:phase])
  replay = h.replay
  started_at = replay.state[:round][:started_at]
  context = h.context(h.owner, at: started_at)
  assert_equal(nil, coordinator.decide(game: h.game, replay: replay, actor: bot, context: context),
    'The quiz bot answered before its ordinary planning delay')
  planned = h.game.plan_duck_bot(replay, bot, context: context)
  assert(planned[:ready_ms] > started_at)
  assert_equal(nil, coordinator.decide_next(game: h.game, replay: replay,
    context: h.context(h.owner, at: planned[:ready_ms] - 1)))
  decision = coordinator.decide_next(game: h.game, replay: replay,
    context: h.context(h.owner, at: planned[:ready_ms]))
  assert(decision, 'The normal coordinator did not produce a ready bot decision')
  assert_equal(bot, decision.actor)
  assert_equal('submit_trace', decision.action['action'])
  assert_equal(planned[:trace], decision.action['trace'])
  h.accept(decision.action, actor: bot, author: h.owner, at: planned[:ready_ms])
  assert_equal([2], h.replay.state[:round][:private][:commitments].keys)
  assert_equal(nil, coordinator.decide_next(game: h.game, replay: h.replay,
    context: h.context(h.owner)))

  challenge = h.replay.state[:round][:challenge]
  [0, 1].each do |seat|
    trace = LOGIC::ChallengeTrace.new(challenge, seat: seat, resources: h.resources, compact: true)
    assert(trace.submit({kind: :answer, value: 0, press_id: 1}, at: 100 + seat * 100))
    h.accept({'action' => 'submit_trace', 'challenge' => id, 'trace' => trace.snapshot},
      actor: h.players.fetch(seat))
  end
  assert_equal(:revealing, h.replay.state[:round][:private][:phase])
  challenge[:participants].each do |seat|
    actor = h.players.fetch(seat)
    prepared = LOGIC::PrivateRound.recover(h.replay.state[:round][:private], seat: seat,
      user: actor, vault: h.vault(actor))
    assert(prepared, "The accepted attempt for seat #{seat} was not recoverable")
    prepared.reveal_pages.each do |page|
      h.accept({'action' => 'reveal', 'challenge' => id, 'page' => page}, actor: actor,
        author: actor == bot ? h.owner : actor)
    end
  end
  assert_equal(nil, h.replay.state[:round])
  assert_equal(id, h.replay.state[:last_resolution][:id])
  assert(h.replay.state[:last_resolution][:settlement], 'The ordinary private protocol did not settle the quiz')
  assert_equal(h.events, h.replay.accepted_events)
  assert_equal(18, h.game.surface_spec(h.replay, h.owner).zones.first.cards.length)
  assert_equal(nil, coordinator.decide(game: h.game, replay: h.replay, actor: bot, context: h.context(h.owner)))
end

check.call('stale revision, control epoch and previous-session selection cannot start a test') do
  h = laboratory
  h.session['__control_epoch'] = 'first'
  old = LAB.selection(h.replay, 'copy_number', [0, 1])
  h.session['__control_epoch'] = 'second'
  assert_equal(:invalid, h.plan(old).first)
  fresh = LAB.selection(h.replay, 'copy_number', [0, 1])
  assert_equal(:ok, h.plan(fresh).first)
  next_game = laboratory(session_id: 92)
  assert_equal(:invalid, next_game.plan(fresh).first)
  before = DuckGameAdapterTest.semantic(next_game.replay)
  forge(next_game, fresh, actor: next_game.owner, 'session' => 91)
  assert_equal(before, DuckGameAdapterTest.semantic(next_game.replay))
  assert_equal(:ok, next_game.plan(LAB.selection(next_game.replay, 'copy_number', [0, 1])).first)
end

check.call('host transfer and replacement preserve authorized historical launches and permit the new playing host') do
  h = laboratory
  launch(h, 'guess_number')
  h.begin_round
  h.finish_private
  h.replace(0, 'Dora')
  h.owner = 'Dora'
  assert_equal(h.events, h.replay.accepted_events)
  selection = LAB.selection(h.replay, 'copy_number', [0, 1])
  assert_equal(:invalid, h.plan(selection, actor: 'Alice').first)
  launch(h, 'copy_number', actor: 'Dora')
  assert_equal('copy_number', h.replay.state[:round][:challenge][:kind])
  assert_equal(h.events, h.replay.accepted_events)
end

check.call('native writer rejects a prepared action after the owner/control epoch changes') do
  fixture = laboratory
  native = NativeHarness.new(game: fixture.game, users: %w[Alice Bob], options: fixture.game.options_from_json(fixture.session['options']))
  native.start
  native.submit_at({'action' => 'start'}, actor: 'Alice', at: 1_000_000)
  replay = native.replay('Alice')
  selection = LAB.selection(replay, 'copy_number', [0, 1])
  context = GameRoomGames::ActionContext.new(session_id: native.session['__id'], table_id: native.table['__id'],
    table_owner: 'Alice', now: 1_001, local_data: {'duck_host' => true, 'duck_seat' => 0})
  status, plan = native.game.action_for(selection, replay, 'Alice', context: context)
  assert_equal(:ok, status)
  native.as('Alice') { native.transports['Alice'].transfer_room_owner(native.table, 'Bob') }
  rejected = false
  begin
    native.write('Alice', plan.events)
  rescue GameRoomNetworkErrors::GamePaused, ArgumentError
    rejected = true
  end
  assert(rejected, 'Native writer accepted a plan made before the ownership change')
  native.as('Bob') do
    # Normal room synchronization publishes the new owner's anchored control
    # record. Reading only game events is not that lifecycle operation.
    native.transports['Bob'].room_snapshot(native.table)
    assert_equal(nil, native.replay('Bob').state[:round])
    native.submit_at(LAB.selection(native.replay('Bob'), 'copy_number', [0, 1]), actor: 'Bob', at: 1_002_000)
  end
  native.assert_converged('New playing host started a lab challenge')
end

check.call('PL and EN tool labels are native UTF-8 and never require a catalogue change') do
  %w[pl en].each do |language|
    GameRoomLocalization.boot(settings: {'interface_language' => language, 'known_languages' => []}, host_language: language)
    h = laboratory
    definition = h.game.effective_option_definitions.find { |item| item.key == LAB::OPTION }
    assert_equal(language == 'pl' ? 'Laboratorium wyzwań (tylko do testów)' : 'Challenge lab (test only)', definition.label)
    assert_equal(Encoding::UTF_8, definition.label.encoding)
    surface = GameSurfaces.build(h.game.surface_spec(h.replay, h.owner))
    surface.fields.first.focus
    assert_equal(18, surface.fields.first.options.length)
  end
end

report = {kind: 'targeted optional Duck lab tests', tests: checks.length,
  passed: checks.count { |entry| entry[:status] == 'PASS' },
  failures: checks.count { |entry| entry[:status] == 'FAIL' }, checks: checks,
  limits: ['Local native-source/API doubles and surface handlers; no live account, physical keys or acoustic listening.',
    'The 72 launch/cancel combinations are not 72 completed games. Full settlement is separately exercised for copy-number, guess-number and RPS.']}
File.write(ENV['DUCK_LAB_REPORT'], JSON.pretty_generate(report) + "\n") if ENV['DUCK_LAB_REPORT']
puts JSON.pretty_generate(report)
raise 'Duck lab targeted tests failed' unless report[:failures].zero?
