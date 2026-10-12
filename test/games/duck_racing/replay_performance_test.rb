require_relative "bots_helpers"
require_relative "../../../lib/game_repository"
include DuckBotFixture

# A long legal model session is generated incrementally, then independently
# decoded by the actual game adapter. Timings are observations, not portable
# performance guarantees and not a measurement of UI/network latency.
def benchmark(samples)
  Array.new(samples) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
  end.sort.then { |values| {min_ms: values.first.round(3), median_ms: values[values.length / 2].round(3), max_ms: values.last.round(3)} }
end

h = DuckBotFixture::Fixture.new(kind: "simon", count: 8, seed: 17, laps: 10)
# This pure fixture has no native transport metadata provider. Supply its
# explicit, server-observed grant instead of depending on a missing limit.
original_context = h.method(:context)
h.define_singleton_method(:context) do |now|
  value = original_context.call(now)
  value.local_data['duck_stack_entry_bytes'] = 1536
  value
end
seed_data = {"action" => "start", "revision" => 0, "session" => 777, "seed" => 17,
  "at" => 1_000, "fingerprint" => DuckBotFixture::FINGERPRINT}
GameRoomActionPayload.commands("duck_racing", seed_data).each do |event|
  h.events << {"__id" => h.events.length + 1, "actor" => h.players[0], "action" => event.action, "value" => event.value}
end
repository = GameRepository.allocate
session = {"__id" => 777, "__players" => h.players, "__table_owner" => h.players[0], "player_one" => h.players[0],
  "table_id" => 777, "options" => JSON.generate(h.state[:options])}
wire = -> do
  h.events.map do |row|
    row.merge("__insertion_user" => h.players[0], "__authority_user" => h.players[0], "__controller" => true)
  end
end
samples, logical, now, rounds = [], 1, 1_100, 0
full_race = ENV["DUCK_LONG_PERFORMANCE"] == "1"
largest_private = nil
record = lambda do |label|
  events = wire.call
  expected = semantic(h.state[:race])
  replay = nil
  cold = benchmark(3) do
    replay = GAME.new(resources: DuckBotFixture.resources).replay(session, events, repository)
  end
  h.game.replay(session, events, repository)
  timing = benchmark(3) { replay = h.game.replay(session, events, repository) }
  assert_equal(events.length, replay.accepted_events.length)
  assert_equal(expected, semantic(replay.state[:race]), "The long replay differs from the incremental model")
  actors = h.game.active_actors(replay)
  legal = benchmark(100) { actors.each { |actor| h.game.legal_actions(replay, actor) } }
  final_batch, final_data = nil, nil
  GameRoomActionPayload.each(events, h.game.id, repository, session) do |data, _, batch|
    final_batch, final_data = batch, data
  end
  preceding = events.first(events.length - final_batch.length)
  append_samples = Array.new(3) do
    game = GAME.new(resources: DuckBotFixture.resources)
    game.replay(session, preceding, repository)
    time = benchmark(1) do
      replay = game.replay(session, events, repository)
    end.fetch(:median_ms)
    assert_equal(expected, semantic(replay.state[:race]), 'Appending the final action differs from cold replay')
    time
  end.sort
  incremental = {min_ms: append_samples.first, median_ms: append_samples[1], max_ms: append_samples.last}
  entry = h.game.instance_variable_get(:@duck_replay_cache)&.instance_variable_get(:@entry)
  samples << {label: label, logical_actions: logical, wire_fragments: events.length,
    wire_bytes: JSON.generate(events).bytesize, completed_challenges: rounds, replay: timing,
    cold_replay: cold, appended_action: final_data['action'], appended_fragments: final_batch.length,
    append_replay: incremental, cache_bytes: entry&.checkpoint&.bytesize, legal_actions_all_actors: legal}
end
record.call("start")

apply = lambda do |action, seat = 0, at = nil|
  now = at || now + 1
  h.apply(action, seat: seat, at: now)
  logical += 1
end

