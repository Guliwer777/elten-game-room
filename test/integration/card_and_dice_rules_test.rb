require_relative "../support/new_games_fixture"
module GameSurfaces
  module ActionEmitter; end
end
require_relative "../../lib/game_surfaces/card_sorting"
require_relative "../../lib/game_surfaces/packet_cards"

PLAYERS = %w[Alice Bob Carol].freeze
SEED = "0123456789abcdef0123456789abcdef"
REPO = NewGames116Repository.new(PLAYERS)
$results = []
def check(name)
  evidence = yield
  $results << { name: name, result: "PASS", evidence: evidence }
rescue StandardError => error
  $results << { name: name, result: "FAIL", evidence: error.message,
    location: error.backtrace.first }
end
def expect(value, message)
  raise message unless value
end
def initial(game, options = {}, players = PLAYERS)
  game.send(:initial_state, players, game.normalize_options(options))
end
def replay_of(state)
  GameRoomGames::Replay.new(players: state[:players], current_player: state[:current_player],
    winner: state[:winner], draw: state[:draw] || false, accepted_events: [], history: [], state: state)
end
def event(action, value = "", actor = "Alice", id = 1)
  { "id" => id, "actor" => actor, "action" => action, "value" => value }
end
def emitted_packet(displayed, selected, name)
  surface = GameSurfaces::PacketCardSurface.allocate
  cards = displayed.map { |card| GameSurfaces::Card.new(id: card, value: card) }
  surface.instance_variable_set(:@cards, cards)
  surface.instance_variable_set(:@selected_ids, selected)
  surface.instance_variable_set(:@spec, GameSurfaces::PacketCardSpec.new(id: "audit", action_name: name))
  surface.define_singleton_method(:emit_action) { |_kind, _name, payload, source:| @audit_payload = payload }
  surface.send(:submit_packet, displayed.index(selected.last), nil)
  JSON.parse(surface.instance_variable_get(:@audit_payload)["cards"])
end
def uno_state(game, options = {})
  initial(game, options).merge(phase: :playing, round: 1, current_player: "Alice",
    hands: { "Alice" => %w[R6a B1a G2a], "Bob" => %w[Y3a B4a], "Carol" => %w[G5a R7a] },
    discard: %w[R5a], colour: "R", draw_pile: %w[B8a G9a Y1a], seed: SEED)
end
def makao_state(game, options = {})
  initial(game, options).merge(phase: :playing, current_player: "Alice",
    hands: { "Alice" => %w[7H 7C AS], "Bob" => %w[9C 8D], "Carol" => %w[6C 5D] },
    discard: %w[9H], declared_suit: "H", draw_pile: %w[TC TD TS], seed: SEED)
end

uno = GameRoomGames::Uno.new
check("UNO: a classic coloured six is not a draw penalty") do
  state = uno_state(uno)
  expect(uno.send(:apply_play, state, event("play", "R6a||0"), "Alice", REPO, []), "Fixture play rejected")
  expect(state[:pending_draw] == 0, "Ordinary red six imposes #{state[:pending_draw]} cards; label=#{uno.send(:uno_label, 'R6a', state)}")
end
check("UNO: U announces UNO rather than catching oneself") do
  state = uno_state(uno)
  state[:hands]["Alice"] = %w[R6a]
  shortcut = uno.custom_game_shortcuts(replay_of(state), "Alice").find { |s| s.key == "u" }
  expect(shortcut.action_name == "uno", "U resolves to #{shortcut.action_name.inspect} with one's own last card")
end
check("UNO: declaration remains legal just after playing the penultimate card") do
  state = uno_state(uno)
  state[:hands]["Alice"] = %w[R4a B1a]
  expect(uno.send(:apply_play, state, event("play", "R4a||0"), "Alice", REPO, []), "Fixture play rejected")
  actions = uno.legal_actions(replay_of(state), "Alice")
  expect(actions.any? { |a| a["action"] == "uno" }, "After penultimate card: turn=#{state[:current_player]}, own actions=#{actions.inspect}")
