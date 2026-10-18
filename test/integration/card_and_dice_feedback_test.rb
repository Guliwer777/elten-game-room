require_relative "../support/new_games_fixture"

PLAYERS = %w[Alice Bob Carol].freeze
REPO = NewGames116Repository.new(PLAYERS)
FAILURES = []
def check(name)
  yield
  puts "PASS #{name}"
rescue StandardError => error
  FAILURES << "#{name}: #{error.message}"
  puts "FAIL #{FAILURES.last}"
end
def initial(game, options = {})
  game.send(:initial_state, PLAYERS, game.normalize_options(options))
end
def view(state, history = [])
  GameRoomGames::Replay.new(players: PLAYERS, current_player: state[:current_player],
    winner: state[:winner], draw: false, state: state, history: history, accepted_events: [])
end
def event(action, value = "", actor = "Alice", id = 99)
  { "action" => action, "value" => value, "actor" => actor, "id" => id }
end

check("Yahtzee pairs count all five dice, including the unpaired die") do
  game = GameRoomGames::Yahtzee.new
  state = initial(game)
  [["pair", [2, 2, 3, 4, 6], 17], ["pair", [1, 2, 3, 4, 6], 0],
   ["two_pairs", [1, 3, 3, 5, 5], 17], ["two_pairs", [2, 2, 5, 5, 5], 19],
   ["two_pairs", [1, 4, 4, 4, 4], 0], ["misery", [1, 1, 1, 1, 1], 31],
   ["misery", [6, 6, 6, 6, 6], 6]].each do |category, dice, points|
    actual = game.send(:score_category, category, dice, state, "Alice")
    assert(actual == points, "#{category}: #{dice} scored #{actual}, expected #{points}")
  end
end

[2, 4].each do |penalty|
  [false, true].each do |playable|
    check("UNO penalty #{penalty}, legal card #{playable}") do
      game = GameRoomGames::Uno.new
      state = initial(game)
      state.update(phase: :playing, current_player: "Alice", round: 1, colour: "R",
        discard: [penalty == 2 ? "RDa" : "WF0"], pending_draw: penalty,
        hands: { "Alice" => playable ? ["R1a"] : ["B1a"], "Bob" => ["G2a"], "Carol" => ["Y3a"] },
        draw_pile: %w[B2a B3a G4a Y5a B6a])
      history = []
      assert(game.send(:apply_draw, state, event("draw", "123"), "Alice", REPO, history), "draw rejected")
      assert(state[:current_player] == (playable ? "Alice" : "Bob"), "wrong next player")
      assert(state[:hands]["Alice"].length == penalty + 1, "wrong penalty size")
      assert(game.legal_actions(view(state), "Alice").none? { |a| a["action"] == "draw" } || playable, "extra mandatory draw remains")
    end
  end
end
check("UNO round winner precedes individual points and match result") do
  game = GameRoomGames::Uno.new
  state = initial(game, "score_limit" => 20)
  state.update(phase: :playing, current_player: "Alice", round: 1,
    hands: { "Alice" => [], "Bob" => %w[R9a B9a], "Carol" => %w[G5a] },
    scores: { "Alice" => 0, "Bob" => 10, "Carol" => 19 })
  history = []
  game.send(:finish_round, state, "Alice", 99, history)
  assert(history.first.text == "Alice won the round.", "round result is not explicit")
  points = history.select { |entry| entry.kind == :score }.map(&:text)
  assert(points == ["Alice received 0 points.", "Bob received 18 points.", "Carol received 5 points."], points.inspect)
  assert(state[:scores] == { "Alice" => 0, "Bob" => 28, "Carol" => 24 }, "scoring changed")
  assert(state[:winner] == "Alice", "match did not finish")
end

