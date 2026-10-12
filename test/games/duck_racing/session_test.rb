require "json"
require "fileutils"
require_relative "../../support/assertions"
require_relative "../../support/elten_array_shuffle"
require_relative "../../../games/duck_racing_support/session"
require_relative "../../../games/duck_racing_support/challenge_bot"
require_relative "../../../games/duck_racing_support/wire_budget"
require_relative "../../../content/languages"

include GameRoomTest::Assertions

# MODEL-ONLY fixtures. Cards and positions below are explicit controlled
# initial conditions, not claims about a live account or a natural deal.
# Every transition after arranging them passes through Session.apply on a
# candidate copy, just as the caller contract requires.
module DuckSessionFixture
  include GameRoomTest::Assertions
  SESSION = GameRoomDuckRacing::Session
  ENGINE = GameRoomDuckRacing::ChallengeEngine
  BOT = GameRoomDuckRacing::ChallengeBot
  PROTOCOL = GameRoomDuckRacing::PrivateRound
  FINGERPRINT = "a" * 64

  def semantic(value)
    case value
    when Hash then value.transform_values { |item| semantic(item) }
    when Array then value.map { |item| semantic(item) }
    when Random then Marshal.dump(value)
    when Data then [value.class.name, semantic(value.to_h)]
    else value
    end
  end

  class Harness
    include GameRoomTest::Assertions
    include DuckSessionFixture
    attr_reader :state, :resources, :events

    def initialize(kind: "copy_number", count: 2, seed: 771, resources: {}, state: nil)
      @resources, @events = resources, []
      @state = state || SESSION.initial(session_id: 417, player_count: count, laps: 3,
        enabled_challenges: [kind], fingerprint: FINGERPRINT)
      accept("start", seed: seed, moderator: true, at: 1_000) unless state
    end

    def act(action, seat: 0, moderator: false, at:, **fields)
      data = {"action" => action, "revision" => @state[:revision]}
      data["challenge"] = @state[:round][:challenge][:id] if @state[:round]
      fields.each { |key, value| data[key.to_s] = value }
      before = Marshal.dump(@state)
      candidate = SESSION.copy(@state)
      accepted = SESSION.apply(candidate, data, seat: seat, moderator: moderator, now_ms: at, resources: @resources)
      assert_equal(before, Marshal.dump(@state), "Candidate reducer mutated accepted state")
      if accepted
        @state = candidate
        @events << [SESSION.copy(data), seat, moderator, at]
      end
      accepted
    end

    def accept(action, **arguments)
      assert(act(action, **arguments), "Session rejected #{action} #{arguments.inspect}")
    end

    def reject(action, **arguments)
      before = Marshal.dump(@state)
      assert_equal(false, act(action, **arguments), "Session accepted invalid #{action} #{arguments.inspect}")
      assert_equal(before, Marshal.dump(@state))
    end

    def positions(*values)
      @state[:race][:occupants] = {}
      values.each_with_index do |progress, seat|
        @state[:race][:racers][seat][:progress] = progress
        GameRoomDuckRacing::Board.arrive!(@state[:race][:occupants], seat, GameRoomDuckRacing::Board.square(progress))
      end
    end

    def give(type, seat: 0)
      card = GameRoomDuckRacing::Cards::Copy.new("session-fixture-#{seat}-#{type}", type)
      @state[:race][:racers][seat][:hand] << card
      card
    end

    def play(type, target: nil, at: 1_100)
      card = give(type)
      accept("race", input: {"kind" => "play", "card" => card.id, "target" => target}, at: at)
      card
    end

    def challenge(group: true, at: 1_100)
      play(group ? "super_challenge" : "challenge", target: group ? nil : 1, at: at)
      assert_equal(:preparing, @state[:round][:phase])
      @state[:round][:challenge]
    end

    def begin_round(at: 1_200, moderator: 0, reverse: false)
      round = @state.fetch(:round)
      stale = @state[:revision]
      seats = round[:challenge][:participants]
      seats = seats.reverse if reverse
      seats.each { |seat| accept("ready", seat: seat, fingerprint: FINGERPRINT, revision: stale, at: at - 1) }
      assert_equal("begin", SESSION.automatic(@state, now_ms: at))
      accept("begin", seat: moderator, moderator: true, at: at)
      assert_equal(:playing, @state[:round][:phase])
    end

    def prepare(traces, page_builder: nil)
      round = @state.fetch(:round)
      traces.to_h do |seat, trace|
        vault = HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)
        [seat, PROTOCOL.prepare(round[:private], seat: seat, user: "fixture-#{seat}", trace: trace,
          vault: vault, nonce: format("%064x", seat + 1), page_builder: page_builder)]
      end
    end

    def traces(seed: 1)
      challenge = @state.fetch(:round).fetch(:challenge)
      challenge[:participants].to_h { |seat| [seat, BOT.plan(challenge, seat: seat, seed: seed, resources: @resources)] }
    end

    def pulse_until(elapsed)
      start = @state.fetch(:round).fetch(:started_at)
      30_000.step(elapsed, 30_000) do |offset|
        @state[:round][:challenge][:participants].each do |seat|
          accept("alive", seat: seat, at: start + offset)
        end
        assert_equal(nil, SESSION.automatic(@state, now_ms: start + offset))
      end
    end

    def commit_all(prepared, at:, reverse: false)
      stale = @state[:revision] - 1
      order = reverse ? prepared.keys.reverse : prepared.keys
      order.each { |seat| accept("commit", seat: seat, revision: stale, value: prepared[seat].commit_value, at: at) }
    end

    def reveal_all(prepared, at:, reverse: false)
      stale, id = @state[:revision] - 1, @state[:round][:challenge][:id]
      pages = prepared.flat_map { |seat, submission| submission.reveal_pages.map { |page| [seat, page] } }
      pages.reverse! if reverse
      pages.each { |seat, page| accept("reveal", seat: seat, challenge: id, revision: stale, page: page, at: at) }
    end

    def resolve_private(reverse: false, traces: nil, seed: 1)
      traces ||= self.traces(seed: seed)
      prepared = prepare(traces)
      elapsed = traces.values.map { |trace| trace["finished_at"] }.max
      pulse_until(elapsed)
      now = @state[:round][:started_at] + elapsed + 1
      commit_all(prepared, at: now, reverse: reverse)
      assert_equal("advance", SESSION.automatic(@state, now_ms: now))
      accept("advance", moderator: true, at: now + 1)
      reveal_all(prepared, at: now + 2, reverse: reverse)
      [traces, prepared, now + 2]
    end

    def changed(seats, at:)
      candidate = SESSION.copy(@state)
      accepted = SESSION.participants_changed(candidate, seats: seats, now_ms: at)
      @state = candidate if accepted
      accepted
    end
  end