end
check("UNO: roulette continues across deck recycling") do
  state = uno_state(uno, "deck" => "no_mercy")
  state.update(pending_type: "C", pending_colour: "R", draw_pile: %w[B8a], discard: %w[Y2a R3a NC0])
  expect(uno.send(:apply_draw, state, event("draw", "0"), "Alice", REPO, []), "Fixture draw rejected")
  expect(state[:hands]["Alice"].last.start_with?("R"), "Roulette ended on #{state[:hands]['Alice'].last}; pending=#{state[:pending_colour].inspect}, turn=#{state[:current_player]}")
end
check("UNO: No Mercy elimination gives the next player a fresh turn deadline") do
  state = uno_state(uno, "deck" => "no_mercy", "no_mercy_limit" => 10, "thinking_time" => 30)
  state[:hands]["Alice"] = %w[R1a R2a R3a R4a R5a R7a R8a R9a Y1a]
  state[:turn_deadline] = 100
  expect(uno.send(:apply_draw, state, event("draw", "130"), "Alice", REPO, []), "Fixture draw rejected")
  expect(state[:current_player] == "Bob", "Fixture did not eliminate Alice")
  expect(state[:turn_deadline] == 130 && state[:optional_draws] == 0,
    "Next player inherits deadline=#{state[:turn_deadline]} and drawn counter=#{state[:optional_draws]}")
end
check("UNO: canceling the final draw penalty settles the pending round winner") do
  state = uno_state(uno, "deck" => "no_mercy", "advanced_responses" => true)
  state[:hands]["Alice"] = %w[RDa]
  state[:hands]["Bob"] = %w[REa B3a]
  expect(uno.send(:apply_play, state, event("play", "RDa||0"), "Alice", REPO, []), "Fixture final penalty rejected")
  expect(uno.send(:apply_play, state, event("play", "REa||0", "Bob", 2), "Bob", REPO, []), "Fixture cancellation rejected")
  expect(state[:phase] != :playing, "Round still playing with #{state[:pending_finisher]} waiting to win, empty hand=#{state[:hands]['Alice'].inspect}, penalty=#{state[:pending_draw]}")
end

poker = GameRoomGames::Poker.new
check("Poker: ante does not become a negative call or stall passive betting") do
  state = initial(poker, "variant" => "draw")
  expect(poker.send(:apply_deal, state, event("deal", "1|0|#{SEED}|1800000000"), "Alice", REPO, []), "Fixture deal rejected")
  observations = []
  6.times do |i|
    break if state[:phase] == :exchange
    actor = state[:current_player]
    action = poker.legal_actions(replay_of(state), actor).find { |a| %w[call check].include?(a["action"]) }
    observations << action
    expect(poker.send(:apply_bet, state, event("bet", "#{action['action']}|#{action['amount']}", actor, i + 2), actor, REPO, []), "Fixture call rejected")
  end
  expect(state[:phase] == :exchange, "After two full call/check circuits phase=#{state[:phase]}; actions=#{observations.inspect}")
end
check("Poker: ace-low straight is recognized") do
  rank = poker.send(:five_card_rank, %w[AC 2D 3H 4S 5C])
  expect(rank.first == 4, "A2345 rank=#{rank.inspect}, expected straight category 4")
end
check("Poker: all-in cannot bypass a fixed betting limit and raise cap") do
  state = initial(poker, "betting" => "fixed", "raise_cap_enabled" => true, "raise_cap" => 3)
  state.update(phase: :betting, current_player: "Alice", current_bet: 20, raises: 3)
  actions = poker.legal_actions(replay_of(state), "Alice")
  expect(actions.none? { |a| a["action"] == "all_in" }, "No ordinary raise allowed, but actions=#{actions.inspect}")
