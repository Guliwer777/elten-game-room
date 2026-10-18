require_relative '../support/clock_event_contract'
require_relative '../../lib/saved_games'
require_relative '../../lib/game_bots'
require_relative '../../games/domino'
require_relative '../../games/mexican_train'
require_relative '../../games/scrabble'
require_relative '../../games/taboo'

class TileWordArchiveMemory
  def initialize; @root = {}; end
  def read_json(_path, default:); JSON.parse(JSON.generate(@root)); end
  def update_json(_path, default:)
    value = read_json(nil, default: default)
    yield value
    @root = JSON.parse(JSON.generate(value))
  end
end

class TileWordNoClientEntropy
  def roll(**); raise 'Native ordinary deal/exchange used client entropy'; end
end

def tile_word_action(h, writer, selection, actor: writer, controller: false)
  h.as(writer) do
    h.transports.fetch(writer).room_snapshot(h.table)
    repository = h.repositories.fetch(writer)
    snapshot = repository.snapshot_for(h.session)
    replay = h.game.replay(snapshot.session, snapshot.events, repository)
    context = GameRoomGames::ActionContext.new(now: ClockEventContract.clock.now(snapshot.session),
      table_owner: snapshot.session['__table_owner'], random_source: TileWordNoClientEntropy.new,
      server_random: snapshot.session['__server_random'] == GameRoomServerRandom::VERSION)
    status, plan = h.game.action_for(selection, replay, actor, context: context)
    assert(status == :ok, "#{h.game.id}: #{writer}/#{actor} cannot perform #{selection.inspect}: #{status}")
    repository.append_events(session: snapshot.session, sequence: repository.next_sequence(snapshot.session, snapshot.events),
      events: plan.events, actor: actor, controller: controller)
  end
end

def tile_word_state(replay)
  # Archive restoration changes the epoch representation, not the position.
  replay.state.reject { |key, _| %i[clock_epoch_offset clock_offset frozen_at].include?(key) }
end

def tile_word_taboo_turn(h, time, moderator)
  game = h.game
  giver = h.replay(moderator).current_player
  tile_word_action(h, giver, {'action'=>'start', 'token'=>game.token(h.replay(giver).state)})
  time.call(h.replay(moderator).state[:deadline])
  tile_word_action(h, moderator, {'action'=>'begin', 'token'=>game.token(h.replay(moderator).state)},
    actor: h.users.first, controller: moderator != h.users.first)
  tile_word_action(h, giver, {'action'=>'correct', 'token'=>game.token(h.replay(giver).state)})
  time.call(h.replay(moderator).state[:deadline])
  tile_word_action(h, moderator, {'action'=>'timeout', 'token'=>game.token(h.replay(moderator).state)},
    actor: h.users.first, controller: moderator != h.users.first)
  tile_word_action(h, moderator, {'action'=>'approve', 'token'=>game.token(h.replay(moderator).state)},
    actor: h.users.first, controller: moderator != h.users.first)
end

