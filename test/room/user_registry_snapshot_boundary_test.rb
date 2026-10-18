require 'json'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/apps.rb')
require_relative '../../lib/game_room_user_registry'

module UserRegistrySnapshotBoundary
  def self.assert(value, message)
    raise message unless value
    @checks = @checks.to_i + 1
  end

  class Client
    attr_reader :requests, :rows
    attr_accessor :cap, :before_query, :after_query, :reply

    def initialize(rows, cap: 2)
      @rows, @cap, @requests = rows, cap, []
    end

    def api_data(method, path, parameters)
      raise 'Unexpected write/non-native query' unless method == 'POST' && path.end_with?('/rows/query')
      query = JSON.parse(JSON.generate(parameters))
      @requests << query
      @before_query&.call(query)
      selected = @rows.select do |row|
        query.fetch('where', {}).all? do |key, expected|
          expected.is_a?(Hash) ? expected.all? { |op, bound| op == 'gte' && row.fetch(key) >= bound } : row.fetch(key) == expected
        end
      end
      query.fetch('order').reverse_each do |key, direction|
        selected = selected.sort_by { |row| row.fetch(key) }
        selected.reverse! if direction == 'desc'
      end
      selected = selected.drop(query.fetch('offset', 0)).first([query.fetch('limit'), cap].min)
      selected = selected.map { |row| row.slice(*query.fetch('columns')) }
      @after_query&.call(query)
      selected = @reply.call(query, selected) if @reply
      {'rows' => selected}
    end
  end

  def self.row(id, name = "User#{id}", author = name)
    {'__id' => id, 'username' => name, '__insertion_user' => author, 'registered_at' => id}
  end

  def self.registry(client, clock)
    table = EltenLink::Apps::AppTable.new(client, 'registry-boundary', 'game_room_users')
    result = GameRoomUserRegistry.new(server_tables: {'game_room_users' => table})
    result.instance_variable_set(:@query_snapshot, GameRoomTableQuerySnapshot.new(clock: clock))
    result
  end

  now = 10.0
  client = Client.new([row(1), row(3), row(8, ' User8 ', 'USER8'), row(9, 'User9', 'Forged'), row(20)])
  directory = registry(client, -> { now })
  client.after_query = lambda do |query|
    next unless query['columns'] == %w[username __insertion_user __id] && query.dig('where', '__id', 'gte') == 1
    # A deleted earlier ID must not shift an offset, and later insertions must
    # not escape the original maximum even when returned on the final page.
    client.rows.delete_if { |entry| entry.fetch('__id') == 1 }
    client.rows << row(100) unless client.rows.any? { |entry| entry.fetch('__id') == 100 }
  end
  requested = ['user20', 'User9', ' user8 ', 'User3', 'User100', 'User20']
  assert(directory.registered(requested) == ['user20', ' user8 ', 'User3', 'User20'],
    'Shrinking native pages lost a valid later user, admitted spoofing, or escaped snapshot boundary')
  assert(client.requests.length == 4, 'Small gapped snapshot did not stop at captured maximum ID')
  before = client.requests.length
  now = 24.99
  assert(directory.registered(['User100', 'User20']) == ['User20'] && client.requests.length == before,
    'Unexpired snapshot performed reads or admitted a later registration')
  now = 25.0
  assert(directory.registered(['User100']) == ['User100'] && client.requests.length > before,
    'Snapshot expiry failed to read a later registration')

  client = Client.new([row(4), row(12), row(30)])
  directory = registry(client, -> { now })
  assert(directory.registered(['User30']) == ['User30'], 'Initial known directory is incomplete')
  now += 15
  broken = false
  client.reply = lambda do |query, rows|
    if query['columns'] != ['__id'] && !broken
      broken = true
      rows + [rows.last.dup] # Invalid duplicate IDs may not be cached as valid users.
    else
      rows
    end
  end
  rejected = begin; directory.registered(['User30']); false; rescue IOError; true; end
  assert(rejected, 'Malformed later refresh was accepted or replaced with stale success')
  client.reply = nil
  client.rows << row(50)
  assert(directory.registered(['User50']) == ['User50'], 'Failed refresh retained a stale or partial cache')

  client = Client.new((1..4097).map { |id| row(id) }, cap: 777)
  directory = registry(client, -> { now })
  assert(directory.registered(['User4097']) == ['User4097'], 'Uncacheable directory was truncated to cache bound')
  reads = client.requests.length
  assert(directory.registered(['User4097']) == ['User4097'] && client.requests.length == reads * 2,
    'Oversized directory was retained in the bounded cache')
  assert(client.requests.all? { |query| query['limit'] <= 1000 && !query.key?('offset') },
    'Independent native snapshot crossed per-request limits or reverted to offsets')
  reads = client.requests.length
  assert(directory.registered([]).empty? && client.requests.length == reads, 'Empty candidate list performed native reads')

  puts "PASS independent native registry snapshot boundaries: #{@checks} checks"
end
