require "json"
require "fileutils"
require_relative "../../support/assertions"
require_relative "../../support/elten_array_shuffle"
require_relative "../../support/duck_private_round"
require_relative "../../../games/duck_racing_support/challenge_bot"
require_relative "../../../content/languages"
require_relative "../../../content/scrabble_words_en"
require_relative "../../../content/scrabble_words_pl"

include GameRoomTest::Assertions
include DuckPrivateRoundTest
engine = GameRoomDuckRacing::ChallengeEngine
bot = GameRoomDuckRacing::ChallengeBot
verifier = GameRoomDuckRacing::TraceVerifier
turn_only = ENV["DUCK_NUMERIC_TURN_ONLY"] == "1"
private_types = turn_only ? ["rock_paper_scissors"] : bot::PRIVATE_TYPES
sequential_types = turn_only ? GameRoomDuckRacing::NumericChallenges::TURN_TYPES : engine::SEQUENTIAL
registry = GameRoomContent::Registry.new
registry.register_language(GameRoomContent::LanguageProfile.new(id: "en", label: "English",
  alphabet: ("a".."z").to_a, normalizer: ->(text) { text.downcase }))
registry.register_pack(GameRoomContent::Pack.new(id: "test.duck.bot.quiz", set_id: "test.duck.bot.quiz", kind: "quiz",
  language_id: "en", version: 1, title: "Test", game_ids: ["quiz"], data: {"questions" => [
    {"id" => "q", "category" => "Test", "prompt" => "How many wheels?", "correct" => "four", "wrong" => %w[one two three]}
  ]}))
resources = {
  questions: GameRoomDuckRacing::QuestionSets.prepare_selected(ids: ["test.duck.bot.quiz"], language: "en", registry: registry)
}
make = lambda do |kind, seed, count = 2|
  {id: 17, kind: kind, participants: (0...count).map { |index| index * 2 }, seed: seed,
    race_snapshot: {board_length: 30, laps: 3, racers: (0...count).to_h do |index|
      [index * 2, {progress: index * 16, feathers: 18 - index, card_count: 3 + index,
        die_sides: [3, 6, 10, 12][index % 4], die_rolls: index % 4 == 1 ? 0 : 2}]
    end}}
end
cases, trace_count = [], 0
times = Hash.new { |hash, kind| hash[kind] = [] }
simon_scores, accuracy_scores, quiz_answers = [], [], []
check = lambda do |name, &block|
  block.call
  cases << {name: name, status: "PASS"}
rescue StandardError => error
  cases << {name: name, status: "FAIL", error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(5)}
end

