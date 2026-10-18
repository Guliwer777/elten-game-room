require_relative 'saved_games_ui'

class SavedPreparationContractDriver < SaveAppDriver
  attr_accessor :activation_failure, :before_prepare, :notification_failure, :drop_confirmed_invitation_result
  attr_reader :activation_calls, :notification_attempts

  def initialize(broker)
    super
    @activation_calls, @notification_attempts = [], []
  end

  def run_network_task(title, **options, &block)
    if title == 'Preparing saved game' && @before_prepare
      callback, @before_prepare = @before_prepare, nil
      callback.call
    end
    result = super(title, **options, &block)
    if title == 'Sending invitation' && @drop_confirmed_invitation_result
      @drop_confirmed_invitation_result = false
      return nil
    end
    result
  end

  def activate_table_transport(row)
    @activation_calls << row['__id']
    failure, @activation_failure = @activation_failure, nil
    raise EltenAPI::LiveSessions::TimeoutError, 'Activation not confirmed' if failure == :before
    super
  end

  def send_notification(user, **options)
    @notification_attempts << user
    if @notification_failure == user
      @notification_failure = nil
      raise EltenAPI::LiveSessions::TimeoutError, 'Invitation not confirmed'
    end
    super
  end
end

module SavedPreparationContract
  module_function

  def fixture(observer_owner: true, private_table: false)
    $game_room_test_user = 'Alice'
    InvitationRepository::SENT_LOCK.synchronize { InvitationRepository::SENT.clear }
    broker = NativeLiveSessionsBroker.new
    app = SavedPreparationContractDriver.new(broker)
    game = GameRoomGames::TicTacToe.new
    table = app.lobby.create_table(name: 'Saved preparation retry', game: game.id, owner: 'Alice',
      private_table: private_table).table
    app.lobby.set_observer(table, 'Alice', true) if observer_owner
    guests = (observer_owner ? %w[Bob Carol] : %w[Bob]).map do |user|
      transport = GameRoomTransport.new(ProgramDouble.new(broker.endpoint(user)))
      app.transport.invite_user(table_id: table['__id'], user: user, metadata: {}) if private_table
      selected = transport.discover_rooms(include_private: true).find { |row| row['__id'] == table['__id'] }
      assert(transport.establish_membership(table_id: table['__id'], owner: 'Alice', capacity: 8,
        user: user, table: selected), 'Fixture guest did not join')
      transport
    end
    players = observer_owner ? %w[Bob Carol] : %w[Alice Bob]
    session = app.games.start_session(table: table, game: game.id, players: players,
      options: JSON.generate(game.default_options))
    saved = app.send(:saved_games).put(game: game, table: table,
      snapshot: app.games.snapshot_for(session), repository: app.games)
    app.lobby.close_table(table)
    [app, broker, saved, guests]
  end

  def role_failure(app, timing)
    original = app.lobby.method(:set_observer)
    writes = []
    first = true
    app.lobby.define_singleton_method(:set_observer) do |*arguments|
      writes << arguments
      inject, first = first, false
      raise EltenAPI::LiveSessions::TimeoutError, 'Role not confirmed before request' if inject && timing == :before
      value = original.call(*arguments)
      raise EltenAPI::LiveSessions::TimeoutError, 'Role not confirmed after request' if inject && timing == :after
      value
    end
    writes
  end

  def unchanged_archive(app, saved)
    stored = app.send(:saved_games).fetch(saved['id'])
    assert(stored == saved,
      'Preparing a continuation consumed or changed its archive')
  end

  def core_state(broker, row)
    core = broker.cores.fetch(row['__live_session_id'])
    Marshal.load(Marshal.dump([core.entries, core.metadata]))
  end
end
