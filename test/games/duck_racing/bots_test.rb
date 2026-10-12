require_relative "bots_helpers"
include DuckBotFixture

cases = []
case_filter = Regexp.new(ENV.fetch("DUCK_BOT_CASE")) if ENV.key?("DUCK_BOT_CASE")
check = lambda do |name, &block|
  next if case_filter && !case_filter.match?(name)

  block.call
  cases << {name: name, status: "PASS"}
rescue StandardError => error
  cases << {name: name, status: "FAIL", error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(6)}
end

check.call("production game includes bots and shares only its bounded planning cache") do
  assert(GAME.ancestors.include?(LOGIC::Bots))
  game = GAME.new(resources: DuckBotFixture.resources)
  first, second = game.build_session_game, game.build_session_game
  cache = game.instance_variable_get(:@bot_cache)
  assert(cache.is_a?(LOGIC::BotCache))
  assert(first.instance_variable_get(:@bot_cache).equal?(cache))
  assert(second.instance_variable_get(:@bot_cache).equal?(cache))
  assert(!first.equal?(second))
end

# Until the parent's game wiring is present, record that integration failure
# above but still exercise this new module rather than skip its diagnostics.
GAME.include(LOGIC::Bots) unless GAME.ancestors.include?(LOGIC::Bots)

check.call("cache is immutable, bounded to seats, invalidates old in-flight publishers") do
  cache = LOGIC::BotCache.new
  scope = [1, 2, "simon"]
  token = cache.activate(scope)
  entry = {ready_ms: 19_000, trace: {"actions" => [], "finished_at" => 18_000}}
  published = cache.publish(scope, token, 0, [0, "bot:1:1"], entry)
  entry[:trace]["actions"] << {"wrong" => true}
  assert_equal([], published[:trace]["actions"])
  assert_raises(FrozenError) { published[:trace]["actions"] << {} }
  assert_equal(1, cache.version(scope))
  assert_equal(published, cache.publish(scope, token, 0, [0, "bot:1:1"], entry))
  assert_equal(1, cache.version(scope))
  8.times { |seat| cache.publish(scope, token, seat, [seat], {ready_ms: seat}) }
  assert_equal(8, cache.size)
  cache.activate([1, 3, "simon"])
  assert_equal(0, cache.size)
  assert_equal(nil, cache.publish(scope, token, 0, [0], entry))
  assert_equal(nil, cache.read(scope, 0, [0]))
end

LOGIC::Cards::TYPES.each do |type|
  check.call("legal physical card and targets: #{type.id}") do
    h = Fixture.new(count: 8)
    race = h.state[:race]
    race[:racers].each_value { |racer| racer[:feathers] = 50 }
    race[:racers][0][:hand] = []
    card = h.card(type.id)
    before = Marshal.dump(h.state)
    actions = h.game.legal_actions(h.replay, h.players[0])
    expected = [:self, :square].include?(type.target) ? 1 : (type.target == :any ? 8 : 7)
    assert_equal(expected + 1, actions.length)
    assert_equal(before, Marshal.dump(h.state))
    actions.each do |action|
      candidate = LOGIC::Session.copy(h.state)
      data = action.reject { |key, _| key == "kind" }.merge("revision" => candidate[:revision])
      assert(LOGIC::Session.apply(candidate, data, seat: 0, moderator: false, now_ms: 1_500, resources: DuckBotFixture.resources), action.inspect)
    end
    assert_equal([], h.game.legal_actions(h.replay, h.players[1]))
    assert_equal([], h.game.legal_actions(h.replay, "Observer"))
    race[:racers][0][:feathers] = [type.cost - 1, 0].max
    if type.cost.positive?
      assert_equal(["roll"], h.game.legal_actions(h.replay, h.players[0]).map { |action| action["input"]["kind"] })
    end
    race[:card_played] = true
    assert_equal(1, h.game.legal_actions(h.replay, h.players[0]).length)
    race[:racers][0][:skip_turns] = 1
    assert_equal([], h.game.active_actors(h.replay))
  end
end