end
check("Poker: exchanging a valid set works in displayed hand order") do
  state = initial(poker, "variant" => "draw")
  displayed = %w[AS 2C].sort_by { |card| poker.send(:playing_sort_key, card) }
  packet = emitted_packet(displayed, displayed.reverse, "exchange")
  state.update(phase: :exchange, current_player: "Alice", hands: { "Alice" => packet.reverse + %w[KH 3D QC], "Bob" => [], "Carol" => [] })
  status, = poker.action_for({ "kind" => "card_packet", "action" => "exchange", "cards" => JSON.generate(packet) }, replay_of(state), "Alice")
  expect(status == :ok, "Valid selection #{packet.inspect} rejected as #{status}")
end
check("Poker bot: a weak draw hand is not forced to keep every card") do
  state = initial(poker, "variant" => "draw")
  state.update(phase: :exchange, current_player: "Alice", hands: { "Alice" => %w[3C 4D 7H 9S KC], "Bob" => %w[2C 5C 6C 8C TC], "Carol" => %w[2D 3D 5D 6D 8D] })
  replay = replay_of(state)
  actions = poker.legal_actions(replay, "Alice")
  selected = poker.bot_strategy.choose(actions: actions, actor: "Alice", observation: {},
    random_source: NewGames116Random.new, game: poker, replay: replay)
  expect(JSON.parse(selected["cards"]).any?, "Bot uniquely prefers no exchange: #{selected.inspect}")
end
check("Poker: eight-player exchanges preserve five cards per player") do
  players = (1..8).map { |i| "Player#{i}" }
  repo = NewGames116Repository.new(players)
  state = initial(poker, { "variant" => "draw" }, players)
  expect(poker.send(:apply_deal, state, event("deal", "1|0|#{SEED}|1800000000", players.first), players.first, repo, []), "Fixture deal rejected")
  state.update(phase: :exchange, current_player: players[1])
  8.times do |i|
    actor = state[:current_player]
    cards = state[:hands][actor].take(3)
    expect(poker.send(:apply_exchange, state, event("exchange", cards.join(","), actor, i + 2), actor, repo, []), "Fixture exchange rejected")
  end
  sizes = state[:hands].transform_values(&:length)
  expect(sizes.values.all? { |n| n == 5 }, "Hand sizes after legal exchanges: #{sizes.inspect}")
end
check("Poker: an all-in player still receives a draw exchange") do
  state = initial(poker, "variant" => "draw")
  state.update(phase: :betting, current_player: "Carol", dealer_index: 0,
    current_bet: 10, street_bets: PLAYERS.to_h { |p| [p, 10] },
    acted: PLAYERS.to_h { |p| [p, true] }, all_in: { "Bob" => true },
    hands: PLAYERS.to_h { |p| [p, %w[2C 3D 4H 5S 6C]] })
  state[:stacks]["Bob"] = 0
  poker.send(:progress_after_action, state, "Carol", 1, [])
  expect(state[:current_player] == "Bob", "First exchange skips all-in Bob: #{state[:current_player]} in #{state[:phase]}")
end

makao = GameRoomGames::Makao.new
check("Makao: reject more dealt cards than fit in the deck") do
  players = (1..8).map { |i| "Player#{i}" }
  options = makao.normalize_options("hand_size" => 7)
  validation = makao.validation_error(options, player_count: 8)
  state = initial(makao, options, players)
  repo = NewGames116Repository.new(players)
  applied = makao.send(:apply_deal, state, event("deal", "0|#{SEED}", players.first), players.first, repo, [])
  nils = state[:hands].values.flatten.count(nil)
  expect(validation != nil || !applied, "Allowed 8x7 cards: nil cards=#{nils}, top=#{state[:discard].last.inspect}")
end
check("Makao: the agreed joker profile permits a universal ace") do
  state = makao_state(makao, "profile" => "joker")
  status = makao.send(:validate_packet, state, "Alice", %w[AS], "D")
  expect(status == :ok, "AS on 9H rejected: #{status}")