end

include DuckSessionFixture
registry = GameRoomContent::Registry.new
registry.register_language(GameRoomContent::LanguageProfile.new(id: "en", label: "English", alphabet: ("a".."z").to_a,
  normalizer: ->(value) { value.downcase }))
registry.register_pack(GameRoomContent::Pack.new(id: "test.duck.session.quiz", set_id: "test.duck.session.quiz", kind: "quiz",
  language_id: "en", version: 1, title: "Test", game_ids: ["quiz"], data: {"questions" => [
    {"id" => "q", "category" => "Test", "prompt" => "How many wheels?", "correct" => "four", "wrong" => %w[one two three]}
  ]}))
resources = {questions: GameRoomDuckRacing::QuestionSets.prepare_selected(ids: ["test.duck.session.quiz"], language: "en", registry: registry)}
cases = []
case_filter = Regexp.new(ENV.fetch("DUCK_SESSION_CASE")) if ENV.key?("DUCK_SESSION_CASE")
check = lambda do |name, &block|
  next if case_filter && !case_filter.match?(name)

  block.call
  cases << {name: name, status: "PASS"}
rescue StandardError => error
  cases << {name: name, status: "FAIL", error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(5)}
end

check.call("setup, start, physical card, stale revision, roll and skipped turn") do
  h = Harness.new(resources: resources)
  assert_equal(18, h.state[:race][:racers][0][:feathers])
  assert_equal([3, 3], h.state[:race][:racers].values.map { |racer| racer[:hand].size })
  h.reject("start", moderator: true, seed: 1, at: 1_001)
  h.reject("race", seat: 1, input: {"kind" => "roll"}, at: 1_010)
  h.reject("race", revision: 0, input: {"kind" => "roll"}, at: 1_010)
  h.positions(31, 8)
  card = h.play("tiny_recoil")
  assert_equal(29, h.state[:race][:racers][0][:progress])
  h.reject("race", input: {"kind" => "play", "card" => card.id}, at: 1_150)
  h.accept("race", input: {"kind" => "roll"}, at: 1_200)
  assert(h.state[:race][:racers][0][:progress] > 29)

  h = Harness.new(resources: resources)
  h.play("sandwich")
  h.reject("race", input: {"kind" => "skip"}, at: 1_200)
  h.reject("race", input: {"kind" => "roll"}, at: 1_200)
  h.accept("race", input: {"kind" => "skip"}, moderator: true, at: 1_200)
  assert_equal(1, h.state[:race][:turn])
  initial = SESSION.initial(session_id: 1, player_count: 2, laps: 3, enabled_challenges: ["dice_duel"], fingerprint: FINGERPRINT)
  assert_equal(false, SESSION.apply(SESSION.copy(initial), {"action" => "start", "revision" => 0, "seed" => 1},
    seat: 0, moderator: false, now_ms: 1))
  assert_raises(ArgumentError) do
    SESSION.initial(session_id: 1, player_count: 4, laps: 3, enabled_challenges: ["rock_paper_scissors"], fingerprint: FINGERPRINT)
  end
