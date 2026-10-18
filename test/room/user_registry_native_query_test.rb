require 'json'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/apps.rb')
require_relative '../../lib/game_room_user_registry'

module UserRegistryNativeQueryContract
  def self.assert(value, message)
    raise message unless value
    @checks = @checks.to_i + 1
  end

  class Client
    attr_reader :requests
    attr_accessor :cap, :failure_at

    def initialize(cap)
      @cap, @requests = cap, []
      @rows = (1..7).map do |id|
        {'__id' => id, 'username' => "Player#{id}", '__insertion_user' => "Player#{id}"}
      end
      @rows[3]['__insertion_user'] = 'Impersonator'
    end

    def api_data(method, path, params)
      raise 'Registry did not use the native projected query' unless method == 'POST' &&
        path == '/api/v1/apps/registry-fixture/tables/game_room_users/rows/query'
      query = JSON.parse(JSON.generate(params))
      @requests << query
      raise IOError, 'request rejected' if failure_at == @requests.length
      rows = @rows
      if query['where']
        bound = query.fetch('where').fetch('__id')
        raise 'Unexpected native cursor' unless bound.keys == ['gte']
        rows = rows.select { |row| row.fetch('__id') >= bound.fetch('gte') }
      end
      key, direction = query.fetch('order').fetch(0)
      raise 'Unstable native registry order' unless key == '__id'
      rows = rows.sort_by { |row| row.fetch('__id') }
      rows.reverse! if direction == 'desc'
      rows = rows.first([cap, query.fetch('limit')].min)
      {'rows' => rows.map { |row| row.slice(*query.fetch('columns')) }}
    end
  end

  [1, 3, 1000].each do |cap|
    client = Client.new(cap)
    table = EltenLink::Apps::AppTable.new(client, 'registry-fixture', 'game_room_users')
    registry = GameRoomUserRegistry.new(server_tables: {'game_room_users' => table})
    assert(registry.registered(%w[Player7 Player4 Player1]) == %w[Player7 Player1],
      "native cap=#{cap}: lost a candidate or trusted a different insertion author")
    assert(client.requests.first == {'columns' => ['__id'], 'order' => [['__id', 'desc']], 'limit' => 1},
      'Native query did not capture a stable initial boundary')
    pages = client.requests.drop(1)
    assert(pages.length == (7.0 / cap).ceil, 'Native short pages caused early EOF or extra empty reads')
    assert(pages.all? { |query| query['columns'] == %w[username __insertion_user __id] &&
      query['limit'] == 1000 && !query.key?('offset') }, 'Native projection/cursor changed')
    requests = client.requests.length
    assert(registry.registered(['Player7']) == ['Player7'] && client.requests.length == requests,
      'Native candidate cache was not reused')
  end

  client = Client.new(2)
  client.failure_at = 3
  table = EltenLink::Apps::AppTable.new(client, 'registry-fixture', 'game_room_users')
  registry = GameRoomUserRegistry.new(server_tables: {'game_room_users' => table})
  failed = begin; registry.registered(['Player7']); false; rescue IOError; true; end
  assert(failed, 'Native later-page failure became an empty or partial successful lookup')
  client.failure_at = nil
  assert(registry.registered(['Player7']) == ['Player7'], 'Native failure cached a partial result')
  puts "PASS native registry query boundary: #{@checks} assertions"
end