# This is model input and deterministic replay, NOT a live ELTEN session.
# The verifier rebuilds each participant independently and recomputes scores.
private_types.each do |kind|
  12.times do |seed|
    check.call("#{kind}/seed#{seed}") do
      count = kind == "rock_paper_scissors" ? 2 : [2, 4, 8][seed % 3]
      challenge = make.call(kind, seed, count)
      before = Marshal.dump(challenge)
      traces = challenge[:participants].to_h do |seat|
        trace = bot.plan(challenge, seat: seat, seed: seed * 43 + 19, resources: resources)
        assert_equal(trace, bot.plan(challenge, seat: seat, seed: seed * 43 + 19, resources: resources), "Repeated planning differs")
        assert_equal(%w[actions finished_at], trace.keys.sort)
        assert(trace["finished_at"].is_a?(Integer) && trace["finished_at"] >= 0)
        assert(trace["actions"].length <= 512)
        state = engine.start(challenge, resources: resources)
        last_time, last_press, heard_starts = 0, 0, {}
        trace["actions"].each do |entry|
          at, input = entry.values_at("at", "input")
          assert(at.between?(last_time, trace["finished_at"]))
          if input["kind"].start_with?("playback_")
            audio = engine.stimulus(state, seat: seat)
            assert(audio, "acknowledgement without pending playback")
            assert_equal(audio[:id], input["playback_id"])
            if input["kind"] == "playback_started"
              assert(at >= audio[:requested_ms])
              heard_starts[audio[:id]] = at
            else
              start = heard_starts.fetch(audio[:id], audio[:requested_ms])
              finish = audio[:events].map { |event| start + event[:offset_ms] + event[:duration_ms] }.max
              assert(at >= finish, "Playback acknowledged before the last sound ended")
            end
            assert_equal(false, input.key?("press_id"))
          else
            assert(input["press_id"].is_a?(Integer) && input["press_id"] > last_press)
            assert_equal(false, input["repeat"] == true)
            last_press = input["press_id"]
          end
          engine.expire(state, now_ms: at)
          assert(engine.submit(state, seat: seat, action: input, now_ms: at, resources: resources))
          last_time = at
          visible = engine.view(state)
          assert_equal([], visible.keys & %i[scores results answer outcome correct_index answers])
        end
        engine.expire(state, now_ms: trace["finished_at"])
        assert(engine.own_finished?(state, seat))
        trace_count += 1
        times[kind] << trace["finished_at"]
        [seat, trace]
      end
      assert_equal(before, Marshal.dump(challenge), "Planning mutated challenge input")
      balances = challenge[:participants].to_h { |seat| [seat, 1_000] }
      check_replay = verifier.new(challenge: challenge, balances: balances, resources: resources)
      if engine::FIRST_ANSWER.include?(kind)
        traces.each do |seat, trace|
          result = check_replay.verify_attempt(seat, trace)
          assert([true, false].include?(result[:correct]))
        end
        # Session accepts these attempts one at a time, not through the
        # all-players commit/reveal protocol tested below.
        next
      end
      resolved = check_replay.replay(traces: traces, forfeits: [])
      assert_equal(resolved, check_replay.replay(traces: traces.to_a.reverse.to_h, forfeits: []))
      assert(resolved.settlement.balances.values.all? { |value| value >= 0 })
      if kind == "simon"
        simon_scores.concat(resolved.results.values.map { |result| result[:score] })
      elsif %w[rhythm hit_duck].include?(kind)
        accuracy_scores.concat(resolved.results.values.map { |result| result[:score] })
      elsif kind == "quiz"
        quiz_answers.concat(resolved.results.values.map { |result| result[:answer] })
      end
    end
  end
end

check.call("varied reaction times and finite imperfect audio memory") do
  assert_equal(private_types.sort, times.keys.sort)
  times.each do |kind, values|
    assert(values.uniq.length >= 3, "#{kind} has no varied reaction times")
  end
  if private_types.include?("simon")
    assert(simon_scores.all? { |score| score.between?(8, 16) })
    assert(simon_scores.uniq.length >= 5)
  end
  assert(accuracy_scores.any? { |score| score < 100 }, "Audio bot must not be uniformly perfect") unless turn_only
  assert_equal([0, 1, 2, 3], quiz_answers.uniq.sort) if private_types.include?("quiz")
end

check.call("disabled word challenges do not get a bot attempt") do
  %w[anagram longest_word].each do |kind|
    assert_raises(ArgumentError) { bot.plan(make.call(kind, 0), seat: 0, seed: 1, resources: resources) }
  end
end unless turn_only

check.call("only projected observations and pending sound affect decisions") do
  expected = private_types.to_h do |kind|
    [kind, bot.plan(make.call(kind, 123), seat: 0, seed: 321, resources: resources)]
  end
  original_view, original_result = engine.method(:view), engine.method(:result_for)
  engine.define_singleton_method(:view) do |state, **arguments|
    original_view.call(state, **arguments).merge(answer: -999, correct_index: 900, scores: {0 => -1},
      private: {seed: -1, pairs: [99], expected: "not an observation"}, deck: [51])
  end
  engine.define_singleton_method(:result_for) { |_state, _seat| raise "Bot attempted to read a private result" }
  begin
    private_types.each do |kind|
      assert_equal(expected[kind], bot.plan(make.call(kind, 123), seat: 0, seed: 321, resources: resources))
    end
  ensure
    engine.define_singleton_method(:view, original_view)
    engine.define_singleton_method(:result_for, original_result)
  end
