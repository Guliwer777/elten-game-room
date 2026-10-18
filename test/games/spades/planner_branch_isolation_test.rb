require_relative '../../../lib/game_simulation'
require_relative '../../../games/spades'
require_relative '../../support/assertions'
include GameRoomTest::Assertions

checks = 0
[[3, 0, false], [4, 2, false], [6, 2, true]].each do |count, team_size, quicksand|
  game = GameRoomGames::Spades.new
  players = Array.new(count) { |index| "Player#{index}" }
  environment = GameRoomSimulation::Environment.new_game(game: game, players: players,
    options: {'team_size' => team_size, 'quicksand' => quicksand}, seed: 71)
  while environment.replay.state[:phase] == :bidding
    actor = environment.active_actor
    choice = environment.legal_actions(actor).find { |action| action['bid'] == 1 }
    assert(environment.step(choice, actor: actor) == :ok, 'real bidding rejected')
  end
  while environment.replay.state[:hands].values.sum(&:length) > count * 2
    assert(environment.step(environment.legal_actions.first) == :ok, 'real play setup rejected')
  end
  replay, actor = environment.replay, environment.active_actor
  before = Marshal.dump(replay)
  first = game.bot_decision_context(replay, actor)
  assert(game.send(:spades_round_planner).last_failure.nil?, 'normal planner silently fell back')
  assert_equal(before, Marshal.dump(replay), 'full planning mutated the replay')
  warm = game.bot_decision_context(replay, actor)
  cold_game = GameRoomGames::Spades.new
  cold = cold_game.bot_decision_context(replay, actor)
  assert_equal(first, warm, 'cached planning changed the same decision context')
  assert_equal(first, cold, 'warm and cold planning disagree')

  changed = Marshal.load(before)
  others = players.reject { |player| player == actor }
  cards = others.flat_map { |player| changed.state[:hands].fetch(player) }.reverse
  others.each do |player|
    changed.state[:hands][player] = cards.shift(changed.state[:hands].fetch(player).length)
  end
  changed_before = Marshal.dump(changed)
  private_permutation = game.bot_decision_context(changed, actor)
  assert_equal(first, private_permutation, 'fair context reads actual hidden locations')
  assert_equal(changed_before, Marshal.dump(changed), 'planning mutated a permuted source')

  source = GameRoomRandom::SeededSource.new(28)
  alternate = GameRoomRandom::SeededSource.new(28)
  arguments = {actions: environment.legal_actions, actor: actor, game: game}
  choice = game.bot_strategy.choose(**arguments, replay: replay, random_source: source)
  other_choice = game.bot_strategy.choose(**arguments, replay: changed, random_source: alternate)
  assert(arguments[:actions].include?(choice), 'planner chose outside the legal candidate list')
  assert_equal(choice, other_choice, 'hidden locations affected actual fair choice')
  assert_equal(source.roll(count: 8, sides: 100).values, alternate.roll(count: 8, sides: 100).values,
    'hidden locations affected decision RNG consumption')
  assert_equal(before, Marshal.dump(replay), 'strategy mutated the replay')
  checks += 1
end
puts "PASS Spades branch isolation: #{checks} real-model tails, team/quicksand, cold/warm cache, hidden permutation, legal choice and RNG"