end

check.call("ready fingerprint, duplicate readiness, owner authority and nonparticipant") do
  h = Harness.new(count: 4, resources: resources)
  h.challenge(group: false)
  h.reject("ready", seat: 2, fingerprint: FINGERPRINT, at: 1_101)
  h.reject("ready", seat: 0, fingerprint: "b" * 64, at: 1_101)
  h.reject("begin", moderator: true, at: 1_101)
  h.accept("ready", fingerprint: FINGERPRINT, at: 1_102)
  h.reject("ready", fingerprint: FINGERPRINT, at: 1_103)
  h.accept("ready", seat: 1, fingerprint: FINGERPRINT, revision: 0, at: 1_104)
  h.reject("begin", seat: 2, at: 1_105)
  h.reject("begin", seat: 2, moderator: true, revision: 0, at: 1_105)
  h.accept("begin", seat: 2, moderator: true, at: 1_106)
  h.reject("alive", seat: 2, at: 40_000)
  h.reject("commit", seat: 2, value: "bad", at: 40_000)
  h.reject("cancel", seat: 2, reason: "technical", at: 40_000)
end

(BOT::PRIVATE_TYPES - ENGINE::FIRST_ANSWER).each do |kind|
  3.times do |seed|
    check.call("private #{kind}/seed#{seed}: complete and permuted concurrent messages") do
      count = kind == "rock_paper_scissors" ? 2 : [2, 3, 8][seed]
      baseline = Harness.new(kind: kind, count: count, seed: seed, resources: resources)
      baseline.challenge
      baseline.begin_round
      fork = Harness.new(resources: resources, state: SESSION.copy(baseline.state))
      challenge, balances = SESSION.copy(baseline.state[:round][:challenge]), baseline.state[:round][:balances].dup
      traces, prepared, completed_at = baseline.resolve_private(seed: seed)
      fork.resolve_private(reverse: true, traces: traces)
      expected = GameRoomDuckRacing::TraceVerifier.new(challenge: challenge, balances: balances, resources: resources)
        .replay(traces: traces, forfeits: {})
      assert_equal(expected.results, baseline.state[:last_resolution][:results])
      assert_equal(expected.settlement, baseline.state[:last_resolution][:settlement])
      assert_equal(nil, baseline.state[:round])
      assert_equal(:turn, baseline.state[:race][:phase])
      assert_equal(semantic(baseline.state), semantic(fork.state), "Commit/reveal order changed the settled race")
      assert(baseline.state[:race][:card_played])
      assert_equal(0, baseline.state[:race][:turn])
      baseline.reject("commit", challenge: challenge[:id], value: prepared.values.first.commit_value, at: completed_at + 1)
      baseline.reject("reveal", challenge: challenge[:id], page: prepared.values.first.reveal_page(0), at: completed_at + 1)
      baseline.accept("race", input: {"kind" => "roll"}, at: completed_at + 2)
    end
  end
end

check.call("private wrong phase, repeated commit, invalid page and invalid trace cancellation") do
  h = Harness.new(kind: "rock_paper_scissors", resources: resources)
  h.challenge
  h.reject("commit", value: "premature", at: 1_101)
  h.begin_round
  traces = h.traces
  traces[0] = {"actions" => [{"at" => 100, "input" => {"kind" => "roll", "press_id" => 1}}], "finished_at" => 100}
  prepared = h.prepare(traces)
  h.reject("reveal", page: prepared[0].reveal_page(0), at: 1_201)
  h.reject("commit", value: "invalid digest", at: 1_201)
  h.accept("commit", value: prepared[0].commit_value, at: 5_000)
  h.reject("commit", value: prepared[0].commit_value, at: 5_001)
  h.reject("advance", moderator: true, at: 5_002)
  h.accept("commit", seat: 1, value: prepared[1].commit_value, at: 5_003)
  h.accept("advance", moderator: true, at: 5_004)
  bad = prepared[0].reveal_page(0).merge("nonce" => "f" * 64)
  h.reject("reveal", page: bad, at: 5_005)
  balances = h.state[:round][:balances]
  h.reveal_all(prepared, at: 5_006)
  assert_equal(:invalid_trace, h.state[:last_resolution][:cancelled])
  assert_equal(balances, h.state[:race][:racers].transform_values { |racer| racer[:feathers] })
  assert_equal(nil, h.state[:round])