check.call("occupied trap, frozen challenge target and identical physical cards") do
  h = Fixture.new(count: 3)
  race = h.state[:race]
  race[:racers][0][:hand] = []
  h.card("mine")
  h.card("challenge")
  race[:traps][1] = {owner: 1, card: LOGIC::Cards::Copy.new("old", "investment")}
  race[:racers][1][:frozen_turns] = 1
  actions = h.game.legal_actions(h.replay, h.players[0])
  assert_equal(["roll", "play"], actions.map { |action| action["input"]["kind"] })
  assert_equal(2, actions.last["input"]["target"])
  race[:racers][0][:hand] = [LOGIC::Cards::Copy.new("first", "tiny_recoil"), LOGIC::Cards::Copy.new("second", "tiny_recoil")]
  actions = h.game.legal_actions(h.replay, h.players[0])
  assert_equal(%w[first second], actions.drop(1).map { |action| action["input"]["card"] })
end

check.call("public observation excludes other hands, RNG, private seeds and pending attempts") do
  h = Fixture.new(kind: "quiz", count: 3)
  original = h.game.bot_observation(h.replay, h.players[0])
  race = h.state[:race]
  [1, 2].each do |seat|
    race[:racers][seat][:hand].map! { |card| LOGIC::Cards::Copy.new("secret-#{card.id}", "winning_die") }
  end
  race[:random] = Random.new(98_714)
  assert_equal(original, h.game.bot_observation(h.replay, h.players[0]))
  assert_equal({}, h.game.bot_observation(h.replay, "Observer"))
  h.challenge
  safe = h.game.bot_observation(h.replay, h.players[0])
  h.state[:round][:challenge][:seed] += 1
  h.state[:round][:private][:pages][1] = {0 => {"secret" => "answer"}}
  assert_equal(safe, h.game.bot_observation(h.replay, h.players[0]))
  text = JSON.generate(safe)
  %w[seed commitments pages private random secret].each { |word| assert(!text.include?("\"#{word}\""), word) }
end

check.call("strategy finishes a race, preserves feathers and targets the threatening leader") do
  h = Fixture.new(count: 3)
  race = h.state[:race]
  race[:racers][0][:hand] = []
  h.card("helix")
  race[:racers][0][:progress] = 88
  move = h.choose(seat: 0, at: 1_500)
  assert_equal(0, move["input"]["target"])
  assert_equal("helix", race[:racers][0][:hand].find { |card| card.id == move["input"]["card"] }.type)
  h.apply(move, at: 1_500)
  assert_equal(h.players[0], h.replay.winner)
  assert_equal([], h.game.active_actors(h.replay))

  h = Fixture.new(count: 3)
  race = h.state[:race]
  race[:racers][0][:hand] = []
  h.card("helix")
  race[:racers][0][:feathers] = 7
  race[:racers][0][:progress] = 10
  assert_equal("roll", h.choose(seat: 0, at: 1_500)["input"]["kind"])
  race[:racers][0][:hand] = []
  h.card("golden_sleep")
  race[:racers][1][:progress], race[:racers][2][:progress] = 78, 5
  assert_equal(1, h.choose(seat: 0, at: 1_500)["input"]["target"])

  race[:racers][0][:hand] = []
  h.card("opportunistic_die")
  race[:racers][0][:feathers] = 30
  race[:racers][0][:die_sides], race[:racers][0][:die_rolls] = 12, 3
  assert_equal("roll", h.choose(seat: 0, at: 1_500)["input"]["kind"])
end

