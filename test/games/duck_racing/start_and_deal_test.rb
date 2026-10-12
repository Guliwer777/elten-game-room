require_relative '../../support/duck_game_adapter'

include DuckGameAdapterTest
numeric = LOGIC::NumericChallenges
results = []
check = lambda do |name, &block|
  block.call
  results << {name: name, status: 'PASS'}
rescue StandardError => error
  results << {name: name, status: 'FAIL', error: "#{error.class}: #{error.message}", trace: error.backtrace.first(5)}
end

%w[dice_duel blackjack risky_dice].each do |kind|
  [2, 3, 8].each do |count|
    check.call("#{kind}: random starter, #{count} players, repeatable replay") do
      seats = [7, 2, 9, 4, 11, 3, 6, 1].first(count)
      seen = []
      64.times do |seed|
        state = numeric.start(kind, seats: seats, seed: seed, now_ms: 100)
        assert_equal(Marshal.dump(state), Marshal.dump(numeric.start(kind, seats: seats, seed: seed, now_ms: 100)))
        next if state[:finished]
        first = state[:participants].fetch(state[:turn_index])
        seen << first
        assert(!state[:players].fetch(first)[:done])
        order = seats.rotate(state[:turn_index]).reject { |seat| state[:players].fetch(seat)[:done] }
        order.each do |seat|
          assert_equal(seat, numeric.public_view(state, viewer: nil)[:turn_seat])
          assert(numeric.expire(state, now_ms: state[:deadline_ms]))
        end
        assert(state[:finished], 'A finished player returned to the turn order')
      end
      assert_equal(seats.sort, seen.uniq.sort, 'Only some participants can start')
    end
  end
end

check.call('blackjack: deal is announced on its turn, including a skipped natural 21') do
  deck = ->(cards) { cards + (numeric::BLACKJACK_CARDS - cards) }
  state = numeric.start('blackjack', seats: [0, 1], seed: 1, now_ms: 0,
    blackjack_decks: {0 => deck.call([0, 36]), 1 => deck.call([20, 40])})
  expected = [[:challenge_hand, 1, [6, 11], 16]]
  assert_equal(expected, state[:notices])
  assert_equal(1, numeric.public_view(state, viewer: nil)[:turn_seat], 'Natural 21 must not wait for input')
  observer = numeric.public_view(state, viewer: nil)
  assert_equal(expected, observer[:notices])
  observer[:notices][0][2] << 13
  assert_equal(expected, state[:notices], 'Public hand notices share mutable model data')
  assert(!observer.key?(:players) && !observer.key?(:deck))
  assert(numeric.submit(state, seat: 1, action: {kind: :stand, press_id: 1}, now_ms: 1))
  assert_equal([[:challenge_stand, 1, 16], [:challenge_hand, 0, [1, 10], 21]], state[:notices],
    'The automatic 21 must be announced after the preceding hand, not at the start')
  assert(state[:finished])
end

[2, 3, 8].each do |count|
  check.call("blackjack: #{count} initial hands reach accepted history exactly once") do
    h = Harness.new(kind: 'blackjack', count: count)
    h.open_round
    before = h.replay
    h.begin_round
    replay = h.replay
    model = replay.state[:round][:engine][:model]
    hands = replay.history.select { |entry| entry.kind == :challenge_hand }
    starter = LOGIC::ChallengeEngine.current_turn(replay.state[:round][:engine])
    assert_equal(1, hands.length, 'A waiting player was dealt aloud before their turn')
    assert(hands.first.text.start_with?(h.players.fetch(starter) + ' receives '))
    initial_hands = {}
    model[:players].each do |seat, player|
      ranks = player[:cards].map { |id| LOGIC::ChallengePresentation.card_rank(id / 4 + 1) }
      initial_hands[seat] = "#{h.players.fetch(seat)} receives #{ranks.join(', ')}. Total: #{player[:total]}."
    end
    announced = h.game.describe_event(h.events.last, h.repository, replay, 'Spectator')
    assert_equal(hands.map(&:text), announced.select { |text| hands.any? { |entry| entry.text == text } })
    assert(announced.include?("#{h.players.fetch(starter)}'s turn."), 'The random starter is not announced')
    cues = h.game.event_sound_cues(event: h.events.last, before_replay: before, after_replay: replay,
      history: replay.history.drop(before.history.length), viewer: 'Spectator', random_variant: 0)
    assert_equal(['draw'], cues, 'The initial deal should play the existing draw sound only once')
    while (round = h.replay.state[:round])
      seat = LOGIC::ChallengeEngine.current_turn(round[:engine])
      history = h.replay.history
      assert_equal(1, history.count { |entry| entry.kind == :challenge_hand && entry.text == initial_hands.fetch(seat) },
        'The current player has no initial hand announcement')
      prior_count = history.length
      h.accept({'action' => 'input', 'challenge' => round[:challenge][:id],
        'input' => {'kind' => 'stand', 'press_id' => 1}}, actor: h.players.fetch(seat))
      added = h.replay.history.drop(prior_count)
      assert_equal(:challenge_stand, added.first.kind, 'The next hand was spoken before the previous player stopped')
    end
    final_hands = h.replay.history.select { |entry| entry.kind == :challenge_hand }.map(&:text)
    assert_equal(initial_hands.values.sort, final_hands.sort, 'A hand was lost or repeated')
    order = model[:participants].rotate(model[:turn_index])
    assert_equal(order.map { |seat| initial_hands.fetch(seat) }, final_hands, 'Hands were announced out of turn')
    completed = h.replay
    session, events = Marshal.load(Marshal.dump([h.session, h.events]))
    rebuilt = h.game.replay(session, events, h.repository)
    assert_equal(DuckGameAdapterTest.semantic(completed), DuckGameAdapterTest.semantic(rebuilt),
      'Rebuilding copied accepted records changed the starter or cards')
    assert_equal(count, h.replay.state[:last_resolution][:results].length)
  end