end

check.call("first accepted correct answer settles immediately regardless of local response times") do
  h = Harness.new(resources: resources)
  h.challenge
  h.begin_round
  challenge = h.state[:round][:challenge]
  traces = [0, 1].to_h do |seat|
    trace = GameRoomDuckRacing::ChallengeTrace.new(challenge, seat: seat, resources: resources)
    question = ENGINE.view(trace.state, seat: seat).fetch(:question)
    assert(trace.submit({kind: :answer, value: question[:number], press_id: 1}, at: seat.zero? ? 1_000 : 5_000))
    [seat, trace.snapshot]
  end
  [0, 1].each do |first|
    fork = Harness.new(resources: resources, state: SESSION.copy(h.state))
    fork.accept("attempt", seat: first, trace: traces.fetch(first), at: 10_000)
    assert_equal(first, fork.state[:last_resolution][:settlement].winner)
    assert_equal(first.zero? ? [22, 14] : [14, 22],
      fork.state[:race][:racers].values.map { |racer| racer[:feathers] })
    assert_equal(nil, fork.state[:round])
    fork.reject("attempt", seat: 1 - first, challenge: challenge[:id],
      trace: traces.fetch(1 - first), at: 10_001)
  end
end

ENGINE::SEQUENTIAL.each do |kind|
  12.times do |seed|
    check.call("sequential #{kind}/#{seed}: full game with current revisions") do
      h = Harness.new(kind: kind, seed: seed, resources: resources)
      h.challenge
      h.begin_round
      memories, presses, now, steps = {0 => {}, 1 => {}}, {0 => 0, 1 => 0}, 1_200, 0
      id = h.state[:round][:challenge][:id]
      until h.state[:round].nil?
        model = h.state[:round][:engine]
        [0, 1].each { |seat| memories[seat] = BOT.observe(ENGINE.view(model, seat: seat), memory: memories[seat]) }
        turn = ENGINE.current_turn(model)
        choice = BOT.choose_sequential(ENGINE.view(model, seat: turn), seat: turn, seed: seed,
          memory: memories[turn], press_id: presses[turn] + 1)
        assert(choice)
        now += choice[:delay_ms]
        if SESSION.automatic(h.state, now_ms: now) == "advance"
          h.accept("advance", moderator: true, at: now)
          next
        end
        h.reject("input", seat: 1 - turn, input: choice[:action], at: now)
        old_revision = h.state[:revision]
        h.accept("input", seat: turn, input: choice[:action], at: now)
        if %w[dice_duel blackjack risky_dice].include?(kind)
          notices = h.state[:notices].select { |entry| [:challenge_roll, :challenge_draw, :challenge_stand].include?(entry[0]) }
          assert_equal(1, notices.length, "One accepted input must publish its one action notice")
          expected_kind = {"roll" => :challenge_roll, "hit" => :challenge_draw,
            "stand" => :challenge_stand, "save" => :challenge_stand}.fetch(choice[:action].fetch(:kind).to_s)
          assert_equal([expected_kind, turn], notices.first.first(2))
        end
        h.reject("input", seat: turn, revision: old_revision, challenge: id, input: choice[:action], at: now)
        h.reject("input", seat: turn, challenge: id, input: choice[:action], at: now)
        memories[turn], presses[turn] = choice[:memory], presses[turn] + 1
        steps += 1
        assert(steps < 120)
      end
      assert_equal(kind, h.state[:last_resolution][:kind])
      assert(h.state[:last_resolution][:settlement])
      assert_equal(:turn, h.state[:race][:phase])
    end
  end
end

