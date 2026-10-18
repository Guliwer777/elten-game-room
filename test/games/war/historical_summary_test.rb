require_relative "../../support/elten_array_shuffle"
require_relative "../../support/native_room_harness"
require_relative "../../../games/war"
require_relative "../../../games/scientific_war"

module WarHistoricalSummaryTest
  module_function

  def summary(game, replay, viewer)
    game.game_shortcuts(replay, viewer).find { |shortcut| shortcut.key == 'v' && shortcut.modifiers.to_a.empty? }.message
  end

  def replace_twice(room)
    game = room.game
    before = room.replay('Alice')
    viewers = %w[Alice Bob Watcher]
    summaries = viewers.to_h { |viewer| [viewer, summary(game, before, viewer)] }
    history = before.history.map(&:to_h)
    events = room.events('Alice').map(&:dup)
    room.add_client('Watcher')
    assert(room.join('Watcher'), 'observer could not join')
    room.as('Alice') { room.transports['Alice'].set_observer(room.table, true, actor: 'Alice', subject: 'Watcher') }
    room.as('Alice') do
      room.transports['Alice'].replace_game_player(room.table, session_id: room.session['__id'], player: 'Alice')
    end
    after = room.replay('Alice')
    bot = after.players.first
    assert(GameRoomParticipants.bot?(bot), 'the first replacement did not create a real bot identity')
    assert(after.history.map(&:to_h) == history && room.events('Alice') == events, 'replacement rewrote historical data')
    viewers.each do |viewer|
      assert(summary(game, after, viewer) == summaries.fetch(viewer), "#{game.id}: human-to-bot replacement changed V for #{viewer}")
    end
    assert(summary(game, after, bot) == summaries.fetch('Watcher'), 'the new bot inherited the former winner narration')
    room.as('Alice') do
      room.transports['Alice'].replace_game_player(room.table, session_id: room.session['__id'], player: bot, replacement: 'Watcher')
    end
    after = room.replay('Alice')
    assert(after.players == %w[Watcher Bob], 'the observer did not physically replace the bot')
    viewers.each do |viewer|
      assert(summary(game, after, viewer) == summaries.fetch(viewer), "#{game.id}: bot-to-human replacement changed V for #{viewer}")
    end
    assert(after.history.map(&:to_h) == history && room.events('Alice') == events, 'the second replacement rewrote historical data')
    # The real screen receives the new session snapshot before the next write;
    # refresh the harness's original start-session handle in the same way.
    room.instance_variable_set(:@session, room.repositories.fetch('Alice').snapshot_for(room.session).session)
    summaries
  end

  def war
    game = GameRoomGames::War.new
    room = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
    room.start
    context = GameRoomGames::ActionContext.new(random_source: GameRoomRandom::SeededSource.new(7))
    room.view('Alice').next_random_values = GameRoomRandom::SeededSource.new(7).roll(count: 16, sides: 256).values
    assert(summary(game, room.replay('Alice'), 'Alice') == 'No battle has been decided yet.', 'initial War V is incorrect')
    room.submit('Alice', {'action' => 'deal'}, context: context)
    2.times do
      replay = room.replay('Alice')
      room.submit(replay.current_player, {'action' => 'play'})
    end
    assert(room.replay('Alice').state[:depth] == 1, 'the seeded battle did not start a war')
    assert(summary(game, room.replay('Alice'), 'Alice') == 'No battle has been decided yet.', 'an unfinished war exposed a summary')
    2.times do
      replay = room.replay('Alice')
      room.submit(replay.current_player, {'action' => 'play'})
    end
    replay = room.replay('Alice')
    assert(replay.state[:last_battle].actor == 'Alice', 'the seeded war was not won by Alice')
    original = summary(game, replay, 'Alice')
    assert(original.include?("Your opponent's hidden cards: queen of diamonds.") && original.include?('Your hidden cards: 9 of clubs.'),
      "the private-view winner narration was lost: #{original}")
    summaries = replace_twice(room)
    assert(summary(game, room.replay('Alice'), 'Alice') == original, 'the former winner lost the historical hidden-card details')
    2.times do
      current = room.replay('Alice')
      room.submit(current.current_player, {'action' => 'play'})
    end
    after = room.replay('Alice')
    assert(summary(game, after, 'Watcher') != summaries.fetch('Watcher'), 'V did not advance after the next battle')
    last = game.history_entries_for_display(after, 'Watcher').reverse.find { |entry| [:take, :carried].include?(entry.kind) }
    assert(summary(game, after, 'Watcher') == last.text, 'V does not match the latest historical display entry')
    room.assert_converged('War historical summary after replacements')
  end

  def scientific
    game = GameRoomGames::ScientificWar.new
    room = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
    room.start
    contexts = %w[Alice Bob Watcher].to_h do |user|
      [user, GameRoomGames::ActionContext.new(session_id: room.session['__id'],
        hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new))]
    end
    trick = lambda do |cards|
      cards.each { |user, card| room.submit(user, {'kind' => 'card', 'action' => 'select', 'card' => card}, context: contexts.fetch(user)) }
      cards.each_key { |user| room.submit(user, {'action' => 'reveal'}, context: contexts.fetch(user)) }
    end
    assert(summary(game, room.replay('Alice'), 'Alice') == 'No trick has been decided yet.', 'initial Scientific War V is incorrect')
    trick.call('Alice' => 'AH1', 'Bob' => 'KS1')
    replay = room.replay('Alice')
    assert(summary(game, replay, 'Alice') == replay.state[:last_trick], 'normal summary changed before any replacement')
    summaries = replace_twice(room)
    assert(summaries.fetch('Watcher').include?('Alice wins') && summaries.fetch('Watcher').include?('Alice: ace'), 'the initial historical identity was missing')
    trick.call('Watcher' => 'QH1', 'Bob' => '5S1')
    after = room.replay('Alice')
    text = summary(game, after, 'Watcher')
    assert(text.include?('Watcher wins') && text.include?('Watcher played a queen'), 'the next trick did not use its actual participants')
    assert(!text.include?('Alice'), 'the new trick retained the old occupant')
    assert(text == after.state[:last_trick], 'the latest summary lost card powers or other public details')
    last = after.history.reverse.find { |entry| entry.kind == :reveal }
    after.history << GameRoomGames::HistoryEntry.new(event_id: last.event_id, actor: 'Watcher', kind: :refill,
      field: 'private', text: 'Private refill must not become a public trick result.')
    assert(summary(game, after, 'Watcher') == text && summary(game, after, 'Alice') == text, 'V included a private same-event entry')
    room.assert_converged('Scientific War historical summary after replacements')
  end
end

$game_room_test_user = 'Alice'
WarHistoricalSummaryTest.war
WarHistoricalSummaryTest.scientific
puts 'PASS War and Scientific War historical V: physical human/bot/observer replacements, unchanged log, original identities, winner details and next result'