end

check.call("reject unauthorized seats, realtime and public-turn traces") do
  c = make.call("rock_paper_scissors", 0)
  assert_raises(ArgumentError) { bot.plan(c, seat: 1, seed: 1) }
  assert_raises(ArgumentError) { bot.plan(c, seat: 0.0, seed: 1) }
  assert_raises(ArgumentError) { bot.plan(c, seat: 0, seed: 1.0) }
  rejected_types = turn_only ? sequential_types : engine::SHARED + engine::REALTIME
  rejected_types.each do |kind|
    assert_raises(ArgumentError) { bot.plan(make.call(kind, 0), seat: 0, seed: 1) }
  end
  assert_raises(ArgumentError) { bot.plan(make.call("anagram", 0), seat: 0, seed: 1) } unless turn_only
end

# Exercise the actual private wire framing too, including Simon traces that
# require several pages. Only a hash is published before the reveal phase.
private_types.reject { |kind| engine::FIRST_ANSWER.include?(kind) }.each do |kind|
  check.call("commit/reveal planned #{kind}") do
    challenge = make.call(kind, 654)
    traces = challenge[:participants].to_h do |seat|
      [seat, bot.plan(challenge, seat: seat, seed: 123, resources: resources)]
    end
    protocol = GameRoomDuckRacing::PrivateRound
    state = private_state(seats: challenge[:participants], commit_deadline_ms: nil)
    prepared = traces.to_h { |seat, trace| [seat, prepare_private(state, seat, trace, page_builder: private_page_builder(state))] }
    prepared.each do |seat, submission|
      assert(commit_private(state, submission, seat, now_ms: 1_000 + traces[seat]["finished_at"]))
      public = protocol.public_view(state)
      assert_equal([], public.keys & %i[trace actions score scores results answers choices])
    end
    now = 1_000 + traces.values.map { |trace| trace["finished_at"] }.max
    assert(protocol.close_commits(state, now_ms: now))
    page_count = 0
    prepared.to_a.reverse.each do |seat, submission|
      submission.reveal_plans.reverse.each do |plan|
        assert(deliver_private(state, plan, seat, now_ms: now + 1))
        page_count += 1
      end
    end
    assert_equal(:finished, state[:phase])
    assert(page_count > 2, "Simon was not tested through pagination") if kind == "simon"
    check_replay = verifier.new(challenge: challenge, balances: {0 => 100, 2 => 100}, resources: resources)
    adapter = Object.new
    adapter.define_singleton_method(:replay) do |traces:, forfeits:|
      check_replay.replay(traces: traces, forfeits: forfeits.keys)
    end
    assert_equal(check_replay.replay(traces: traces, forfeits: []), protocol.replay(state, adapter: adapter))
  end
end