[GameRoomGames::Domino, GameRoomGames::MexicanTrain, GameRoomGames::Scrabble, GameRoomGames::Taboo].each do |klass|
  ClockEventContract.with_server_time do |time|
    game = klass.new
    users = %w[Alice Bob Carol Dave].first(game.id == 'taboo' ? 4 : 3)
    options = game.default_options.merge('bot_delay'=>0)
    h = NativeRoomHarness.new(game: game, users: users, options: options)
    h.start
    h.view('Alice').next_random_values = Array.new(16, 8)
    tile_word_action(h, 'Alice', {'action'=>'deal'})
    assert(!GameRoomPrivateCards.enabled?(h.session), "#{game.id}: ordinary game unexpectedly needs private pools")
    assert(h.events('Alice').any? { |event| event['__server_random'] }, "#{game.id}: ordinary deal lacks native random proof")
    if game.id == 'taboo'
      tile_word_taboo_turn(h, time, 'Alice')
    else
      actor = h.replay('Alice').current_player
      choice = if game.id == 'scrabble'
        {'action'=>'exchange', 'tiles'=>h.replay(actor).state[:racks][actor].first(2)}
      else
        game.legal_actions(h.replay(actor), actor).first
      end
      assert(choice, "#{game.id}: fixture has no ordinary action")
      tile_word_action(h, actor, choice)
    end
    before = h.replay('Alice')
    assert(before.accepted_events.size == h.events('Alice').size, "#{game.id}: ordinary move was rejected")
    h.as('Alice') { h.transports['Alice'].freeze_game(h.repositories['Alice'].snapshot_for(h.session).session) }
    source = h.repositories['Alice'].snapshot_for(h.session)
    saved_at = Time.now.to_i
    saves = SavedGames.new(TileWordArchiveMemory.new, owner:'Alice')
    row = saves.put(game:game, table:h.table, snapshot:source, repository:h.repositories['Alice'], now:saved_at)
    time.call(saved_at + 100)
    restored = NativeRoomHarness.new(game:game, users:users, options:options)
    data = saves.restored_data(row, game:game, table_id:restored.table['__id'], now:Time.now.to_i)
    session = restored.as('Alice') do
      restored.repositories['Alice'].restore_session(table:restored.table, game:game.id,
        players:data[:players], options:row['options'], restore:data)
    end
    restored.instance_variable_set(:@session, session)
    users.each do |user|
      replay = restored.replay(user)
      assert(tile_word_state(replay) == tile_word_state(before), "#{game.id}: archive changed hands, stock, scores or position")
      assert(replay.history.map(&:to_h) == before.history.map(&:to_h), "#{game.id}: archive changed history")
      assert(replay.accepted_events.size == before.accepted_events.size, "#{game.id}: archive lost a native random event")
    end
    assert(ClockEventContract.clock.now(restored.repositories['Alice'].snapshot_for(session).session) == saved_at,
      "#{game.id}: archive did not preserve logical time")

    # A cold native reconnect has no old local transport or repository cache.
    restored.view('Bob').leave
    restored.add_client('Bob')
    assert(restored.join('Bob'), "#{game.id}: ordinary return failed")
    assert(tile_word_state(restored.replay('Bob')) == tile_word_state(before), "#{game.id}: cold return changed the restored position")

    if game.supports_bots?
      actor = restored.replay('Alice').current_player
      repository = restored.repositories['Alice']
      snapshot = repository.snapshot_for(session)
      guard = repository.control_change_guard(table:restored.table, game:game, session:snapshot.session, player:actor)
      restored.as('Alice') do
        restored.transports['Alice'].replace_game_player(restored.table, session_id:repository.session_id(snapshot.session),
          player:actor, control_guard:guard)
      end
      changed = restored.replay('Alice')
      bot = changed.current_player
      assert(GameRoomParticipants.bot?(bot) && changed.state[:hands][bot] == before.state[:hands][actor],
        "#{game.id}: ordinary replacement lost the active hand")
    else
      assert(game.controller_change_error(restored.replay('Alice'), replacement:true), "#{game.id}: unsupported bot was allowed")
    end

    restored.add_client('Watcher')
    assert(restored.join('Watcher'), "#{game.id}: observer join failed")
    restored.as('Watcher') { restored.transports['Watcher'].set_observer(restored.table, true, actor:'Watcher') }
    restored.view('Alice').transfer_ownership(restored.view('Alice').participants.find { |entry| entry.user == 'Watcher' })
    restored.as('Watcher') { restored.transports['Watcher'].room_snapshot(restored.table) }
    previous = restored.replay('Watcher')
    if game.supports_bots?
      context = GameRoomGames::ActionContext.new(now:saved_at, random_source:GameRoomRandom::SeededSource.new(3))
      decision = GameRoomBots::Coordinator.new.decide_next(game:game, replay:previous, context:context)
      assert(decision, "#{game.id}: named bot has no legal action after restore/host transfer")
      # Hidden opponent identities/stock order are not inputs to its heuristic.
      altered = previous.dup
      altered.state = Marshal.load(Marshal.dump(previous.state))
      others = altered.state[:hands].keys.reject { |user| user == decision.actor }
      hidden = (others.flat_map { |user| altered.state[:hands][user] } + altered.state[:stock]).reverse
      others.each { |user| altered.state[:hands][user] = hidden.shift(altered.state[:hands][user].size) }
      altered.state[:stock] = hidden
      assert(others.any? { |user| altered.state[:hands][user].sort != previous.state[:hands][user].sort },
        "#{game.id}: hidden-information fixture only changed order, not identities")
      scores = ->(replay) { game.legal_actions(replay, decision.actor).map { |action| [action, game.bot_action_score(replay, decision.actor, action)] } }
      assert(scores.call(previous) == scores.call(altered), "#{game.id}: bot scores depend on foreign hand/stock order")
      tile_word_action(restored, 'Watcher', decision.action, actor:decision.actor, controller:true)
    elsif game.id == 'scrabble'
      actor = previous.current_player
      tile_word_action(restored, actor, {'action'=>'pass'})
    else
      # Advance wall time by the stored epoch shift to hit each logical deadline.
      logical_time = ->(value) { time.call(value + 100) }
      tile_word_taboo_turn(restored, logical_time, 'Watcher')
      assert(restored.replay('Watcher').state[:completed] == before.state[:completed] + 1, 'Taboo observer master could not complete a restored turn')
    end
    after = restored.replay('Watcher')
    assert(after.accepted_events.size > previous.accepted_events.size, "#{game.id}: restored game did not continue")
    assert(after.accepted_events.size == restored.events('Watcher').size, "#{game.id}: continuation rejected an accepted receipt")
    assert(after.history.first(before.history.size).map(&:to_h) == before.history.map(&:to_h), "#{game.id}: continuation rewrote old history")
    puts "PASS #{game.id}: ordinary native random, archive, cold return, observer host and continued #{game.supports_bots? ? 'named bot' : 'human'} play"
  end
end