%w[dice_duel blackjack risky_dice].each do |kind|
  check.call("sequential #{kind}: exact and sparse timeouts finish only the current player") do
    h = Harness.new(kind: kind, resources: resources)
    h.challenge
    h.begin_round
    round, model = h.state[:round], h.state[:round][:engine]
    first_turn = ENGINE.current_turn(model)
    assert_equal(2, model[:model][:players].count { |_seat, player| !player[:done] },
      "This fixture needs both participants to have a decision")
    interval = kind == "dice_duel" ? 10_000 : 30_000
    first_deadline = round[:started_at] + interval
    before = Marshal.dump(h.state)
    assert_equal(nil, SESSION.automatic(h.state, now_ms: first_deadline - 1))
    assert_equal("advance", SESSION.automatic(h.state, now_ms: first_deadline))
    assert_equal(before, Marshal.dump(h.state), "Automatic probing must not consume the pending roll")
    action = kind == "blackjack" ? "stand" : "roll"
    h.reject("input", seat: first_turn, input: {"kind" => action, "press_id" => 1}, at: first_deadline)
    h.accept("advance", moderator: true, at: first_deadline)
    current = h.state[:round][:engine]
    assert(current[:model][:players].fetch(first_turn)[:done])
    assert_equal(1, current[:model][:players].count { |_seat, player| player[:done] })
    assert_equal(1 - first_turn, ENGINE.current_turn(current))
    assert_equal(interval, current[:model][:turn_started_at_ms])
    assert_equal(interval * 2, current[:model][:deadline_ms])
    expected_notices = {"dice_duel" => [:challenge_roll], "blackjack" => [:challenge_stand],
      "risky_dice" => [:challenge_roll, :challenge_stand]}.fetch(kind)
    turn_notices = h.state[:notices].reject { |notice| notice[0] == :challenge_hand }
    assert_equal(expected_notices, turn_notices.map(&:first))
    assert(turn_notices.all? { |notice| notice[1] == first_turn })
    hands = h.state[:notices].select { |notice| notice[0] == :challenge_hand }
    assert_equal(kind == 'blackjack' ? [1 - first_turn] : [], hands.map { |notice| notice[1] })
    h.reject("advance", moderator: true, at: first_deadline)
    h.accept("advance", moderator: true, at: first_deadline + interval + 1_000)
    assert_equal(nil, h.state[:round])
    assert_equal(expected_notices, h.state[:notices].select { |entry| expected_notices.include?(entry[0]) }.map(&:first))
    assert_equal(:turn, h.state[:race][:phase])

    late = Harness.new(kind: kind, resources: resources)
    late.challenge
    late.begin_round
    late.accept("advance", moderator: true, at: first_deadline + interval + 1_000)
    assert_equal(nil, late.state[:round])
    assert_equal(expected_notices * 2,
      late.state[:notices].select { |entry| expected_notices.include?(entry[0]) }.map(&:first))
    assert_equal(semantic(h.state[:last_resolution]), semantic(late.state[:last_resolution]),
      "Sparse polling must keep the same rolls and settlement as deadline-by-deadline processing")
    late.reject("advance", moderator: true, at: first_deadline + interval + 1_000)
  end
end

check.call("sequential deadline at exact boundary and automatic without mutating RNG") do
  h = Harness.new(kind: "numbered_balls", resources: resources)
  h.challenge
  h.begin_round
  model = h.state[:round][:engine]
  turn = ENGINE.view(model, seat: 0)[:turn_seat]
  before = Marshal.dump(h.state)
  assert_equal(nil, SESSION.automatic(h.state, now_ms: 61_199))
  assert_equal("advance", SESSION.automatic(h.state, now_ms: 61_200))
  assert_equal(before, Marshal.dump(h.state))
  h.reject("input", seat: turn, input: {kind: :take, value: 3, press_id: 1}, at: 61_200)
  h.accept("advance", moderator: true, at: 61_200)
  current = ENGINE.view(h.state[:round][:engine], seat: 0)
  assert_equal(11, current[:remaining].length)
  assert_equal(1 - turn, current[:turn_seat])
  h.reject("advance", moderator: true, at: 61_200)
end

ENGINE::REALTIME.each do |kind|
  [0, 1].each do |winner|
    check.call("native #{kind} winner#{winner}: five-feather receipt once") do
      h = Harness.new(kind: kind, resources: resources)
      h.challenge
      h.begin_round
      id = h.state[:round][:challenge][:id]
      receipt = {"epoch" => "native-epoch", "id" => id, "kind" => kind,
        "participants" => [0, 1], "point" => "0:#{winner}", "winner" => winner}
      assert_equal(nil, SESSION.automatic(h.state, now_ms: 1_000_000))
      h.reject("point", receipt: receipt, at: 1_500)
      h.accept("point", moderator: true, receipt: receipt, at: 1_501)
      assert_equal(23, h.state[:race][:racers][winner][:feathers])
      assert_equal(13, h.state[:race][:racers][1 - winner][:feathers])
      assert_equal(receipt, h.state[:point_receipt])
      assert_equal(nil, h.state[:round])
      h.reject("point", moderator: true, challenge: id, receipt: receipt, at: 1_502)
    end
  end
  check.call("native #{kind}: timeout receipt, insufficient feathers and freeze") do
    h = Harness.new(kind: kind, resources: resources)
    h.state[:race][:racers][0][:feathers] = 3
    h.challenge
    h.begin_round
    id = h.state[:round][:challenge][:id]
    receipt = {"epoch" => "native-epoch", "id" => id, "kind" => kind,
      "participants" => [0, 1], "point" => "0:1:timeout", "winner" => 1}
    h.accept("point", moderator: true, receipt: receipt, at: 1_501)
    assert_equal([0, 21], h.state[:race][:racers].values.map { |racer| racer[:feathers] })
    assert(h.state[:race][:racers][0][:frozen_turns].positive?)
    h.reject("race", input: {"kind" => "roll"}, at: 1_600)
    h.accept("race", input: {"kind" => "skip"}, moderator: true, at: 1_601)
    assert_equal(1, h.state[:race][:turn])
  end