end
check("Makao: joker's declared value applies to the next player") do
  state = makao_state(makao, "profile" => "joker")
  state[:hands]["Alice"] = %w[X0 AS]
  expect(makao.send(:apply_play, state, event("play", "X0|9H"), "Alice", REPO, []), "Fixture joker rejected")
  status = makao.send(:validate_packet, state, "Bob", %w[9C], "")
  expect(status == :ok, "Joker declared 9H, next player's 9C rejected: #{status}")
end
check("Makao: selected packet preserves a legal opening card") do
  state = makao_state(makao)
  selected = %w[7H 7C]
  displayed = emitted_packet(selected.sort_by { |card| makao.send(:makao_sort_key, card) }, selected, "play")
  expect(makao.send(:validate_packet, state, "Alice", selected, "") == :ok, "Fixture intended packet illegal")
  status = makao.send(:validate_packet, state, "Alice", displayed, "")
  expect(status == :ok, "UI reorders #{selected.inspect} to #{displayed.inspect}, rejected: #{status}")
end
check("Makao: non-stacking fours still skip one turn") do
  state = makao_state(makao, "profile" => "custom", "stack_fours" => false)
  state[:hands]["Alice"] = %w[4H AS]
  expect(makao.send(:apply_play, state, event("play", "4H|"), "Alice", REPO, []), "Fixture four rejected")
  expect(state[:skip_penalty] > 0 || state[:current_player] == "Carol", "Four has no effect: pending=#{state[:skip_penalty]}, turn=#{state[:current_player]}")
end
check("Makao: one drawn playable card does not enable another optional draw") do
  state = makao_state(makao, "profile" => "joker")
  state[:hands]["Alice"] = %w[5D 6C]
  state[:draw_pile] = %w[7H 8H]
  expect(makao.send(:apply_draw, state, event("draw"), "Alice", REPO, []), "Fixture draw rejected")
  actions = makao.legal_actions(replay_of(state), "Alice")
  expect(actions.none? { |a| a["action"] == "draw" }, "After drawing a playable card, another draw remains legal")
end
check("Makao: declaration possible after penultimate card") do
  state = makao_state(makao)
  state[:hands]["Alice"] = %w[9C AS]
  expect(makao.send(:apply_play, state, event("play", "9C|"), "Alice", REPO, []), "Fixture play rejected")
  actions = makao.legal_actions(replay_of(state), "Alice")
  expect(actions.any? { |a| a["action"] == "makao" }, "After penultimate card turn=#{state[:current_player]}, declaration unavailable")
end

yahtzee = GameRoomGames::Yahtzee.new
check("Yahtzee: final score is not counted twice in announcements") do
  state = initial(yahtzee)
  keys = yahtzee.send(:categories, state)
  state[:sheets] = PLAYERS.to_h { |p| [p, keys.to_h { |key| [key, 0] }] }
  state[:sheets]["Alice"]["chance"] = 20
  state[:sheets]["Bob"]["chance"] = 10
  history = []
  yahtzee.send(:finish_or_advance, state, 1, history)
  text = yahtzee.send(:scores_text, state)
  expect(text.include?("Alice: 20"), "Announced #{text}; actual totals #{state[:totals].inspect}; history #{history.map(&:text).inspect}")
end
check("Yahtzee: participants show the current score, not just finished matches") do
  state = initial(yahtzee)
  state[:sheets]["Alice"]["chance"] = 20
  scores = yahtzee.participant_scores(replay_of(state))
  expect(scores["Alice"] == 20, "Recorded 20 points, participant scores=#{scores.inspect}")
end