LOGIC::ChallengeBot::PRIVATE_TYPES.each do |kind|
  check.call("private #{kind}: real trace, absolute time, shared delay and full commit/reveal") do
    game = DuckBotFixture.game
    h = Fixture.new(kind: kind, game: game)
    def h.context(now)
      super.tap { |context| context.local_data["duck_stack_entry_bytes"] = 1_536 }
    end
    h.challenge
    baseline = Marshal.dump(h.state)
    started_at = h.state[:round][:started_at]
    speed = LOGIC::ChallengeEngine::SPEED_TYPES.include?(kind)
    preparation = speed ? LOGIC::ChallengeEngine::PREPARATION_MS : 0
    assert(preparation.positive?) if speed
    delays, selections = {}, {}
    h.players.each_index do |seat|
      actor = h.players[seat]
      key_before = game.bot_delay_revision(h.replay, [1, 2])
      assert_equal(0.0, game.bot_move_delay(h.replay, actor, context: h.context(started_at)))
      immediate = h.choose(seat: seat, at: started_at)
      wait = game.bot_move_delay(h.replay, actor, context: h.context(started_at))
      at = started_at + (wait * 1_000).round
      if wait.positive?
        assert_equal(nil, immediate)
        assert_equal(nil, h.choose(seat: seat, at: at - 1))
      end
      if speed
        assert(wait * 1_000 >= preparation, "#{kind} did not wait for the preparation cue")
        assert_equal(nil, h.choose(seat: seat, at: started_at + preparation - 1))
      end
      assert(game.bot_delay_revision(h.replay, [1, 2]) != key_before)
      selection = h.choose(seat: seat, at: at)
      assert(selection && selection["trace"], "#{kind} did not finish a real trace")
      assert_equal(at - started_at - preparation, selection["trace"]["finished_at"],
        "#{kind} added preparation to the scored trace")
      if speed
        # The former deadline omitted preparation. Neither reaching that
        # deadline nor hearing the cue is enough to finish the attempt.
        assert_equal(nil, h.choose(seat: seat, at: at - preparation))
        if selection["trace"]["finished_at"].positive?
          assert_equal(nil, h.choose(seat: seat, at: started_at + preparation))
        end
      end
      delays[seat], selections[seat] = at, selection
      assert_equal(selection, h.choose(seat: seat, at: at + 100))
      assert_equal(selection, h.choose(seat: seat, at: at, game: DuckBotFixture.game),
        "#{kind} changed its trace after rebuilding the bot's local cache")
    end
    assert_equal(baseline, Marshal.dump(h.state), "Planning changed the race or RNG")
    verifier = LOGIC::TraceVerifier.new(challenge: h.state[:round][:challenge],
      balances: h.state[:round][:balances], resources: DuckBotFixture.resources)
    if LOGIC::ChallengeEngine::FIRST_ANSWER.include?(kind)
      arrival_order = delays.sort_by { |seat, time| [time, seat] }.map(&:first)
      winner = arrival_order.find { |seat| verifier.verify_attempt(seat, selections[seat].fetch("trace"))[:correct] }
      arrival_order.each do |seat|
        break unless h.state[:round]
        h.apply(selections[seat], seat: seat, at: delays[seat])
      end
      assert_equal(nil, h.state[:round])
      assert_equal(winner, h.state[:last_resolution][:settlement].winner)
      next
    end
    expected = verifier.replay(traces: selections.transform_values { |selection| selection.fetch("trace") }, forfeits: [])
    now = delays.values.max
    30_000.step(now - started_at, 30_000) { |offset| h.alive(at: started_at + offset) }
    h.players.each_index do |seat|
      h.apply(selections[seat], seat: seat, at: now)
      assert(!game.active_actors(h.replay).include?(h.players[seat]))
      assert(h.state[:round][:private][:commitments].key?(seat))
      assert_equal({}, h.state[:round][:private][:reveals])
      assert_equal(nil, h.state[:last_resolution])
    end
    id = h.state[:round][:challenge][:id]
    h.apply({"kind" => "duck", "action" => "advance", "challenge" => id}, at: now + 1)
    until h.state[:round].nil?
      ready = false
      h.players.each_index do |seat|
        break unless h.state[:round]
        action = game.automatic_action(h.replay, h.players[seat], context: h.context(now + 2))
        next unless action
        assert_equal("reveal", action["action"])
        h.apply(action, seat: seat, at: now + 2)
        ready = true
      end
      assert(ready)
    end
    assert(h.state[:last_resolution][:settlement])
    assert_equal(expected.results, h.state[:last_resolution][:results],
      "Commit/reveal changed scores measured from the cue")
    assert_equal(expected.settlement, h.state[:last_resolution][:settlement])
    assert_equal(:turn, h.state[:race][:phase])
  end
end

check.call("sound ordering uses shared swaps and keeps a bot deadline across peer actions") do
  h = Fixture.new(kind: "sound_order", count: 3)
  h.challenge
  engine = h.state[:round][:engine]
  assert_equal(h.players, h.game.active_actors(h.replay))
  assert_equal(28, h.game.legal_actions(h.replay, h.players[0]).length)
  assert_equal(nil, h.choose(seat: 0, at: 1_200))
  delay = h.game.bot_move_delay(h.replay, h.players[0], context: h.context(1_200))
  assert(delay >= 4.65)
  peer_at = 1_300 + LOGIC::ChallengeEngine::ORDER_PREPARATION_MS
  h.apply({"kind" => "duck", "action" => "input", "challenge" => h.state[:round][:challenge][:id],
    "input" => {"kind" => "swap", "value" => 1, "other" => 2, "press_id" => 1}}, seat: 1, at: peer_at)
  assert(h.state[:round])
  remaining = h.game.bot_move_delay(h.replay, h.players[0], context: h.context(peer_at))
  assert((remaining - (delay - (peer_at - 1_200) / 1000.0)).abs < 0.001, "A peer swap restarted the bot's listening time")
  now = 1_200 + (delay * 1_000).round
  8.times do
    break unless h.state[:round]
    h.choose(seat: 0, at: now)
    wait = h.game.bot_move_delay(h.replay, h.players[0], context: h.context(now))
    now += (wait * 1_000).round
    action = h.choose(seat: 0, at: now)
    assert_equal("input", action && action["action"])
    assert_equal("swap", action["input"]["kind"])
    h.apply(action, seat: 0, at: now)
  end
  assert_equal(nil, h.state[:round])
  assert_equal(0, h.state[:last_resolution][:settlement].winner)
  assert(h.state[:last_resolution][:settlement].transfers.all? { |transfer| transfer.amount <= 5 })
