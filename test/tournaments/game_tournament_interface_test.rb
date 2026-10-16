require_relative '../support/tournament_ft2b1_entry'
require_relative '../../games/catalog'
require_relative '../../lib/game_simulation'
require_relative '../../lib/tournaments/game_result'
require_relative '../../lib/tournaments/standings'
include GameRoomTest::Assertions
module Session
  def self.name; 'AuthenticatedUser'; end
end unless defined?(Session)
registry = GameRoomGames::CATALOG
registry.ids.each do |id|
  game = registry.build(id)
  capability = registry.tournament_capabilities(id)
  assert_equal(1, capability[:version])
  assert(capability[:player_counts].is_a?(Array), "Missing counts for #{id}")
  assert(game.respond_to?(:tournament_result), "Missing result contract for #{id}")
end
future = Class.new(GameRoomGames::TicTacToe) do
  def id; 'future-game'; end
end
new_registry = GameRoomGames::Registry.new([future])
assert_equal([2], new_registry.tournament_capabilities('future-game')[:player_counts])
assert_equal(['future-game'], new_registry.tournament_ids)
game = new_registry.build('future-game')
repository = GameRoomSimulation::Repository.new(%w[Ala Bartek])
session = {'__players' => %w[Ala Bartek], 'options' => {}}
make_events = lambda do |coordinates|
  coordinates.each_with_index.map do |value, index|
    encoded = value.split(',').map { |coordinate| coordinate.to_i + 1 }.join(',')
    {'id' => index + 1, 'actor' => index.even? ? 'Ala' : 'Bartek', 'action' => 'place', 'value' => encoded}
  end
end
win = game.replay(session, make_events.call(%w[0,0 0,1 1,0 1,1 2,0]), repository)
assert_equal(5, win.accepted_events.size)
assert_equal(nil, win.state)
assert_equal(['Ala'], game.tournament_result(win)[:winners])
assert_equal(nil, game.tournament_result(win)[:scores])
people = %w[Ala Bartek].map { |name| {'username' => name, 'account' => name.downcase, 'team' => nil} }
mapped = GameRoomTournaments::GameResult.from_replay(game: game, replay: win, players: people, options: {}, event_count: 5)
assert_equal(['ala'], mapped['winners'])
entry = mapped.slice('participants', 'winners', 'scores').merge('id' => 'future-game-result')
table = GameRoomTournaments::Standings.calculate(units: %w[ala bartek], results: [entry])
assert_equal(1, table.first['wins'])
assert_equal(nil, table.first['score_for'])
assert_raises(GameRoomTournaments::Publication::Invalid) do
  GameRoomTournaments::GameResult.from_replay(game: game, replay: win, players: people, options: {}, event_count: 6)
end

game.define_singleton_method(:tournament_scores) { |_replay, options:| {'Ala' => 1, 'Bartek' => 0} }
game.define_singleton_method(:tournament_export_scores) { |_replay, options:| {'Ala' => 10, 'Bartek' => 3} }
legacy = GameRoomTournaments::GameResult.from_replay(game: game, replay: win, players: people, options: {}, event_count: 5)
modern = GameRoomTournaments::GameResult.from_replay(game: game, replay: win, players: people, options: {}, event_count: 5,
  result_policy: GameRoomTournaments::GameResult::SCORE_EXPORT_POLICY)
assert_equal({'ala' => 1, 'bartek' => 0}, legacy['scores'])
assert_equal({'ala' => 10, 'bartek' => 3}, modern['scores'])
ordered = GameRoomTournaments::GameResult.from_replay(game: game, replay: win, players: people, options: {}, event_count: 5,
  result_policy: GameRoomTournaments::GameResult::CURRENT_RESULT_POLICY)
assert_equal('higher', ordered['score_order'])
assert_equal(modern['scores'], ordered['scores'])
['ascending', nil, 1, :lower].each do |order|
  game.define_singleton_method(:tournament_export_small_scores) { |_replay, options:| {scores: {'Ala' => 10, 'Bartek' => 3}, order: order} }
  assert_raises(GameRoomTournaments::Publication::Invalid) do
    GameRoomTournaments::GameResult.from_replay(game: game, replay: win, players: people, options: {}, event_count: 5,
      result_policy: GameRoomTournaments::GameResult::CURRENT_RESULT_POLICY)
  end
end
game.singleton_class.remove_method(:tournament_export_small_scores)
game.define_singleton_method(:tournament_export_scores) { |_replay, options:| {'Ala' => Float::NAN, 'Bartek' => 3} }
assert_raises(GameRoomTournaments::Publication::Invalid) do
  GameRoomTournaments::GameResult.from_replay(game: game, replay: win, players: people, options: {}, event_count: 5,
    result_policy: GameRoomTournaments::GameResult::SCORE_EXPORT_POLICY)
end
game.singleton_class.remove_method(:tournament_scores, :tournament_export_scores)
draw = game.replay(session, make_events.call(%w[0,0 1,0 2,0 1,1 0,1 2,1 1,2 0,2 2,2]), repository)
assert_equal(true, draw.draw)
assert_equal([], game.tournament_result(draw)[:winners])
unfinished = game.replay(session, [], repository)
assert_raises(GameRoomGames::Base::Tournaments::InvalidResult) { game.tournament_result(unfinished) }
puts "PASS inherited tournament interface for #{registry.ids.size} registered games and a future game; real board win/draw without state"
