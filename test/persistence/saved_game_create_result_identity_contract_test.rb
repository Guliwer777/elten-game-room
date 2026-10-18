require_relative '../support/saved_games_ui'

# Separate native-lobby scenario: a racing table can have exactly the same
# title/game/options as the requested archive. Only the save identity matters.
class SavedCreateIdentityDriver < SaveAppDriver
  attr_accessor :before_prepare
  attr_reader :activation_calls

  def initialize(broker)
    super
    @activation_calls = []
  end

  def run_network_task(title, **options, &block)
    if title == 'Preparing saved game' && @before_prepare
      callback, @before_prepare = @before_prepare, nil
      callback.call
    end
    super(title, **options, &block)
  end

  def activate_table_transport(row)
    @activation_calls << row['__id']
    super
  end
end

def create_identity_fixture
  $game_room_test_user = 'Alice'
  broker = NativeLiveSessionsBroker.new
  app = SavedCreateIdentityDriver.new(broker)
  game = GameRoomGames::TicTacToe.new
  table = app.lobby.create_table(name: 'Same visible table name', game: game.id, owner: 'Alice').table
  app.lobby.set_observer(table, 'Alice', true)
  %w[Bob Carol].each do |user|
    transport = GameRoomTransport.new(ProgramDouble.new(broker.endpoint(user)))
    row = transport.discover_rooms.find { |item| item['__id'] == table['__id'] }
    assert(transport.establish_membership(table_id: table['__id'], owner: 'Alice', capacity: 8,
      user: user, table: row), 'Original participant could not enter fixture')
  end
  session = app.games.start_session(table: table, game: game.id, players: %w[Bob Carol], options: '{}')
  saved = app.send(:saved_games).put(game: game, table: table,
    snapshot: app.games.snapshot_for(session), repository: app.games)
  app.lobby.close_table(table)
  [app, broker, saved]
end

[:same_save, :different_save].each do |kind|
  app, broker, saved = create_identity_fixture
  existing = nil
  baseline = nil
  app.before_prepare = lambda do
    id = kind == :same_save ? saved['id'] : SecureRandom.uuid
    existing = app.lobby.create_table(name: saved['table_name'], game: saved['game'], owner: 'Alice',
      game_options: saved['options'], private_table: saved['private'], resume_save_id: id).table
    # A matching continuation already completed its normal role setup.
    app.lobby.set_observer(existing, 'Alice', true) if kind == :same_save
    core = broker.cores.fetch(existing['__live_session_id'])
    baseline = Marshal.load(Marshal.dump([core.entries, core.metadata]))
  end
  result = app.send(:create_saved_game_table, saved)
  core = broker.cores.fetch(existing['__live_session_id'])
  assert([core.entries, core.metadata] == baseline, 'Retained table was written during create-result reconciliation')
  assert(app.activation_calls.empty?, 'Retained table was activated as if freshly created')
  assert(app.notices.none? { |notice| notice.is_a?(Array) }, 'Retained table resent archived-player invitations')
  assert(app.send(:saved_games).fetch(saved['id']) == saved, 'Reconciliation consumed the original archive')
  if kind == :same_save
    assert(result && result['__id'] == existing['__id'], 'Matching archive identity was not reused')
    assert(app.lobby.snapshot_for(existing).observer?('Alice'), 'Matching continuation lost its observer owner')
    # The fast precheck follows the same non-mutating contract on explicit retry.
    assert(app.send(:create_saved_game_table, saved)['__id'] == existing['__id'], 'Explicit retry did not reuse its table')
    assert([core.entries, core.metadata] == baseline && app.activation_calls.empty?, 'Explicit retry reran setup')
  else
    assert(result.nil?, 'Visible equality substituted another archive identity')
    assert(!app.lobby.snapshot_for(existing).observer?('Alice'), 'Refused archive changed the unrelated owner role')
    assert(app.notices.include?('You are already at another table.'), 'Conflict did not explain its refusal')
  end
  app.lobby.close_table(existing)
end

# The new-table branch must still activate, set the archive owner as observer,
# and invite each original human once. A subsequent retry does none of these.
app, broker, saved = create_identity_fixture
created = app.send(:create_saved_game_table, saved)
assert(created && app.activation_calls == [created['__id']], 'New continuation did not activate exactly once')
assert(app.lobby.snapshot_for(created).observer?('Alice'), 'New archive owner was inserted as a playing seat')
invited = app.notices.grep(Array).map(&:first)
assert(invited.sort == %w[Bob Carol], 'New continuation did not invite the two original seats exactly once')
assert(app.send(:create_saved_game_table, saved)['__id'] == created['__id'], 'New continuation was not reusable')
assert(app.activation_calls == [created['__id']] && app.notices.grep(Array).map(&:first) == invited,
  'A retry reactivated the new continuation or resent invitations')
assert(app.send(:saved_games).fetch(saved['id']) == saved, 'Waiting for players consumed the archive')
app.lobby.close_table(created)
puts 'PASS saved-game CreateResult identity: native immutable retained room, matching presentation, observer owner, fresh/retry branches'