end

check.call("private wait is not restarted by alive or chat, and delay reads do not plan") do
  h = Fixture.new(kind: "simon")
  h.challenge
  actor = h.players[0]
  cache = h.game.instance_variable_get(:@bot_cache)
  10.times { h.game.bot_move_delay(h.replay, actor, context: h.context(1_200)) }
  assert_equal(0, cache.size)
  now = 0.0
  gate = GameRoomBots::TurnController.new(clock: -> { now })
  first_key = h.game.bot_delay_revision(h.replay, [1, 2])
  gate.schedule_decision(session_id: 777, actor: actor, revision: first_key, delay: 0)
  lease = gate.acquire(session_id: 777, actor: actor, revision: [1, 2])
  assert(lease)
  assert_equal(nil, h.choose(seat: 0, at: 1_200))
  gate.cancel(lease)
  delay = h.game.bot_move_delay(h.replay, actor, context: h.context(1_200))
  planned_key = h.game.bot_delay_revision(h.replay, [1, 2])
  assert(planned_key != first_key)
  gate.schedule_decision(session_id: 777, actor: actor, revision: planned_key, delay: delay)
  assert_equal(nil, gate.acquire(session_id: 777, actor: actor, revision: [1, 2]))
  if delay > 30
    now = 30.0
    h.alive(at: 31_200)
    assert_equal(planned_key, h.game.bot_delay_revision(h.replay, [99, 999]))
    gate.schedule_decision(session_id: 777, actor: actor, revision: planned_key,
      delay: h.game.bot_move_delay(h.replay, actor, context: h.context(31_200)))
  end
  now = delay - 0.001
  assert_equal(nil, gate.acquire(session_id: 777, actor: actor, revision: [99, 999]))
  now = delay
  assert(gate.acquire(session_id: 777, actor: actor, revision: [99, 999]))
  assert(h.choose(seat: 0, at: 1_200 + (delay * 1000).round))
end

check.call("controller and challenge identity reset cached attempts; cache never accumulates old rounds") do
  h = Fixture.new(kind: "simon")
  h.challenge
  h.choose(seat: 0, at: 1_200)
  cache = h.game.instance_variable_get(:@bot_cache)
  assert_equal(1, cache.size)
  h.state[:bot_controller_epoch] = "replacement"
  assert_equal(0.0, h.game.bot_move_delay(h.replay, h.players[0], context: h.context(1_200)))
  assert_equal(0, cache.size)
  h.choose(seat: 0, at: 1_200)
  assert_equal(1, cache.size)
  original = LOGIC::Session.copy(h.state[:round][:challenge])
  20.times do |index|
    h.state[:round][:challenge][:id] = original[:id] + index + 1
    h.choose(seat: 0, at: 1_200)
    assert_equal(1, cache.size)
  end
  h.state[:session_id] += 1
  h.game.bot_delay_revision(h.replay, [0, 0])
  assert_equal(0, cache.size)
end

check.call("revalidated seed or start time cannot reuse an old attempt under the same challenge ID") do
  h = Fixture.new(kind: "copy_number")
  h.challenge
  actor, cache = h.players[0], h.game.instance_variable_get(:@bot_cache)
  h.choose(seat: 0, at: 1_200)
  assert_equal(1, cache.size)
  # A corrected prefix is a separate model fixture, not a legal edit to a
  # running challenge. Cache identity must still honor that revalidation.
  h.state[:round][:challenge][:seed] += 1
  assert_equal(0.0, h.game.bot_move_delay(h.replay, actor, context: h.context(1_200)))
  assert_equal(0, cache.size)
  h.choose(seat: 0, at: 1_200)
  h.state[:round][:started_at] += 500
  assert_equal(0.0, h.game.bot_move_delay(h.replay, actor, context: h.context(1_200)))
  assert_equal(0, cache.size)
