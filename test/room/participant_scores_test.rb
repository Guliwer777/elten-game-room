def _(text)
  text
end

require_relative "../../games/base"
require_relative "../../games/farkle"
require_relative "../../games/tysiac"
require_relative "../../games/spades"
require_relative "../../games/categories"
require_relative "../../games/ninety_nine"
require_relative "../../lib/room_presentation"
require_relative "../../lib/lobby_repository"

def assert(condition, message)
  raise message unless condition
end

class ScoreRepository
  def initialize(players)
    @players = players
  end

  def players_for(_session)
    @players
  end
end

players = %w[Alice Bob Carol Dave]
[GameRoomGames::Farkle, GameRoomGames::Tysiac, GameRoomGames::Categories].each do |type|
  game = type.new
  contestants = players.first(game.minimum_players)
  repository = ScoreRepository.new(contestants)
  session = { "options" => JSON.generate(game.default_options) }
  replay = game.replay(session, [], repository)
  scores = game.participant_scores(replay)
  assert(!scores.empty? && scores.values.all?(&:zero?), "#{game.id} omitted real zero-point scores")
  scored_player = scores.keys.first
  replay.state[:scores][scored_player] = 125
  assert(game.participant_scores(replay)[scored_player] == 125, "#{game.id} did not expose updated points")
  scores[scored_player] = 999
  assert(replay.state[:scores][scored_player] == 125, "#{game.id} exposed mutable game scores to the UI")
  fresh = game.replay(session, [], repository)
  assert(game.participant_scores(fresh).values.all?(&:zero?), "#{game.id} carried old scores into a new game")
end

spades = GameRoomGames::Spades.new
options = spades.with_team_assignment(spades.normalize_options("team_size" => 2), players: players, seats: [0, 1, 0, 1])
replay = spades.replay({ "options" => JSON.generate(options) }, [], ScoreRepository.new(players))
scoring = GameRoomGames::Spades::Scoring.new(players, options)
first_unit, second_unit = scoring.unit_ids
replay.state[:scores][first_unit] = -20
replay.state[:scores][second_unit] = 50
scores = spades.participant_scores(replay)
assert(scoring.members_for(first_unit).all? { |player| scores[player] == -20 }, "Spades lost a negative team score")
assert(scoring.members_for(second_unit).all? { |player| scores[player] == 50 }, "Spades assigned another team's score")
assert(scores.keys.sort == players.sort, "team scores were exposed as fictitious participants")

room = LobbyRepository::TableSnapshot.new(
  table: { "__id" => 7, "max_players" => 8 }, members: players + ["Observer"], bots: []
)
rows = RoomPresentation.game_users(room: room, game: spades, replay: replay, players: players, owner: "Alice", options: options)
assert(rows.find { |row| row.participant == "Alice" }.label.include?("-20 points"), "user list omitted the current score")
assert(!rows.find { |row| row.participant == "Observer" }.label.include?("points"), "observer received a fabricated score")
replay.winner = "Alice"
finished_rows = RoomPresentation.game_users(room: room, game: spades, replay: replay, players: players, owner: "Alice", options: options)
assert(finished_rows.find { |row| row.participant == "Alice" }.label.include?("-20 points"), "finished game lost its final scores")

tokens_game = GameRoomGames::NinetyNine.new
tokens_replay = tokens_game.replay({"options" => JSON.generate(tokens_game.default_options)}, [], ScoreRepository.new(players))
tokens = tokens_game.participant_scores(tokens_replay)
assert(tokens == tokens_replay.state.fetch(:tokens), "99 omitted its actual remaining tokens")
tokens[players.first] = 999
assert(tokens_replay.state.fetch(:tokens).fetch(players.first) != 999, "99 exposed mutable token scores")
rows = RoomPresentation.game_users(room: room, game: tokens_game, replay: nil, players: [], owner: "Alice")
assert(rows.none? { |row| row.label.include?("points") }, "a waiting room has fabricated scores")
labels = RoomPresentation.user_labels(["alice", "Observer"], owner: "Alice", players: ["Alice"], active: true, scores: { "Alice" => 0 })
assert(labels.first.include?("0 points") && !labels.last.include?("points"), "zero score or case-insensitive participant mapping is wrong")
puts "Participant score presentation tests passed"