check("Monopoly arrival and offer carry colour; purchase choices stay short") do
  game = GameRoomGames::Monopoly.new
  state = initial(game)
  history = []
  assert(game.send(:apply_roll, state, event("roll", "1,2,1"), "Alice", REPO, history), "roll rejected")
  assert(history.any? { |entry| entry.text.include?("pink group") && entry.text.include?("60") }, "missing spoken colour and price")
  labels = game.surface_spec(view(state), "Alice").items.map(&:label)
  assert(labels == ["Buy", "Do not buy"], labels.inspect)
  state[:owners][1] = "Alice"
  state[:owners][6] = "Bob"
  offer = game.send(:encode_trade_offer, target: 1, give_property: 1, receive_property: 6)
  text = game.send(:trade_label, state, offer)
  assert(text.include?("pink group") && text.include?("light blue group"), "trade omits colours")
  fields = game.send(:trade_form_fields, state, "Alice", "Bob")
  own_list = fields.find { |field| field.key == "give_properties" }
  assert(own_list.choices.any? { |choice| choice.label.include?("pink group") }, "trade property list omits colour")
end
check("Monopoly full group is announced once on purchase, not on later events") do
  game = GameRoomGames::Monopoly.new
  state = initial(game)
  state[:positions]["Alice"] = 3
  state[:phase] = :property_decision
  state[:owners][1] = "Alice"
  history = []
  before = game.send(:completed_colour_groups, state)
  assert(game.send(:apply_buy, state, event("buy"), "Alice", REPO, history), "purchase rejected")
  game.send(:announce_completed_groups, state, before, 99, history)
  assert(history.last.text == "Alice completed the pink group.", history.map(&:text).inspect)
  game.send(:announce_completed_groups, state, game.send(:completed_colour_groups, state), 100, history)
  assert(history.count { |entry| entry.text.include?("completed") } == 1, "duplicate completion")
end

%w[buy auction_pass trade_accept bankrupt].each do |action|
  check("Monopoly #{action}: replay announces acquired groups without repeating on next roll") do
    game = GameRoomGames::Monopoly.new
    base_initial = game.method(:initial_state)
    game.define_singleton_method(:initial_state) do |players, options|
      state = base_initial.call(players, options)
      state[:owners][1] = "Alice"
      case action
      when "buy"
        state[:phase] = :property_decision
        state[:positions]["Alice"] = 3
      when "auction_pass"
        state.update(phase: :auction, current_player: "Bob", auction_square: 3,
          auction_leader: "Alice", auction_bid: 10, auction_origin: "Bob", auction_passed: { "Carol" => true })
      when "trade_accept"
        state[:owners][3] = "Bob"
        offer = parse_trade_offer(state, encode_trade_offer(target: 1, receive_property: 3, give_cash: 100))
        offer[:from] = "Alice"
        state.update(phase: :trade_response, current_player: "Bob", trade_offer: offer, trade_phase: :awaiting_roll)
      when "bankrupt"
        state[:owners][3] = "Bob"
        state[:cash]["Bob"] = -10
        state[:debts]["Bob"] = [{ to: "Alice", amount: 10 }]
        state.update(phase: :turn_complete, current_player: "Bob")
      end
      state
    end
    actor = action == "buy" ? "Alice" : "Bob"
    events = [event(action, "", actor, 1)]
    replay = game.replay({}, events, REPO)
    assert(replay.accepted_events.length == 1, "ownership action rejected")
    entries = replay.history.select { |entry| entry.key.start_with?("group_complete:") }
    assert(entries.map(&:text) == ["Alice completed the pink group."], entries.map(&:text).inspect)
    assert(game.describe_event(events.first, REPO, replay, "Carol").include?(entries.first.text), "group not spoken to others")
    events << event("roll", "1,2,1", replay.current_player, 2)
    replay = game.replay({}, events, REPO)
    assert(replay.accepted_events.length == 2, "following roll rejected")
    assert(replay.history.count { |entry| entry.key.start_with?("group_complete:") } == 1, "repeat on unrelated action")
  end
end