end

%w[numbered_balls sound_memory].each do |kind|
  8.times do |seed|
    check.call("sequential #{kind}/#{seed}: honest memory, pacing and host-cache replacement") do
      h = Fixture.new(kind: kind, seed: seed)
      h.challenge
      now, steps = 1_200, 0
      until h.state[:round].nil?
        actor = h.game.active_actors(h.replay).first
        seat = h.players.index(actor)
        assert(seat)
        assert_equal(nil, h.choose(seat: seat, at: now)) if steps.zero?
        h.choose(seat: seat, at: now)
        delay = h.game.bot_move_delay(h.replay, actor, context: h.context(now))
        now += (delay * 1000).ceil
        if LOGIC::Session.automatic(h.state, now_ms: now) == "advance"
          h.apply({"kind" => "duck", "action" => "advance", "challenge" => h.state[:round][:challenge][:id]}, at: now)
          next
        end
        move = h.choose(seat: seat, at: now)
        assert(move)
        # A fresh host derives the same heard positions from the accepted
        # current challenge, not an old process's hidden memory or board.
        fresh = DuckBotFixture.game
        assert_equal(move, h.choose(seat: seat, at: now, game: fresh))
        before = Marshal.dump(h.state)
        assert_equal([], h.game.legal_actions(h.replay, h.players[1 - seat]))
        assert_equal(before, Marshal.dump(h.state))
        h.apply(move, seat: seat, at: now)
        steps += 1
        assert(steps < 100)
      end
      assert(h.state[:last_resolution][:settlement])
      assert_equal(:turn, h.state[:race][:phase])
    end
  end
end

check.call("a sound-memory bot remembers heard pairs only, with or without a former host") do
  h = Fixture.new(kind: "sound_memory", seed: 17)
  h.challenge
  view = LOGIC::ChallengeEngine.view(h.state[:round][:engine], seat: 0)
  turn = view[:public][:turn]
  # Two explicit public reveals. Their values are read only after submitting
  # them; the test never uses the concealed pair layout to select a key.
  [1, 2].each_with_index do |position, index|
    h.apply({"kind" => "duck", "action" => "input", "challenge" => h.state[:round][:challenge][:id],
      "input" => {"kind" => "reveal", "value" => position, "press_id" => index + 1}}, seat: turn, at: 1_300 + index * 200)
  end
  memory = h.game.send(:duck_memory_from_history, h.replay, 1 - turn)
  public = LOGIC::ChallengeEngine.view(h.state[:round][:engine], seat: 0)[:public]
  expected_keys = [1, 2] - public[:removed]
  assert_equal(expected_keys, memory[:tones].keys.sort)
  assert_equal(memory, DuckBotFixture.game.send(:duck_memory_from_history, h.replay, 1 - turn))
  assert_equal(2, memory[:serial])
end

%w[axel_pong audio_ball].each do |kind|
  check.call("native #{kind} has no second bot executor") do
    h = Fixture.new(kind: kind)
    h.challenge
    assert_equal([], h.game.active_actors(h.replay))
    assert_equal([], h.game.legal_actions(h.replay, h.players[0]))
    assert_equal(nil, h.choose(seat: 0, at: 30_000))
  end
end

report_dir = File.expand_path("../../../tmp/duck-racing", __dir__)
FileUtils.mkdir_p(report_dir)
path = File.join(report_dir, "bots-integration-local.json")
report = File.file?(path) ? JSON.parse(File.read(path)) : {"runs" => []}
run = {scope: "Local game policy, candidate-copy action_for, commitment/reveal and shared delay gate; not live accounts",
  filter: case_filter&.source, cases: cases, failures: cases.count { |entry| entry[:status] == "FAIL" }}
report["runs"] << run
File.write(path, JSON.pretty_generate(report) + "\n")
cases.select { |entry| entry[:status] == "FAIL" }.each { |entry| warn "FAIL #{entry[:name]}: #{entry[:error]}" }
raise "#{run[:failures]} bot integration checks failed" unless run[:failures].zero?
raise "No bot integration cases matched #{case_filter.inspect}" if cases.empty?
puts "PASS #{cases.length} Duck Racing bot integration scenarios"
