require_relative '../support/tournament_public_service'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/error.rb')
require EltenTestHost.file('src/eltenlink/apps.rb')
require_relative '../../lib/game_room_server_tables'
include TournamentPublicServiceSupport
include GameRoomTest::Assertions

# Real host AppTable and production provider; only HTTP is replaced here.
class TournamentReadClient
  attr_accessor :failure, :after_read
  attr_reader :calls
  def initialize(rows)
    @rows, @calls = rows, []
  end
  def api_data(method, path, params = {})
    raise 'Unexpected server write' unless method == 'GET'
    @calls << [method, path, params]
    raise @failure if @failure
    name = path.split('/').fetch(-2)
    rows = @rows.fetch(name, [])
    where = params['where'] && JSON.parse(params['where'])
    if where && where['__id'].is_a?(Hash)
      bound = where['__id']
      rows = rows.select { |row| row['__id'].between?(bound['gte'], bound['lte']) }
    end
    order = params['order'] && JSON.parse(params['order'])
    rows = rows.reverse if order == [['__id', 'desc']]
    result = {'rows' => rows.first(params.fetch('limit', 1000))}
    @after_read&.call(name)
    result
  end
end
program = Object.new
program.define_singleton_method(:server_app_uuid) { '468f59c5-c9d7-47cd-80f1-1a6fbfd1aa80' }
announcement = publication.merge('__id' => 1, '__insertion_user' => 'Author', '__insertion_time' => 100)
join = T::RegistrationProjection.join_values(tournament_id: 1, operation_key: 'native-read').merge(
  '__id' => 1, '__insertion_user' => 'Player', '__insertion_time' => 150)
client = TournamentReadClient.new(ANN => [announcement], REG => [join])
provider = GameRoomServerTables.new(program, client: client)
assert(provider.check_access(username: 'Player'))
actor = 'Player'
gateway = T::TablesGateway.new(server_tables: provider, user: -> { actor }, operation_error_classes: [EltenLink::Error])
assert_equal([announcement], gateway.read_rows(ANN))
assert_equal([join], gateway.read_rows(REG))
assert(client.calls.all? { |method, path, _| method == 'GET' && path.start_with?('/api/v1/apps/') })
client.failure = EltenLink::Error.new(code: 'apps.tables.stamp_required')
error = assert_raises(T::TablesGateway::Unavailable) { gateway.read_rows(ANN) }
assert_equal('apps.tables.stamp_required', error.cause.code)
assert_equal(:stamp_required, provider.access_state)
assert_raises(T::TablesGateway::Unavailable) { gateway.read_rows(REG) }
client.failure = nil
assert(provider.check_access(username: 'Player'))
client.after_read = ->(_) { actor = 'Other' }
assert_raises(T::TablesGateway::ContextChanged) { gateway.read_rows(ANN) }
puts 'PASS native SDK read integration: actual GET queries and metadata, protected-access error, no empty fallback or writes, account change guard'