end

[:stand, :maximum, :bust, :timeout, :late_timeout].each do |ending|
  check.call("blackjack: #{ending} reveals the next initial hand, not a second copy of the current one") do
    prefix = ->(cards) { cards + (numeric::BLACKJACK_CARDS - cards) }
    final_card = ending == :maximum ? 8 : 16 # After 10 + 8: rank 3 makes 21, rank 5 busts.
    state = numeric.start('blackjack', seats: [7, 2, 9], seed: 1, now_ms: 0,
      blackjack_decks: [7, 2, 9].to_h { |seat| [seat, prefix.call([36, 28, final_card])] })
    seats = state[:participants].rotate(state[:turn_index])
    assert_equal([seats.first], state[:notices].map { |notice| notice[1] })
    if [:timeout, :late_timeout].include?(ending)
      assert(numeric.expire(state, now_ms: ending == :timeout ? 30_000 : 90_000))
    else
      action = ending == :stand ? :stand : :hit
      assert(numeric.submit(state, seat: seats.first, action: {kind: action, press_id: 1}, now_ms: 1))
    end
    revealed = state[:notices].select { |notice| notice.first == :challenge_hand }
    assert_equal(ending == :late_timeout ? seats.drop(1) : [seats[1]], revealed.map { |notice| notice[1] })
    if ending == :late_timeout
      assert(state[:finished])
      assert_equal([:challenge_stand, :challenge_hand, :challenge_stand, :challenge_hand, :challenge_stand],
        state[:notices].map(&:first), 'Late processing must keep every turn in chronological order')
    else
      assert_equal(seats[1], numeric.public_view(state, viewer: nil)[:turn_seat])
      assert_equal(:maximum, state[:players][seats.first][:status]) if ending == :maximum
      assert_equal(:busted, state[:players][seats.first][:status]) if ending == :bust
    end
  end
end

check.call('blackjack: immediate all-natural finish preserves both initial hands') do
  seed = (0..10_000).find do |candidate|
    numeric.start('blackjack', seats: [0, 1], seed: candidate, now_ms: 0)[:finished]
  end
  assert(seed, 'No deterministic all-natural fixture')
  h = Harness.new(kind: 'blackjack')
  h.open_round
  # Model-only setup for the rare all-natural boundary; normal adapter cases
  # above use the immutable seed from a real start and challenge-card action.
  state = LOGIC::Session.copy(h.replay.state)
  state[:round][:challenge][:seed] = seed
  state[:round][:ready] = {0 => true, 1 => true}
  assert(LOGIC::Session.apply(state, {'action' => 'begin', 'revision' => state[:revision],
    'challenge' => state[:round][:challenge][:id]}, seat: 0, moderator: true,
    now_ms: h.now_ms + 1, resources: h.resources))
  assert_equal(nil, state[:round])
  assert_equal(2, state[:notices].count { |notice| notice.first == :challenge_hand })
  assert_equal([], state[:notices].select { |notice| notice.first == :challenge_turn })
end

puts JSON.pretty_generate(results)
raise 'Duck challenge starter/deal regression failed' unless results.all? { |row| row[:status] == 'PASS' }
