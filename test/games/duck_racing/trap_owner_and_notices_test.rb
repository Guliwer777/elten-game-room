# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'
include DuckGameAdapterTest

game = Harness.new.game
results = []
check = lambda do |name, &test|
  test.call
  results << [name, 'PASS']
rescue StandardError => error
  results << [name, "FAIL: #{error.class}: #{error.message}"]
end
state_at = lambda do |positions|
  state = LOGIC::Race.start(player_count: positions.length, laps: 3, seed: 77,
    enabled_challenges: ['dice_duel'])
  state[:occupants] = {}
  positions.each_with_index do |progress, seat|
    state[:racers][seat][:progress] = progress
    LOGIC::Board.arrive!(state[:occupants], seat, LOGIC::Board.square(progress))
  end
  state
end
trap_on = lambda do |state, square, type, owner|
  state[:traps][square] = {card: LOGIC::Cards::Copy.new('placed-card', type), owner: owner}
end
roll_one = lambda do |state, seat|
  state[:turn] = seat
  state[:random] = Random.new((0..100).find { |seed| Random.new(seed).rand(6).zero? })
  assert(LOGIC::Race.new(state).apply(seat: seat, revision: state[:revision], action: {kind: :roll}))
end
render = lambda do |state|
  history = []
  game.send(:append_notices, history, state[:notices], 123, %w[Alice Bob Carol])
  history
end

%w[tar_stain oil_stain].each do |type|
  [0, 30].each do |lap_offset|
    check.call("#{type}: owner keeps the trap on lap #{lap_offset / 30 + 1}") do
      state = state_at.call([3 + lap_offset, 8, 16])
      trap = trap_on.call(state, 5, type, 0)
      balance = state[:racers][0][:feathers]
      hand_size = state[:racers][0][:hand].size
      roll_one.call(state, 0)
      assert_equal(trap, state[:traps][5])
      assert_equal(4 + lap_offset, state[:racers][0][:progress])
      assert_equal(balance + 1, state[:racers][0][:feathers])
      assert_equal(hand_size + 1, state[:racers][0][:hand].size)
      assert_equal(1, state[:turn])
      assert_equal([], state[:pending])
      assert(!state[:notices].any? { |notice| [:trap, :stole_feathers].include?(notice.first) })
      assert_equal([:rolled, :moved, :scenery, :feathers, :drew_cards], render.call(state).map(&:kind))
    end
  end

  check.call("#{type}: skipping own card still starts the encounter") do
    state = state_at.call([3, 4, 16])
    trap = trap_on.call(state, 5, type, 0)
    roll_one.call(state, 0)
    assert_equal(trap, state[:traps][5])
    assert_equal(:challenge, state[:phase])
    assert_equal([1, 0], state[:challenge][:participants])
  end

  check.call("#{type}: opponent activates the retained card exactly once") do
    state = state_at.call([3, 3, 16])
    trap_on.call(state, 5, type, 0)
    roll_one.call(state, 0)
    assert(state[:traps].key?(5))
    balance = state[:racers].transform_values { |racer| racer[:feathers] }
    roll_one.call(state, 1)
    amount = type == 'tar_stain' ? 4 : 2
    assert_equal(nil, state[:traps][5])
    assert_equal(balance[0] + amount, state[:racers][0][:feathers])
    assert_equal(balance[1] + 1 - amount, state[:racers][1][:feathers])
    assert_equal(type == 'tar_stain' ? 4 : 3, state[:racers][1][:progress])
    assert_equal(1, state[:notices].count { |notice| notice.first == :trap })
    assert_equal([[:stole_feathers, 0, 1, amount]], state[:notices].select { |notice| notice.first == :stole_feathers })
  end

  check.call("#{type}: owner immunity survives a question and copied continuation") do
    state = state_at.call([5, 6, 16])
    trap = trap_on.call(state, 7, type, 0)
    roll_one.call(state, 0)
    assert_equal(:square_question, state[:challenge][:trigger])
    assert_equal(trap, state[:traps][7])
    copy = Marshal.load(Marshal.dump(state))
    [state, copy].each do |current|
      balances = current[:racers].transform_values { |racer| racer[:feathers] }
      result = LOGIC::Settlement.fixed(balances: balances, winner: nil, amount: 0)
      assert(LOGIC::Race.new(current).complete_challenge(id: current[:challenge][:id], result: result))
      assert_equal(trap, current[:traps][7])
      assert_equal(:encounter, current[:challenge][:trigger])
      assert_equal([1, 0], current[:challenge][:participants])
      assert(!current[:notices].any? { |notice| notice.first == :trap })
    end
    assert_equal(DuckGameAdapterTest.semantic(state), DuckGameAdapterTest.semantic(copy))
  end
end

check.call('own non-stealing trap still activates') do
  state = state_at.call([20, 2, 8])
  trap_on.call(state, 22, 'mine', 0)
  roll_one.call(state, 0)
  assert_equal(nil, state[:traps][22])
  assert_equal(6, state[:racers][0][:progress])
  assert(state[:notices].any? { |notice| notice.first == :trap })
end

check.call('backward risk at the start reports no movement without reapplying the square') do
  state = state_at.call([0, 8, 16])
  card = LOGIC::Cards::Copy.new('risk', 'taste_for_risk')
  state[:racers][0][:hand] << card
  state[:random] = Random.new((0..100).find do |seed|
    random = Random.new(seed)
    random.rand(10)
    random.rand(2).zero?
  end)
  before = state[:racers][0].dup
  assert(LOGIC::Race.new(state).apply(seat: 0, revision: 0, action: {kind: :play, card: card.id}))
  assert_equal(0, state[:racers][0][:progress])
  assert_equal(before[:feathers] - 4, state[:racers][0][:feathers])
  assert_equal(before[:arrival], state[:racers][0][:arrival])
  assert_equal([:played, :stayed], state[:notices].map(&:first))
  assert_equal('Alice remains at the start.', render.call(state).last.text)
  assert_equal(nil, state[:challenge])
  assert_equal([], state[:pending])
  roll_one.call(state, 0)
  assert_equal(1, state[:racers][0][:progress])
end

check.call('challenge title is in history once, not repeated by automatic field speech') do
  LOGIC::Challenges::BY_ID.each_key do |kind|
    next if LOGIC::ChallengeEngine::REALTIME.include?(kind)
    view = ENGINE.view(challenge_state(kind), seat: 0)
    history = []
    game.send(:append_notices, history, [[:challenge, 1, kind, [0, 1], 0]], 123, %w[Alice Bob])
    title = LOGIC::ChallengePresentation.description(kind).first
    [0, nil].each do |viewer|
      projected = LOGIC::ChallengePresentation.project(kind: kind, view: view, viewer: viewer)
      assert(!projected[:announcement].include?(title), "#{kind}: duplicate title in automatic field speech")
      assert(projected[:header].include?(title), "#{kind}: title lost from manual inspection")
      assert_equal(1, (history.first.text + "\n" + projected[:announcement]).scan(game.challenge_name(kind) + '.').length, kind)
    end
  end
end

results.each { |name, status| puts "#{status}: #{name}" }
raise 'Duck trap/notice regressions failed' unless results.all? { |_name, status| status == 'PASS' }
