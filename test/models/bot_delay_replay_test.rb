require_relative "../support/ui"
require_relative "../support/log"

class Program
  def self.server_app(**_options); end
end

require_relative "../../__app"
require_relative "../../lib/bot_turn_gate"
require_relative '../support/catalog_options'

def assert(value, message)
  raise message unless value
end

class BotDelayReplayRepository
  def players_for(session); session.fetch("__players"); end
  def actor_of(event, _session = nil); event.fetch("actor"); end
  def event_id(event); event.fetch("__id"); end
end

repository = BotDelayReplayRepository.new
games = EltenGameRoom::GAME_REGISTRY.ids.map { |id| EltenGameRoom::GAME_REGISTRY.build(id) }
games.select!(&:supports_bot_move_delay?)
without_state = []

# Use each game's real replay, rather than manufacturing a state Hash. Simple
# board games legitimately store everything in Replay's board/player fields.
games.each do |game|
  profile = GameRoomTest::CatalogOptions.for_players(game, bots: true)
  count = (game.minimum_players..game.maximum_players).find { |size| !game.validation_error(profile, player_count: size) }
  players = ["bot:7:1"] + Array.new(count - 1) { |index| "Player#{index + 1}" }
  [0, 1, 5].each do |delay|
    options = profile.merge("bot_delay" => delay)
    session = {"__id" => 11, "__players" => players, "options" => JSON.generate(options)}
    replay = game.replay(session, [], repository)
    before = Marshal.dump(replay)
    context = GameRoomGames::ActionContext.new(options: game.options_from_json(session["options"]), now: 100)
    assert(game.bot_move_delay(replay, players.first, context: context) == delay,
      "#{game.id}: real initial replay lost configured delay #{delay}")
    assert(Marshal.dump(replay) == before, "#{game.id}: pacing mutated the replay")

    next unless replay.state.nil?

    without_state << game.id
    assert(game.bot_move_delay(replay, players.first) == game.default_bot_move_delay,
      "#{game.id}: absent context did not use default delay")
    empty_context = GameRoomGames::ActionContext.new(now: 100)
    assert(game.bot_move_delay(replay, players.first, context: empty_context) == game.default_bot_move_delay,
      "#{game.id}: context without options did not use default delay")
  end
end
assert(without_state.uniq.sort == %w[four_in_a_row tic_tac_toe], "Missing real nil-state regressions")

# Exercise the same scheduling call after a human move, then validate and
# replay a bot move. Waiting is simulated, with no sleeping or live clients.
without_state.uniq.each do |id|
  game = EltenGameRoom::GAME_REGISTRY.build(id)
  options = game.default_options.merge("bot_delay" => 3)
  session = {"__id" => 12, "__players" => ["Alice", "bot:7:1"], "options" => JSON.generate(options)}
  context = GameRoomGames::ActionContext.new(options: options, now: 100)
  replay = game.replay(session, [], repository)
  status, human_plan = game.action_for(game.legal_actions(replay, "Alice").first, replay, "Alice", context: context)
  assert(status == :ok, "#{id}: human fixture move rejected")
  events = human_plan.events.each_with_index.map do |event, index|
    {"__id" => index + 1, "actor" => "Alice", "action" => event.action, "value" => event.value}
  end
  replay = game.replay(session, events, repository)
  bot = replay.current_player
  assert(bot == "bot:7:1" && replay.state.nil?, "#{id}: fixture did not reach a nil-state bot turn")
  clock = 0.0
  controller = GameRoomBots::TurnController.new(clock: -> { clock })
  revision = [events.length, events.last.fetch("__id")]
  controller.schedule_decision(session_id: 12, actor: bot, revision: game.bot_delay_revision(replay, revision),
    delay: game.bot_move_delay(replay, bot, context: context))
  assert(!controller.acquire(session_id: 12, actor: bot, revision: revision), "#{id}: pacing was bypassed")
  clock = 3.0
  lease = controller.acquire(session_id: 12, actor: bot, revision: revision)
  assert(lease, "#{id}: bot did not become ready")
  status, bot_plan = game.action_for(game.legal_actions(replay, bot).first, replay, bot, context: context)
  assert(status == :ok, "#{id}: bot fixture move rejected")
  bot_plan.events.each do |event|
    events << {"__id" => events.length + 1, "actor" => bot, "action" => event.action, "value" => event.value}
  end
  replay = game.replay(session, events, repository)
  assert(replay.accepted_events.length == events.length && replay.current_player == "Alice",
    "#{id}: bot move did not advance the game")
end

# Existing deadline rules must still apply, including the special question
# and auction phases, with context options taking precedence over replay data.
game = GameRoomGames::TicTacToe.new
context = GameRoomGames::ActionContext.new(options: {"bot_delay" => 5}, now: 100)
[:playing, :answering, :auction].each do |phase|
  deadline_key = {playing: :turn_deadline, answering: :deadline, auction: :auction_deadline}.fetch(phase)
  state = {options: {"bot_delay" => 1}, phase: phase, deadline_key => 103.5}
  replay = GameRoomGames::Replay.new(state: state)
  assert(game.bot_move_delay(replay, "Alice", context: context) == 2.5, "#{phase}: deadline headroom changed")
  [99, 100, 101].each do |deadline|
    state[deadline_key] = deadline
    assert(game.bot_move_delay(replay, "Alice", context: context) == 0, "#{phase}: expired/near deadline still waits")
  end
  state[deadline_key] = 0
  assert(game.bot_move_delay(replay, "Alice", context: context) == 5, "#{phase}: unlimited turn lost delay")
  assert(game.bot_move_delay(replay, "Alice") == 1, "#{phase}: replay option fallback changed")
end

puts "Bot delay: #{games.length} real game replays, nil-state board turns, option fallback and deadline phases OK"