end

check.call("point malformed receipts are rejected without exceptions") do
  h = Harness.new(kind: "axel_pong", resources: resources)
  h.challenge
  h.begin_round
  receipt = {"epoch" => "native-epoch", "id" => h.state[:round][:challenge][:id], "kind" => "axel_pong",
    "participants" => [0, 1], "point" => "0:0", "winner" => 0}
  [receipt.merge("id" => 999), receipt.merge("kind" => "audio_ball"), receipt.merge("participants" => [1, 0]),
    receipt.merge("epoch" => ""), receipt.merge("point" => "1:0"), receipt.merge("winner" => 1),
    receipt.merge("winner" => 0.0)].each do |bad|
    h.reject("point", moderator: true, receipt: bad, at: 1_500)
  end
end

check.call("cancel at 90 seconds without a pulse, not at 89999 ms") do
  h = Harness.new(resources: resources)
  h.challenge
  original = h.state[:round][:balances]
  assert_equal(nil, SESSION.automatic(h.state, now_ms: 91_099))
  assert_equal("cancel", SESSION.automatic(h.state, now_ms: 91_100))
  h.reject("cancel", moderator: true, at: 91_099)
  h.accept("cancel", moderator: true, at: 91_100)
  assert_equal(:unresponsive, h.state[:last_resolution][:cancelled])
  assert_equal(original, h.state[:race][:racers].transform_values { |racer| racer[:feathers] })
  assert_equal(nil, h.state[:round])
end

check.call("one active player cannot mask the other participant's silence") do
  h = Harness.new(resources: resources)
  h.challenge
  h.begin_round
  [31_200, 61_200, 91_200].each { |time| h.accept("alive", at: time) }
  assert_equal("cancel", SESSION.automatic(h.state, now_ms: 91_200))
  h.accept("cancel", moderator: true, at: 91_200)
  assert_equal(:unresponsive, h.state[:last_resolution][:cancelled])
end

check.call("technical cancellation and participant replacement versus unrelated seat") do
  h = Harness.new(count: 4, resources: resources)
  h.challenge(group: false)
  h.begin_round(moderator: 2)
  id = h.state[:round][:challenge][:id]
  before = Marshal.dump(h.state)
  assert_equal(false, h.changed([2], at: 1_500))
  assert_equal(false, h.changed([], at: 1_500))
  assert_equal(before, Marshal.dump(h.state))
  balances = h.state[:race][:racers].transform_values { |racer| racer[:feathers] }
  assert(h.changed([1], at: 1_600))
  assert_equal(:participant_changed, h.state[:last_resolution][:cancelled])
  assert_equal(balances, h.state[:race][:racers].transform_values { |racer| racer[:feathers] })
  assert_equal(false, h.changed([1], at: 1_601))
  h.reject("ready", challenge: id, fingerprint: FINGERPRINT, at: 1_602)
  h.reject("commit", challenge: id, value: "late", at: 1_602)
  h = Harness.new(resources: resources)
  h.challenge
  h.accept("cancel", seat: 1, reason: "technical", at: 1_101)
  assert_equal(:technical, h.state[:last_resolution][:cancelled])
  assert_equal(nil, h.state[:round])
end

check.call("save, finish by moving card and no input after completed race") do
  h = Harness.new(resources: resources)
  h.positions(88, 8)
  card = h.give("helix")
  restored = Harness.new(resources: resources, state: SESSION.copy(h.state))
  [h, restored].each do |copy|
    copy.accept("race", input: {"kind" => "play", "card" => card.id, "target" => 0}, at: 1_100)
    assert_equal(:finished, copy.state[:race][:phase])
    assert_equal(0, copy.state[:race][:winner])
    assert_equal(nil, copy.state[:round])
    copy.reject("start", moderator: true, seed: 3, at: 1_101)
    copy.reject("race", input: {"kind" => "roll"}, at: 1_101)
  end
  assert_equal(semantic(h.state), semantic(restored.state))
