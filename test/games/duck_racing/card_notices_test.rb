# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'

include DuckGameAdapterTest

h = Harness.new
game = h.game
players = %w[Alice Bob]
cases = 0
LOGIC::Cards::TYPES.each do |type|
  seed = h.seed_for(type.id)
  targets = case type.target
  when :any then [0, 1]
  when :opponent then [1]
  else [nil]
  end
  targets.each do |target|
    # A real reducer play from a naturally dealt card, not a fabricated notice.
    state = LOGIC::Race.start(player_count: 2, laps: 3, seed: seed,
      enabled_challenges: ['copy_number'])
    card = state[:racers][0][:hand].find { |copy| copy.type == type.id }
    assert(card, "The natural deal lacks #{type.id}")
    accepted = LOGIC::Race.new(state).apply(seat: 0, revision: 0,
      action: {kind: :play, card: card.id, target: target})
    assert(accepted, "The real reducer rejected #{type.id}/#{target}")
    before = Marshal.dump(state)
    notices = state[:notices]
    history = []
    game.send(:append_notices, history, notices, 103, players)
    assert_equal(before, Marshal.dump(state), "Presentation changed #{type.id} state or RNG")

    retained = notices.reject { |kind, *_args| kind == :played && type.target == :square }
    effects_only = history.reject { |entry| [:scenery, :displacement].include?(entry.kind) }
    expected_kinds = retained.map do |kind, _id, challenge, _participants, _initiator, origin|
      kind == :challenge && challenge == 'quiz' && [:square_question, :question_card].include?(origin) ? :quiz_question : kind
    end
    assert_equal(expected_kinds, effects_only.map(&:kind), "Lost or reordered effects of #{type.id}")
    expected_moves = retained.count { |kind, _seat, movement, distance| kind == :moved && distance && !movement.finished }
    assert_equal(expected_moves, history.count { |entry| entry.kind == :displacement })
    assert(effects_only.all? { |entry| entry.event_id == 103 && entry.actor == '' })
    assert(history.all? { |entry| entry.event_id == 103 })
    if type.target == :square
      assert_equal(0, history.count { |entry| entry.kind == :played }, "Duplicate placement of #{type.id}")
      assert_equal(1, history.count { |entry| entry.kind == :placed })
      assert_equal("Alice leaves #{game.card_name(type.id)} on square 1 (On the line).", history.first.text)
    else
      expected = if target.nil? || target.zero?
        "Alice plays #{game.card_name(type.id)}."
      else
        "Alice plays #{game.card_name(type.id)} on Bob."
      end
      assert_equal(expected, history.first.text)
      assert_equal(1, history.count { |entry| entry.kind == :played })
    end
    # Every effect retains its existing full message, independent of the
    # shorter play line. No hand/feather/challenge state is removed.
    effects = []
    game.send(:append_notices, effects, notices.reject { |kind, *_args| [:played, :placed].include?(kind) }, 103, players)
    assert_equal(effects.map(&:text), history.reject { |entry| [:played, :placed].include?(entry.kind) }.map(&:text))
    cases += 1
  end
end

%w[super_challenge hand_mix curiosity].each do |card|
  history = []
  game.send(:append_notices, history, [[:played, 0, card, 0]], 201, players)
  assert_equal("Alice plays #{game.card_name(card)}.", history.fetch(0).text)
  assert_equal(1, history.first.text.scan('Alice').length, "Global #{card} mentions its actor as target")
end

result = LOGIC::Settlement.difference(balances: {0 => 18, 1 => 18}, scores: {0 => 10, 1 => 6})
history = []
game.send(:append_notices, history,
  [[:played, 0, 'mine', 0], [:placed, 0, 'mine', 2],
    [:trap, 1, 'mine', 0], [:feathers, 1, -4],
    [:challenge_details, 'simon', {0 => {score: 10}, 1 => {score: 6}}, nil],
    [:challenge_result, 2, result]], 202, players)
assert_equal([:placed, :trap, :feathers, :challenge_details, :challenge_result], history.map(&:kind))
assert_equal('Bob lands on Mine, left by Alice.', history[1].text)
assert_equal('Bob loses 4 feathers.', history[2].text)
assert_equal("Alice: 10 sounds.\nBob: 6 sounds.", history[3].text)
assert_equal("Alice wins.\nAlice takes 4 feathers from Bob.", history[4].text)
assert(history.none? { |entry| entry.text.include?("\r") || entry.text.match?(/\n\n|\A\n|\n\z/) },
  'The combined card/challenge history contains noncanonical or blank lines')

puts "PASS concise card history: #{cases} actual plays across all #{LOGIC::Cards::TYPES.size} cards, self/other targets, one placement notice, effects and settlement preserved"