sequential_types.each do |kind|
  40.times do |seed|
    check.call("sequential #{kind}/seed#{seed}") do
      challenge = make.call(kind, seed)
      state = engine.start(challenge)
      memories, presses = {0 => {}, 2 => {}}, {0 => 0, 2 => 0}
      now, steps = 0, 0
      until engine.finished?(state)
        challenge[:participants].each do |seat|
          memories[seat] = bot.observe(engine.view(state, seat: seat), memory: memories[seat])
          assert(memories[seat][:tones].length <= 10)
        end
        turn = engine.current_turn(state)
        view = engine.view(state, seat: turn)
        before = Marshal.dump([view, memories[turn]])
        choice = bot.choose_sequential(view, seat: turn, seed: seed, memory: memories[turn], press_id: presses[turn] + 1)
        assert(choice, "No sequential decision")
        assert_equal(choice, bot.choose_sequential(view, seat: turn, seed: seed, memory: memories[turn], press_id: presses[turn] + 1))
        assert_equal(before, Marshal.dump([view, memories[turn]]), "Sequential selector mutated its input")
        assert_equal(nil, bot.choose_sequential(view, seat: 77, seed: seed, press_id: 1))
        other = challenge[:participants].find { |seat| seat != turn }
        assert_equal(nil, bot.choose_sequential(engine.view(state, seat: other), seat: other, seed: seed, press_id: presses[other] + 1))
        at = now + choice[:delay_ms]
        engine.expire(state, now_ms: at)
        break if engine.finished?(state)
        assert(engine.submit(state, seat: turn, action: choice[:action], now_ms: at), "Sequential choice rejected")
        memories[turn] = choice[:memory]
        presses[turn] += 1
        now, steps = at, steps + 1
        assert(steps <= 120)
      end
      results = challenge[:participants].to_h { |seat| [seat, engine.result_for(state, seat)] }
      resolved = engine.settlement(kind, balances: {0 => 100, 2 => 100}, results: results)
      assert_equal(200, resolved.balances.values.sum + resolved.burned.values.sum)
      assert_equal(nil, bot.choose_sequential(engine.view(state, seat: 0), seat: 0, seed: seed, press_id: presses[0] + 1))
    end
  end
end

check.call("sound memory hears only public events, not concealed pairs") do
  view = {type: "sound_memory", seats: [0, 2], finished: false,
    public: {turn: 0, removed: [], revealed: [{position: 3, tone: 4}], sound_serial: 9,
      sound_event: {id: 9, position: 3, tone: 4}}, private: {pairs: [1] * 10}}
  memory = {tones: {7 => 4, 5 => 2}, serial: 8}
  before = Marshal.dump([view, memory])
  decision = bot.choose_sequential(view, seat: 0, seed: 1, memory: memory, press_id: 1)
  assert_equal(7, decision[:action][:value])
  assert_equal({3 => 4, 7 => 4, 5 => 2}, decision[:memory][:tones])
  assert_equal(before, Marshal.dump([view, memory]))
  assert_equal(decision[:memory], bot.observe(view, memory: decision[:memory]))
  stale = view.merge(public: view[:public].merge(sound_serial: 7, revealed: [{position: 7, tone: 1}], removed: [3]))
  assert_equal(decision[:memory], bot.observe(stale, memory: decision[:memory]))
  removed = view.merge(public: view[:public].merge(revealed: [], removed: [3, 7]))
  assert_equal({5 => 2}, bot.observe(removed, memory: decision[:memory])[:tones])
  view[:private] = {pairs: [5] * 10}
  assert_equal(decision, bot.choose_sequential(view, seat: 0, seed: 1, memory: memory, press_id: 1))
  assert_raises(ArgumentError) { bot.choose_sequential(view, seat: 0, seed: 1, press_id: 0) }
end unless turn_only

report_dir = File.expand_path("../../../tmp/duck-racing", __dir__)
FileUtils.mkdir_p(report_dir)
report_path = File.join(report_dir, "challenge-bot-local.json")
report = File.file?(report_path) ? JSON.parse(File.read(report_path)) : {"runs" => []}
run = {scope: "Pure model bot traces and public sequential decisions; no live accounts or full test runner",
  filter: turn_only ? "numeric turns and private RPS" : nil,
  cases: cases, private_traces: trace_count, simon_score_range: simon_scores.minmax,
  reaction_times: times.transform_values { |values| {minimum_ms: values.min, maximum_ms: values.max, distinct: values.uniq.length} },
  failures: cases.count { |entry| entry[:status] == "FAIL" }}
report["runs"] << run
File.write(report_path, JSON.pretty_generate(report) + "\n")
cases.select { |entry| entry[:status] == "FAIL" }.each { |entry| warn "FAIL #{entry[:name]}: #{entry[:error]}" }
raise "#{run[:failures]} challenge bot checks failed" unless run[:failures].zero?
puts "PASS #{cases.length} challenge bot scenarios; #{trace_count} private traces; #{private_types.length} private types and #{sequential_types.length} sequential types"