until h.replay.finished? || (!full_race && rounds >= 32)
  raise "Long model session exceeded its finite action budget" if logical > 8_000
  round = h.state[:round]
  if round
    id = round[:challenge][:id]
    round[:challenge][:participants].each do |seat|
      apply.call({"kind" => "duck", "action" => "ready", "challenge" => id,
        "fingerprint" => DuckBotFixture::FINGERPRINT}, seat)
    end
    apply.call({"kind" => "duck", "action" => "begin", "challenge" => id})
    round = h.state[:round]
    assert(round[:private], "Performance fixture unexpectedly opened a non-private challenge")
    plans = round[:challenge][:participants].to_h do |seat|
      [seat, LOGIC::ChallengeBot.plan(round[:challenge], seat: seat, seed: 63 + seat * 11, resources: DuckBotFixture.resources)]
    end
    finish_at = now + plans.values.map { |trace| trace.fetch("finished_at") }.max
    pulse = now + 30_000
    while pulse < finish_at
      round[:challenge][:participants].each do |seat|
        apply.call({"kind" => "duck", "action" => "alive", "challenge" => id}, seat, pulse)
      end
      pulse += 30_000
    end
    plans.each do |seat, trace|
      apply.call({"kind" => "duck", "action" => "submit_trace", "challenge" => id, "trace" => trace}, seat, finish_at)
    end
    apply.call({"kind" => "duck", "action" => "advance", "challenge" => id})
    while h.state[:round] && h.state[:round][:challenge][:id] == id
      protocol = h.state[:round][:private]
      assert(protocol && protocol[:phase] == :revealing)
      bytes = Marshal.dump(protocol).bytesize
      if !largest_private || bytes > largest_private[:bytes]
        active = LOGIC::Session.copy(h.state)
        # While another seat is still answering, legal_actions must not inspect
        # or validate thousands of concealed input entries held by others.
        active[:round][:private][:phase] = :collecting
        pending_seat = active[:round][:challenge][:participants].last
        active[:round][:private][:commitments].delete(pending_seat)
        candidate = h.replay.dup
        candidate.state = active
        actor = h.players[pending_seat]
        sample = benchmark(200) { assert_equal(1, h.game.legal_actions(candidate, actor).length) }
        largest_private = {bytes: bytes, pages: protocol[:pages].values.sum(&:length), timing: sample,
          note: "Controlled collecting-view snapshot retains the large protocol; this isolated cost probe is not an accepted state transition"}
      end
      seat = round[:challenge][:participants].find { |member| !protocol[:reveals].key?(member) }
      prepared = LOGIC::PrivateRound.recover(protocol, seat: seat, user: h.players[seat], vault: h.vault)
      page = LOGIC::PrivateRound.next_reveal_page(protocol, prepared)
      assert(page)
      apply.call({"kind" => "duck", "action" => "reveal", "challenge" => id, "page" => page}, seat)
    end
    assert_equal(id, h.state[:last_resolution][:id])
    assert(h.state[:last_resolution][:settlement], "A long valid challenge was cancelled")
    rounds += 1
    record.call("challenge #{rounds}") if [1, 3, 8, 16, 32].include?(rounds)
  else
    seat = h.state[:race][:turn]
    racer = h.state[:race][:racers].fetch(seat)
    action = if racer[:frozen_turns].positive? || racer[:skip_turns].positive?
      {"kind" => "duck", "action" => "race", "input" => {"kind" => "skip"}}
    else
      actions = h.game.legal_actions(h.replay, h.players[seat])
      # Deterministic public-information policy. No injected cards or positions.
      # Prioritize a real dealt group challenge to exercise large private traces.
      actions.find do |choice|
        physical = racer[:hand].find { |card| card.id == choice.dig("input", "card") }
        physical && physical.type == "super_challenge"
      end || actions.first
    end
    apply.call(action, seat)
  end
end
record.call(h.replay.finished? ? "finished race" : "bounded 32-challenge prefix")
assert(rounds >= 8, "The fixture did not exercise a long session")
assert(largest_private[:bytes] > 10_000, "Private trace fixture was too small")
report_dir = File.expand_path("../../../tmp/duck-racing", __dir__)
FileUtils.mkdir_p(report_dir)
path = File.join(report_dir, "replay-performance-local.json")
report = File.file?(path) ? JSON.parse(File.read(path)) : {"runs" => []}
run = {scope: "Eight-seat ten-lap model race, actual wire codec/full replay; no UI, real network or live account",
  status: "PASS", authenticated_prefix_cache: true, full_race: h.replay.finished?, logical_actions: logical,
  rounds: rounds, samples: samples, largest_private: largest_private}
report["runs"] << run
File.write(path, JSON.pretty_generate(report) + "\n")
puts JSON.pretty_generate(run)
