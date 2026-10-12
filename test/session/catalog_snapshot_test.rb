require_relative '../support/session_runner'
require_relative '../support/model_contract'
require_relative '../../games/catalog'

include GameRoomTest::Assertions

games = 0
public_actions = 0
GameRoomGames::CATALOG.ids.each do |id|
  game = GameRoomGames::CATALOG.build(id)
  options = game.default_options
  # Daily Krowa requires its separate server assignment/start guard. Use a
  # normal random word here; this test must not invent a daily assignment.
  options = options.merge('variant' => 'random') if id == 'krowa'
  players = GameRoomTest::ModelContract.players_for(game, options)
  native = NativeRoomHarness.new(game: game, users: players, options: options)
  native.start
  runner = runner_for(native, players.first, covered: -> { false })
  # The local broker does not synchronize ELTEN's global server clock.
  # Supply one confirmed fixture sample; production time guards stay intact.
  server_time = Time.now.to_i
  clock = GameRoomSessionClock.new(sample: -> { server_time }, elapsed: -> { 0.0 }, wall: -> { server_time })
  runner.instance_variable_set(:@clock, clock)
  steps = 0
  begin
    5.times do |index|
      step(native, runner)
      packet = runner.ready_presentation_snapshot
      assert(packet, "#{id}: no complete worker snapshot")
      expected = native.repositories.fetch(players.first).snapshot_for(native.session)
      assert_equal(expected.session, packet.session, "#{id}: worker changed session metadata")
      assert_equal(expected.events, packet.snapshot.events, "#{id}: worker lost the complete event log")
      assert_equal(packet.session, packet.snapshot.session, "#{id}: mixed snapshot generations")
      replay_value = GameRoomTest::ContractValues.canonical(packet.replay)
      assert_equal(expected.events, packet.replay.accepted_events, "#{id}: fixture action was rejected")
      players.each do |player|
        assert_equal(expected.events, native.events(player), "#{id}: clients disagree about the event log")
        assert_equal(replay_value, GameRoomTest::ContractValues.canonical(native.replay(player)),
          "#{id}: worker/UI replay differs for #{player}")
      end
      event_ids = expected.events.map { |event| event.fetch('__id') }
      assert_equal(event_ids.sort.uniq, event_ids, "#{id}: duplicated or unordered records")
      assert_equal(players, packet.room.game_participants, "#{id}: copied room lost its participants")
      copy = GameRoomSnapshot.copy(packet)
      copy.snapshot.events.clear
      copy.room.members.clear
      assert_equal(expected.events, packet.snapshot.events, "#{id}: consumer owns the worker's log")
      assert_equal(players, packet.room.members, "#{id}: consumer owns the worker's membership")
      break if index == 4 || packet.replay.finished?

      # Let real game rules create the action. Private games with no public
      # action available are covered at their waiting boundary; do not invent
      # a hidden answer or bypass their own client protocol to inflate coverage.
      context = runner.send(:context)
      actor = game.automatic_actor(packet.replay, players.first, table_owner: players.first)
      selection = actor && game.automatic_action(packet.replay, actor, context: context)
      unless selection
        actor = game.active_actors(packet.replay).first
        selection = actor && game.legal_actions(packet.replay, actor, context: context).first
      end
      break unless selection

      native.submit(actor, selection, context: context)
      public_actions += 1
      steps += 1
    end
    games += 1
    puts "#{id}: complete worker snapshot, #{steps} public actions"
  ensure
    runner.close
    native.users.each { |user| native.as(user) { native.view(user)&.close } }
  end
end
puts "PASS catalog worker snapshot: #{games} games, #{public_actions} actions, native session fixtures (no live network)"
