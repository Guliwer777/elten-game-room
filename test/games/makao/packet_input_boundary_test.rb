require_relative '../../support/private_card_games'
require_relative '../../../games/makao'

failures = []
[false, true].each do |private_cards|
  game = GameRoomGames::Makao.new
  if private_cards
    h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob])
  else
    h = NativeRoomHarness.new(game: game, users: %w[Alice Bob],
      options: game.default_options.merge('bot_delay' => 0))
    h.start
    runners = h.users.to_h { |user| [user, runner_for(h, user)] }
    4.times { PrivateCardGamesTest.tick(h, runners) }
  end
  begin
    actor = h.replay('Alice').current_player
    replay = h.replay(actor)
    before = Marshal.dump(replay.state)
    %w[null true false 1 "AS" {} [] [null] [1] [["AS"]]].each do |text|
      selection = {'kind' => 'card_packet', 'action' => 'play', 'cards' => text}
      begin
        status, plan = game.action_for(selection, replay, actor)
        failures << "Unexpected packet result #{private_cards}/#{text}: #{status}" unless
          status == :invalid_packet && plan.nil?
      rescue StandardError => error
        failures << "Packet raised #{private_cards}/#{text}: #{error.class}"
      end
      assert(Marshal.dump(replay.state) == before, 'Malformed local input mutated the replay')
    end
    # A rejected local selection must not leave a pending writer or consume
    # any private proof. The next ordinary legal action still reaches replay.
    selection = game.legal_actions(replay, actor).first
    assert(selection, 'The fixture has no legal follow-up action')
    accepted = replay.accepted_events.size
    PrivateCardGamesTest.submit(h, runners, actor, selection)
    PrivateCardGamesTest.tick(h, runners)
    assert(h.replay(actor).accepted_events.size > accepted, 'Bad input blocked the next legal move')
    PrivateCardGamesTest.assert_private(h) if private_cards
  ensure
    runners.each_value(&:close)
  end
end
assert(failures.empty?, failures.join("\n"))
puts 'PASS Makao: malformed packet JSON returns a validation error; ordinary/private play continues'