monopoly = GameRoomGames::Monopoly.new
check("Monopoly: Atlantic City uses the reference Boardwalk rent schedule") do
  square = GameRoomContent::MonopolyBoards.build("atlantic_city")[:squares][39]
  expected = [50, 200, 600, 1400, 1700, 2000]
  expect(square[:rents] == expected, "Boardwalk rents=#{square[:rents].inspect}, reference=#{expected.inspect}")
end
check("Monopoly: a property sale can clear negative cash") do
  state = initial(monopoly)
  state[:cash]["Alice"] = -20
  state[:owners][1] = "Alice"
  offer = monopoly.send(:trade_actions, state, "Alice").find do |action|
    parsed = monopoly.send(:parse_trade_offer, state, action["offer"])
    parsed != nil && parsed[:target] == "Bob" && parsed[:give_properties] == [1] && parsed[:receive_cash] > 0
  end
  expect(offer != nil, "Fixture sale offer unavailable")
  expect(monopoly.send(:apply_trade, state, event("trade_offer", offer["offer"]), "Alice", REPO, []), "Fixture sale offer rejected")
  ok = monopoly.send(:apply_trade, state, event("trade_accept", "", "Bob", 2), "Bob", REPO, [])
  expect(ok, "Offered sale covering debt #{offer.inspect}, but buyer cannot accept; cash=#{state[:cash].inspect}")
end
check("Monopoly: bankrupted rent payer cannot create unearned money") do
  state = initial(monopoly)
  state[:cash]["Alice"] = 1
  state[:positions]["Alice"] = 1
  state[:owners][1] = "Bob"
  state[:houses][1] = 5
  state[:owners][3] = "Alice"
  before = state[:cash]["Bob"]
  monopoly.send(:resolve_square, state, "Alice", 1, [])
  expect(monopoly.send(:apply_bankruptcy, state, event("bankrupt"), "Alice", REPO, []), "Fixture bankruptcy rejected")
  expect(state[:cash]["Bob"] - before == 1, "Creditor must receive exactly the bankrupt payer's remaining 1 cash")
  expect(state[:owners][3] == "Bob", "Debtor property must pass to the creditor")
end
check("Monopoly: advance to Start counts a completed board lap") do
  state = initial(monopoly, "forbid_first_round_purchase" => true)
  state[:positions]["Alice"] = 7
  monopoly.send(:initialize_card_decks, state, "start")
  state[:card_decks][:community].delete(0)
  state[:card_decks][:community].unshift(0)
  monopoly.send(:draw_event_card, state, "Alice", :community, 1, [])
  state[:positions]["Alice"] = 1
  monopoly.send(:resolve_square, state, "Alice", 2, [])
  expect(state[:phase] == :property_decision, "After advance-to-Start: laps=#{state[:laps]['Alice']}, phase=#{state[:phase]} (buying still forbidden)")
end
check("Monopoly: doubles releasing a jailed player do not grant another roll") do
  state = initial(monopoly)
  state[:positions]["Alice"] = 10
  state[:jail]["Alice"] = 3
  state[:owners][14] = "Alice"
  expect(monopoly.send(:apply_roll, state, event("roll", "2,2,1"), "Alice", REPO, []), "Fixture release rejected")
  monopoly.send(:advance_completed_turn, state)
  expect(state[:current_player] != "Alice", "After leaving jail on doubles, same player gets another roll: #{state[:current_player]} / #{state[:phase]}")
end
check("Monopoly interface: ordinary square shows Roll, management stays in shortcuts") do
  state = initial(monopoly)
  state[:owners][1] = "Alice"
  items = monopoly.surface_spec(replay_of(state), "Alice").items
  actions = items.filter_map { |item| item.action&.name }
  expect(actions == ["roll"], "Main field contains: #{actions.inspect}")
end

puts JSON.pretty_generate($results)
puts "PROBES: #{$results.length}, FAILURES: #{$results.count { |r| r[:result] == 'FAIL' }}"


abort "Regression failures" if $results.any? { |result| result[:result] == "FAIL" }
