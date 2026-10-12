require_relative "assertions"
require_relative "../../games/duck_racing_support/private_round"

# Helpers only: importing this file does not run a test scenario.
module DuckPrivateRoundTest
  include GameRoomTest::Assertions
  PRIVATE_ROUND = GameRoomDuckRacing::PrivateRound
  REPOSITORY = Object.new.tap do |repository|
    def repository.actor_of(event, _session); event.fetch("author"); end
  end

  class CaptureReplay
    attr_reader :received, :calls
    def initialize; @calls = 0; end
    def replay(traces:, forfeits:)
      @calls += 1
      @received = {traces: traces, forfeits: forfeits}
    end
  end

  def private_state(**overrides)
    PRIVATE_ROUND.start(**{session_id: 91, round_id: "match-1/challenge-2", seats: [0, 1],
      started_at_ms: 1_000, commit_deadline_ms: 50_000, reveal_timeout_ms: 5_000}.merge(overrides))
  end

  def input_trace(value = "rock", count: 1, kind: "choose")
    actions = Array.new(count) do |index|
      {"at" => index * 10 + 100, "input" => {"kind" => kind, "value" => value, "press_id" => index + 1}}
    end
    {"actions" => actions, "finished_at" => actions.last&.fetch("at") || 0}
  end

  def prepare_private(state, seat, trace, vault: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new), **options)
    PRIVATE_ROUND.prepare(state, seat: seat, user: "account-#{seat}", trace: trace,
      vault: vault, nonce: format("%064x", seat + 1), **options)
  end

  def private_events(plan, seat)
    GameRoomEventProtocol.validate_commands!(plan.events)
    plan.events.map do |command|
      {"action" => command.action, "value" => command.value, "author" => seat}
    end
  end

  # Keep pagination/recovery fixtures genuinely multipart even when a more
  # compact codec fits the same inputs into fewer bytes. Native packet budgets
  # (including controller metadata) have their own adapter tests.
  def private_page_builder(state, max_bytes: 200)
    lambda do |page|
      raise ArgumentError, "Fixture page limit" if PRIVATE_ROUND.reveal_page_size(page) > max_bytes
      GameRoomGames::ActionPlan.new(events: GameRoomActionPayload.commands(PRIVATE_ROUND.reveal_action(state), page))
    end
  end

  def private_pages(state, plan, seat)
    PRIVATE_ROUND.each_reveal_page(state, events: private_events(plan, seat),
      repository: REPOSITORY, session: nil).to_a
  end

  def commit_private(state, prepared, seat, now_ms: 2_000)
    assert_equal(1, prepared.commit_plan.events.length)
    command = prepared.commit_plan.events.first
    assert_equal(PRIVATE_ROUND::COMMIT_ACTION, command.action)
    GameRoomEventProtocol.validate_commands!(prepared.commit_plan.events)
    PRIVATE_ROUND.accept_commit(state, seat: seat, value: command.value, now_ms: now_ms)
  end

  def deliver_private(state, plan, seat, now_ms: 2_001)
    pages = private_pages(state, plan, seat)
    assert_equal(1, pages.length, "The atomic action was not decoded as one page")
    page, actor, originals = pages.first
    assert_equal(seat, actor)
    assert_equal(plan.events.length, originals.length)
    PRIVATE_ROUND.accept_reveal_page(state, seat: actor, page: page, now_ms: now_ms)
  end

  def rejected_unchanged(state)
    before = Marshal.dump(state)
    assert_equal(false, yield, "Unexpected acceptance")
    assert_equal(before, Marshal.dump(state), "Rejected input mutated private-round state")
  end
end