%w[holdem draw].each do |variant|
  [false, true].each do |all_in|
    check("Poker #{variant} phases, all-in #{all_in}") do
      game = GameRoomGames::Poker.new
      session = { "options" => JSON.generate(game.normalize_options("variant" => variant, "jacks_or_better" => false)) }
      events = []
      replay = game.replay(session, [], REPO)
      replay = append_action(game, session, REPO, events, replay, "Alice", { "kind" => "command", "action" => "deal" }, context_for)
      40.times do
        break if replay.finished? || replay.state[:phase] == :hand_complete
        actor = replay.current_player
        actions = game.legal_actions(replay, actor)
        selection = (all_in && actions.find { |a| a["action"] == "all_in" }) || actions.find { |a| %w[call check exchange].include?(a["action"]) }
        assert(selection, "no progress action")
        replay = append_action(game, session, REPO, events, replay, actor, selection, context_for)
      end
      history = replay.history
      stages = history.select { |entry| entry.key.start_with?("stage:") }
      if variant == "holdem"
        assert(stages.length == 4, "expected preflop/flop/turn/river: #{stages.map(&:text)}")
        assert(stages.map(&:text).zip(%w[Preflop Flop Turn River]).all? { |text, name| text.start_with?(name) }, "phase order")
        [3, 1, 1].each_with_index do |count, index|
          offset = [0, 3, 4][index]
          cards = replay.state[:community].slice(offset, count).map { |card| game.send(:poker_card_label, card) }
          assert(cards.all? { |label| stages[index + 1].text.include?(label) }, "missing community cards")
        end
      else
        assert(stages.map(&:text) == ["First betting round.", "Card exchange.", "Second betting round."], stages.map(&:text).inspect)
        assert(replay.state[:community].empty?, "draw unexpectedly exposes community cards")
      end
      assert(history.any? { |entry| entry.key.start_with?("showdown:") && entry.kind == :round_result }, "missing showdown")
      assert(history.count { |entry| entry.key.start_with?("showdown_hand:") } == PLAYERS.length, "missing separately shown hands")
      assert(game.replay(session, events, REPO).history.map(&:text) == history.map(&:text), "replay differs")
      stages.each do |stage|
        source = events.find { |item| item["id"] == stage.event_id }
        spoken = game.describe_event(source, REPO, replay, "Carol")
        if source['action'] == 'deal'
          assert(!spoken.include?(stage.text), 'Deal repeated its initial betting-stage announcement')
        else
          assert(spoken.include?(stage.text), "phase not spoken")
        end
      end
    end
  end
end
check("Polish regional board labels go through the runtime catalogue") do
  data = File.binread(File.expand_path("../../locale/PL.mo", __dir__))
  count, originals, translations = data.byteslice(8, 12).unpack("V3")
  catalog = {}
  count.times do |index|
    read = lambda do |table|
      size, offset = data.byteslice(table + index * 8, 8).unpack("V2")
      data.byteslice(offset, size).force_encoding("UTF-8")
    end
    catalog[read.call(originals)] = read.call(translations)
  end
  require_relative "../support/localization"
  previous_language = GameRoomTestLocalization.language
  GameRoomTestLocalization.use_language(:pl)
  begin
    boards = GameRoomContent::MonopolyBoards
    %w[atlantic_city roma indonesia india].each do |id|
      board = boards.build(id)[:squares]
      assert(board.find { |square| square[:type] == :chance }[:name] == "Szansa", "#{id}: chance is untranslated")
      assert(board.find { |square| square[:type] == :go_to_jail }[:name] == catalog.fetch("Go to jail"), "#{id}: jail is untranslated")
    end
    assert(boards.build("atlantic_city")[:squares][5][:name] == "Kolej Reading", "railroad bypasses translation")
    assert(boards.build("roma")[:squares][12][:name] == "Elektrownia", "utility bypasses translation")
    assert(boards.build("atlantic_city")[:squares][1][:name] == "Mediterranean avenue", "proper street name unexpectedly replaced")
    game = GameRoomGames::Monopoly.new
    state = initial(game)
    history = []
    game.send(:apply_roll, state, event("roll", "1,2,1"), "Alice", REPO, history)
    assert(history.any? { |entry| entry.text.include?("Alice może kupić") && entry.text.include?("za 60") && entry.text.include?(catalog.fetch("pink group")) }, "offer is untranslated")
  ensure
    GameRoomTestLocalization.use_language(previous_language)
  end
end
abort FAILURES.join("\n") unless FAILURES.empty?
puts "Build 207 feedback regressions passed."
