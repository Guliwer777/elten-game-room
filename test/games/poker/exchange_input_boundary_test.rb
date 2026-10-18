require_relative '../../support/clock_event_contract'
require_relative '../../support/private_card_games'
require_relative '../../../games/poker'

def poker_exchange_fixture(private_cards, draw_five)
  game = GameRoomGames::Poker.new
  options = {'variant' => 'draw', 'draw_five' => draw_five, 'bot_delay' => 0}
  if private_cards
    h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob], options: options)
  else
    h = NativeRoomHarness.new(game: game, users: %w[Alice Bob], options: game.default_options.merge(options))
    h.start
    runners = h.users.to_h { |user| [user, runner_for(h, user)] }
    4.times { PrivateCardGamesTest.tick(h, runners) }
  end
  8.times do
    replay = h.replay('Alice')
    break if replay.state[:phase] == :exchange
    actor = replay.current_player
    choice = game.legal_actions(h.replay(actor), actor).find { |item| %w[check call].include?(item['action']) }
    assert(choice, 'Cannot reach the ordinary five-card-draw exchange phase')
    PrivateCardGamesTest.submit(h, runners, actor, choice)
    PrivateCardGamesTest.tick(h, runners)
  end
  assert(h.replay('Alice').state[:phase] == :exchange, 'The native exchange fixture did not settle')
  [game, h, runners]
end

failures = []
ClockEventContract.with_server_time do
  [false, true].product([false, true]).each do |private_cards, draw_five|
    counts = draw_five ? [0, 1, 3, 5] : [0, 1, 3]
    counts.each do |count|
      game, h, runners = poker_exchange_fixture(private_cards, draw_five)
      label = "private=#{private_cards}/five=#{draw_five}/count=#{count}"
      begin
        actor = h.replay('Alice').current_player
        replay = h.replay(actor)
        own_cards = replay.state[:hands].fetch(actor).dup
        before = Marshal.dump(replay.state)
        before_events = h.events(actor).dup
        malformed = [nil, '', 'not-json', '[', 'null', 'true', 'false', '1', '1.5', '"AS"', '{}',
          '{"a":"AS"}', '[null]', '[1]', '[true]', '[["AS"]]', '[{}]', '["ZZ"]',
          JSON.generate([own_cards.first, own_cards.first]), JSON.generate(own_cards + ['ZZ'])]
        malformed << JSON.generate(own_cards) unless draw_five
        malformed.each do |text|
          selection = {'kind' => 'card_packet', 'action' => 'exchange', 'cards' => text}
          begin
            status, plan = game.action_for(selection, replay, actor)
            failures << "#{label}/#{text.inspect}: unexpected result #{status}" unless status == :invalid_exchange && plan.nil?
          rescue StandardError => error
            failures << "#{label}/#{text.inspect}: action raised #{error.class}"
          end
          begin
            message = game.move_error_for(:invalid_exchange, selection: selection, replay: replay, actor: actor)
            failures << "#{label}/#{text.inspect}: missing explanation" unless message.is_a?(String) && !message.empty?
          rescue StandardError => error
            failures << "#{label}/#{text.inspect}: explanation raised #{error.class}"
          end
          assert(Marshal.dump(replay.state) == before, 'Invalid exchange input mutated the model')
          assert(h.events(actor) == before_events, 'Invalid exchange input wrote a native event')
        end

        # Empty packets are the separate Keep all cards command; nonempty
        # packets come from the normal single-card or Shift+Enter selection.
        selection = {'kind' => count.zero? ? 'command' : 'card_packet', 'action' => 'exchange',
          'cards' => JSON.generate(own_cards.first(count))}
        PrivateCardGamesTest.submit(h, runners, actor, selection)
        12.times { PrivateCardGamesTest.tick(h, runners) }
        after = h.replay(actor)
        assert(after.state[:exchanged][actor], "#{label}: legitimate exchange was not accepted")
        assert(after.state[:hands][actor].length == 5, "#{label}: legitimate exchange changed the hand size")
        kept = own_cards.drop(count)
        assert((kept - after.state[:hands][actor]).empty?, "#{label}: exchange removed an unselected card")
        assert((own_cards.first(count) & after.state[:hands][actor]).empty?, "#{label}: exchange did not replace selected cards")
        PrivateCardGamesTest.assert_private(h) if private_cards
      ensure
        runners.each_value(&:close)
      end
    end
  end
end

assert(failures.empty?, failures.join("\n"))
puts 'PASS Poker exchange input: malformed JSON/types and explanatory messages; ordinary/private stand-pat and 1/3/5-card packets'