end

check.call("long human Simon exceeds 30 tones and 10 minutes with 30-second pulses") do
  h = Harness.new(kind: "simon", resources: resources)
  h.challenge
  h.begin_round
  challenge = h.state[:round][:challenge]
  trace = GameRoomDuckRacing::ChallengeTrace.new(challenge, seat: 0, resources: resources)
  now, press = 0, 0
  until trace.finished?
    playback = ENGINE.stimulus(trace.state, seat: 0)
    now = playback[:requested_ms] + playback[:events].map { |event| event[:offset_ms] + event[:duration_ms] }.max
    assert(trace.submit({kind: :playback_finished, playback_id: playback[:id]}, at: now))
    playback[:events].each do |event|
      now, press = now + 600, press + 1
      tone = playback[:events].length > 40 ? event[:tone] % 5 + 1 : event[:tone]
      assert(trace.submit({kind: :tone, value: tone, press_id: press}, at: now))
      break if trace.finished?
    end
  end
  assert(now > 600_000)
  traces = {0 => trace.snapshot, 1 => trace.snapshot}
  assert_equal(nil, h.state[:round][:private][:commit_deadline_ms])
  h.resolve_private(traces: traces)
  assert_equal({0 => {score: 40}, 1 => {score: 40}}, h.state[:last_resolution][:results])
  assert_equal([18, 18], h.state[:race][:racers].values.map { |racer| racer[:feathers] })
end

check.call("alive pulses do not hide a stalled reveal upload after 90 seconds") do
  h = Harness.new(kind: "rock_paper_scissors", resources: resources)
  h.challenge
  h.begin_round
  prepared = h.prepare(h.traces)
  original = h.state[:round][:balances]
  id = h.state[:round][:challenge][:id]
  h.commit_all(prepared, at: 5_000)
  h.accept("advance", moderator: true, at: 5_001)
  [35_001, 65_001].each do |time|
    [0, 1].each { |seat| h.accept("alive", seat: seat, at: time) }
    assert_equal(nil, SESSION.automatic(h.state, now_ms: time))
  end
  assert_equal(nil, SESSION.automatic(h.state, now_ms: 95_000))
  [0, 1].each { |seat| h.accept("alive", seat: seat, at: 95_001) }
  assert_equal("cancel", SESSION.automatic(h.state, now_ms: 95_001))
  h.accept("cancel", moderator: true, at: 95_001)
  assert_equal(:unresponsive, h.state[:last_resolution][:cancelled])
  assert_equal(original, h.state[:race][:racers].transform_values { |racer| racer[:feathers] })
  assert_equal(nil, h.state[:round])
  h.reject("reveal", challenge: id, page: prepared[0].reveal_page(0), at: 95_002)
end

check.call("real paged reveal progress extends the upload deadline") do
  h = Harness.new(kind: "simon", resources: resources)
  h.challenge
  h.begin_round
  traces = h.traces(seed: 143)
  wire_replay = GameRoomGames::Replay.new(accepted_events: [], state: {session_id: h.state[:session_id], bot_controller_epoch: 'initial'})
  page_builder = lambda do |page|
    GameRoomDuckRacing::WireBudget.plan('duck_racing', {'action' => 'reveal', 'page' => page,
      'challenge' => h.state[:round][:challenge][:id], 'at' => 1_791_682_353_483, 'revision' => 99,
      'session' => h.state[:session_id]}, replay: wire_replay, actor: 'fixture-0', limit: 1536)
  end
  prepared = h.prepare(traces, page_builder: page_builder)
  elapsed = traces.values.map { |trace| trace["finished_at"] }.max
  h.pulse_until(elapsed)
  now = h.state[:round][:started_at] + elapsed + 1
  h.commit_all(prepared, at: now)
  h.accept("advance", moderator: true, at: now + 1)
  pages = prepared[0].reveal_pages
  assert(pages.length >= 3, "The fixture must genuinely span several pages")
  prepared[1].reveal_pages.each { |page| h.accept("reveal", seat: 1, page: page, at: now + 2) }
  pages.each_with_index do |page, index|
    at = now + 80_000 * (index + 1)
    assert_equal(nil, SESSION.automatic(h.state, now_ms: at))
    h.accept("reveal", page: page, at: at)
    next if h.state[:round].nil?
    assert_equal(at + 90_000, h.state[:round][:private][:reveal_deadlines][0])
    assert_equal(nil, SESSION.automatic(h.state, now_ms: at + 89_999))
  end
  assert_equal(nil, h.state[:round])
  assert(h.state[:last_resolution][:settlement])
end

