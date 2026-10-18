require_relative '../support/private_card_games'
require_relative '../../games/scrabble'

def scrabble_shape_room(private_cards)
  game = GameRoomGames::Scrabble.new
  options = game.normalize_options('content_language_id' => 'en')
  if private_cards
    h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob],
      options: options, random_values: Array.new(16, 8))
  else
    h = NativeRoomHarness.new(game: game, users: %w[Alice Bob], options: options)
    h.start
    h.view('Alice').next_random_values = Array.new(16, 8)
    runners = h.users.to_h { |user| [user, runner_for(h, user)] }
    16.times { PrivateCardGamesTest.tick(h, runners) }
  end
  assert(h.replay('Alice').state[:phase] == :playing, 'normal native deal did not complete')
  [game, h, runners]
end

def scrabble_shape_move(h, runners)
  actor = h.replay('Alice').current_player
  before = h.replay(actor)
  PrivateCardGamesTest.submit(h, runners, actor, {'action' => 'pass'})
  assert(h.replay(actor).state[:revision] == before.state[:revision] + 1,
    'ordinary pass did not advance once')
end

[true, false].each do |private_cards|
  game, h, runners = scrabble_shape_room(private_cards)
  begin
    scrabble_shape_move(h, runners)
    before = h.replay('Alice')
    actor = before.current_player
    tile = h.replay(actor).state[:racks][actor].first
    malformed = [nil, false, 1, 'x', {}, [], [nil], [false], [1], ['x'], [{}], [[]],
      [[tile, 112, game.tiles(before.state)[tile][:letter]], nil]]
    malformed.each do |placements|
      states = h.users.to_h { |user| [user, GameRoomTest::ReplaySnapshot.capture(h.replay(user))] }
      data = {'action' => 'place', 'placements' => placements,
        'revision' => before.state[:revision], 'time' => before.state[:turn_started]}
      commands = GameRoomActionPayload.commands(game.id, data)
      if private_cards
        commands = commands.map do |command|
          GameRoomPrivateCards.command(command.action, command.value, operation: 'claim')
        end
      end
      count = h.events(actor).size
      h.write(actor, commands)
      snapshot = h.repositories['Alice'].snapshot_for(h.session)
      assert(snapshot.events.size == count + commands.size, 'native payload never reached replay')
      assert(h.repositories['Alice'].actor_of(snapshot.events.last, snapshot.session) == actor,
        'native payload lost its authenticated author')
      h.users.each do |user|
        assert(GameRoomTest::ReplaySnapshot.capture(h.replay(user)) == states.fetch(user),
          "malformed placement changed #{user}'s replay: #{placements.inspect}, private=#{private_cards}")
      end
      PrivateCardGamesTest.tick(h, runners)
    end
    # An invalid claim must not consume the turn, reveal a rack or prevent the
    # next normal action. Reconstructing from the same immutable native log is
    # checked independently of each repository's warmed projection above.
    snapshot = h.repositories[actor].snapshot_for(h.session)
    rebuilt = GameRoomGames::Scrabble.new.replay(snapshot.session, snapshot.events, h.repositories[actor])
    assert(GameRoomTest::ReplaySnapshot.capture(rebuilt) == GameRoomTest::ReplaySnapshot.capture(h.replay(actor)),
      'cold reconstruction differs after rejected placements')
    scrabble_shape_move(h, runners)
    PrivateCardGamesTest.assert_private(h) if private_cards
  ensure
    runners.each_value(&:close)
  end
end

puts 'PASS native private/ordinary Scrabble malformed placement payloads, unchanged peer state and continued legal moves'
