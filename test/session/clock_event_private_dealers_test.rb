require_relative '../support/clock_event_contract'
require_relative '../support/private_card_games'
require_relative '../../games/poker'
require_relative '../../games/ninety_nine'

def private_snapshot(h, user = h.users.first)
  h.repositories.fetch(user).snapshot_for(h.session)
end

def freeze_private_game(h, owner, value)
  h.as(owner) do
    h.transports.fetch(owner).freeze_game(private_snapshot(h, owner).session, frozen: value)
  end
end

def assert_private_deadline(h, deadline, logical_now, stage)
  PrivateCardGamesTest.assert_private(h)
  public_events = h.users.map { |user| private_snapshot(h, user).events }
  assert(public_events.uniq.length == 1, "#{h.game.id}: #{stage}: native event clocks diverged")
  h.users.each do |user|
    snapshot = private_snapshot(h, user)
    replay = h.game.replay(snapshot.session, snapshot.events, h.repositories.fetch(user))
    assert(replay.state[:turn_deadline] == deadline,
      "#{h.game.id}: #{stage}: #{user} deadline=#{replay.state[:turn_deadline]}, expected #{deadline}")
    assert(ClockEventContract.clock.now(snapshot.session) == logical_now, "#{h.game.id}: #{stage}: game clock moved")
    assert(replay.accepted_events.length == snapshot.events.length, "#{h.game.id}: #{stage}: a private dealer record was rejected")
  end
end

[[GameRoomGames::Poker.new, 'holdem'], [GameRoomGames::Poker.new, 'draw'],
  [GameRoomGames::NinetyNine.new, nil]].each do |game, variant|
  ClockEventContract.with_server_time do |time|
    options = {'thinking_time' => 30, 'starting_chips' => 1000}
    options['variant'] = variant if variant
    h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob Carol], options: options)
    begin
      runners.each_value { |runner| runner.instance_variable_set(:@clock, ClockEventContract.clock) }
      assert_private_deadline(h, 1030, 1000, 'initial private deal')
      original = private_snapshot(h).events
      hands = h.users.to_h { |user| [user, h.replay(user).state[:hands][user].dup] }
      time.call(1002)
      freeze_private_game(h, 'Alice', true)
      time.call(1050)
      assert_private_deadline(h, 1030, 1002, 'while frozen')
      time.call(1062)
      freeze_private_game(h, 'Alice', false)
      assert_private_deadline(h, 1030, 1002, 'first thaw')
      time.call(1063)
      freeze_private_game(h, 'Alice', true)
      h.as('Alice') { h.transports.fetch('Alice').transfer_room_owner(h.table, 'Carol') }
      h.as('Carol') { h.transports.fetch('Carol').room_snapshot(h.table) }
      time.call(1123)
      freeze_private_game(h, 'Carol', false)
      PrivateCardGamesTest.tick(h, runners)
      assert_private_deadline(h, 1030, 1003, 'successor thaw')
      assert(private_snapshot(h).events == original, "#{game.id}: pause/host transfer changed the initial private records")
      assert(h.users.all? { |user| h.replay(user).state[:hands][user] == hands[user] },
        "#{game.id}: pause/host transfer changed private hand ownership")

      # Use legal human actions and the real private-dealer runner. Poker must
      # reach a new board draw or exchange, and 99 a private replacement card.
      # In every case the final dealer action must start a fresh 30-second turn.
      reached = false
      12.times do |index|
        time.call(1124 + index)
        PrivateCardGamesTest.tick(h, runners)
        rep = h.replay('Alice')
        if [:betting, :exchange, :playing].include?(rep.state[:phase]) && !game.send(:private_waiting?, rep.state)
          user = rep.current_player
          choices = game.legal_actions(h.replay(user), user)
          choice = if game.is_a?(GameRoomGames::NinetyNine)
            choices.first
          elsif rep.state[:phase] == :exchange
            choices.find { |item| JSON.parse(item['cards']).length == 2 }
          else
            choices.find { |item| %w[check call].include?(item['action']) }
          end
          assert(choice, "#{game.id}/#{variant}: no legal fixture action in #{rep.state[:phase]}")
          PrivateCardGamesTest.submit(h, runners, user, choice)
        end
        4.times { PrivateCardGamesTest.tick(h, runners) }
        fresh = private_snapshot(h).events.drop(original.length)
        rep = h.replay('Alice')
        next unless fresh.any? { |event| event['action'] == 'private_draw' } &&
          !game.send(:private_waiting?, rep.state) && [:betting, :exchange, :playing].include?(rep.state[:phase])
        last = fresh.last
        logical = Time.now.to_i - 120
        assert(last['action'] == 'private_draw', "#{game.id}/#{variant}: final clock transition was not a private dealer draw")
        assert(last['__clock_offset'] == 120 && last['created_at'] == Time.now.to_i,
          "#{game.id}/#{variant}: post-thaw dealer event used an old offset")
        assert_private_deadline(h, logical + 30, logical, 'post-thaw private dealer draw')
        assert(rep.state[:turn_started] == logical, "#{game.id}: dealer started the next turn in wall time")
        if variant == 'holdem'
          assert(rep.state[:community].length == 3, 'Holdem fixture did not reach the flop')
        elsif variant == 'draw'
          assert(rep.state[:exchanged].values.any?, 'Draw poker fixture did not exchange cards')
        end
        reached = true
        break
      end
      assert(reached, "#{game.id}/#{variant}: did not exercise a post-pause private dealer transition")
    ensure
      runners.each_value(&:close)
    end
  end
end

puts 'PASS event clocks: private Holdem board draw, draw-poker exchange and 99 replacement, initial/dealer deadlines across two pauses and host handover, native accepted history and hand secrecy'