check.call("moderator skips another blocked seat without gaining control of its ordinary actions") do
  h = Harness.new(resources: resources)
  own_card = h.give("tiny_recoil", seat: 1)
  h.reject("race", seat: 1, moderator: true, input: {"kind" => "skip"}, at: 1_010)
  h.reject("race", seat: 1, moderator: true, input: {"kind" => "roll"}, at: 1_010)
  h.reject("race", seat: 1, moderator: true,
    input: {"kind" => "play", "card" => own_card.id}, at: 1_010)
  h.play("sandwich")
  assert_equal(0, h.state[:race][:turn])
  h.reject("race", seat: 1, input: {"kind" => "skip"}, at: 1_200)
  h.reject("race", seat: 1, moderator: true, input: {"kind" => "roll"}, at: 1_200)
  h.accept("race", seat: 1, moderator: true, input: {"kind" => "skip"}, at: 1_200)
  assert_equal(1, h.state[:race][:turn])
  assert_equal(0, h.state[:race][:racers][0][:skip_turns])
  h.reject("race", seat: 0, moderator: true, input: {"kind" => "roll"}, at: 1_201)
end

[:finish, :cancel, :replacement].each do |path|
  check.call("chained square quiz then encounter uses new time after #{path}") do
    h = Harness.new(count: 3, resources: resources)
    h.positions(2, 6, 15)
    h.play("helix", target: 0)
    assert_equal("quiz", h.state[:round][:challenge][:kind])
    previous = h.state[:round][:challenge][:id]
    if path == :finish
      h.begin_round
      _traces, _prepared, now = h.resolve_private
    elsif path == :cancel
      now = 7_500
      h.accept("cancel", seat: 0, reason: "technical", at: now)
    else
      now = 9_000
      assert(h.changed([2], at: now))
    end
    assert_equal("copy_number", h.state[:round][:challenge][:kind])
    assert_equal([1, 0], h.state[:round][:challenge][:participants])
    assert_equal(now, h.state[:round][:created_at])
    assert_equal([now], h.state[:round][:last_seen].values.uniq)
    assert_equal(nil, SESSION.automatic(h.state, now_ms: now + 89_999))
    h.reject("ready", challenge: previous, fingerprint: FINGERPRINT, at: now + 1)
  end
end

check.call("Marshal mid-commit and mid-reveal, continuation and future RNG match") do
  h = Harness.new(kind: "simon", resources: resources)
  h.challenge
  h.begin_round
  traces = h.traces(seed: 143)
  prepared = h.prepare(traces)
  elapsed = traces.values.map { |trace| trace["finished_at"] }.max
  h.pulse_until(elapsed)
  at = h.state[:round][:started_at] + elapsed + 1
  h.accept("commit", value: prepared[0].commit_value, at: at)
  copies = [h, Harness.new(resources: resources, state: Marshal.load(Marshal.dump(h.state)))]
  copies.each do |copy|
    copy.accept("commit", seat: 1, value: prepared[1].commit_value, at: at)
    copy.accept("advance", moderator: true, at: at + 1)
    copy.accept("reveal", page: prepared[0].reveal_page(0), at: at + 2)
  end
  copies << Harness.new(resources: resources, state: Marshal.load(Marshal.dump(copies[0].state)))
  pages = prepared.flat_map { |seat, submission| submission.reveal_pages.each_with_index.map { |page, index| [seat, index, page] } }
  copies.each do |copy|
    pages.reject { |seat, index, _page| seat.zero? && index.zero? }.each do |seat, _index, page|
      copy.accept("reveal", seat: seat, page: page, at: at + 3)
    end
    copy.accept("race", input: {"kind" => "roll"}, at: at + 4)
  end
  assert_equal(1, copies.map { |copy| semantic(copy.state) }.uniq.length)
end

report_dir = File.expand_path("../../../tmp/duck-racing", __dir__)
FileUtils.mkdir_p(report_dir)
path = File.join(report_dir, "session-local.json")
report = File.file?(path) ? JSON.parse(File.read(path)) : {"runs" => []}
run = {scope: "Model-only Session candidate-copy transitions, not live accounts", filter: case_filter&.source, cases: cases,
  failures: cases.count { |entry| entry[:status] == "FAIL" }}
report["runs"] << run
File.write(path, JSON.pretty_generate(report) + "\n")
cases.select { |entry| entry[:status] == "FAIL" }.each { |entry| warn "FAIL #{entry[:name]}: #{entry[:error]}" }
raise "#{run[:failures]} session checks failed" unless run[:failures].zero?
raise "No session cases matched #{case_filter.inspect}" if cases.empty?
puts "PASS #{cases.length} Duck Racing session scenarios"
