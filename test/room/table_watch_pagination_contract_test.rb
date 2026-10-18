require 'json'
require_relative '../support/host_source'
require EltenTestHost.file('src/eltenlink/apps.rb')
require_relative '../../lib/table_watch'

module TableWatchPaginationContract
  COLUMNS = GameRoomTableWatch::Preferences::COLUMNS
  PATH = '/api/v1/apps/watch-pagination/tables/table_watch_preferences/rows'.freeze

  class Client
    attr_reader :rows, :queries, :writes
    attr_accessor :cap, :after_query, :failure_at, :user

    def initialize(cap, rows = nil)
      @cap, @queries, @writes, @user = cap, [], [], 'Bob'
      @rows = rows || [
        [1, 'Alice', 'Alice', 'uno'], [2, 'Bob', 'Mallory', 'uno'],
        [3, 'Alice', 'Alice', 'rummy'], [4, 'Carol', 'Carol', 'uno'],
        [5, 'Dave', 'Dave', 'rummy'], [6, 'Bob', 'Bob', 'uno'],
        [7, 'Sender', 'Sender', 'uno']
      ].map { |id, name, author, game| row(id, name, author, game) }
    end

    def row(id, name, author, game)
      {'__id' => id, '__insertion_user' => author, 'username' => name,
        'format' => 1, 'games' => JSON.generate([game])}
    end

    def api_data(method, path, params)
      values = JSON.parse(JSON.generate(params))
      return query(values) if method == 'POST' && path == "#{PATH}/query"

      @writes << [method, path, values]
      if method == 'PATCH' && path.start_with?("#{PATH}/")
        found = owned(path.split('/').last.to_i)
        found.merge!(values.fetch('values'))
        {'row' => found.dup}
      elsif method == 'POST' && path == PATH
        found = values.fetch('values').merge('__id' => (@rows.map { |entry| entry.fetch('__id') }.max || 0) + 1,
          '__insertion_user' => @user)
        @rows << found
        {'row' => found.dup}
      elsif method == 'POST' && path == "#{PATH}/bulk" && values.fetch('operation') == 'delete'
        removed = values.fetch('ids').map { |id| owned(id) }
        removed.each { |entry| @rows.delete(entry) }
        {'count' => removed.length}
      else
        raise "Unexpected native request #{method} #{path}"
      end
    end

    def query(values)
      @queries << values
      raise IOError, 'later page unavailable' if @queries.length == @failure_at
      selected = @rows.select do |entry|
        values.fetch('where', {}).all? do |key, value|
          value.is_a?(Hash) ? value.keys == ['gte'] && entry.fetch(key) >= value.fetch('gte') : entry[key] == value
        end
      end.sort_by { |entry| entry.fetch('__id') }
      key, direction = values.fetch('order').fetch(0)
      raise 'Wrong query order' unless key == '__id' && %w[asc desc].include?(direction)
      selected.reverse! if direction == 'desc'
      selected = selected.drop(values.fetch('offset', 0)).first([values.fetch('limit'), @cap].min)
      result = selected.map { |entry| entry.slice(*values.fetch('columns')) }
      @after_query.call(self, values, result) if @after_query
      {'rows' => result}
    end

    def owned(id)
      found = @rows.find { |entry| entry['__id'] == id }
      raise 'Attempted to change a foreign row' unless found && found['__insertion_user'] == @user
      found
    end
  end

  def self.assert(value, message)
    raise message unless value
    @checks = @checks.to_i + 1
  end

  def self.check(name)
    yield
    puts "PASS #{name}"
  rescue StandardError => error
    (@failures ||= []) << "#{name}: #{error.class}: #{error.message}"
    warn "FAIL #{@failures.last}"
  end

  def self.preferences(client)
    table = EltenLink::Apps::AppTable.new(client, 'watch-pagination', 'table_watch_preferences')
    GameRoomTableWatch::Preferences.new(table, games: %w[uno rummy])
  end

  def self.recipients(repository)
    repository.recipients('uno', online: %w[Alice ALICE Bob Carol Dave Mallory Sender], sender: 'Sender')
  end

  [1, 2, 3, 1000].each do |cap|
    check("native recipients cap #{cap}") do
      client = Client.new(cap)
      repository = preferences(client)
      assert(recipients(repository) == %w[ALICE Carol Bob], 'Short page lost recipients or trusted a forged/duplicate preference')
      assert(client.writes.empty?, 'Recipient read wrote defaults')
      assert(client.queries.first == {'where' => {}, 'columns' => COLUMNS, 'order' => [['__id', 'desc']], 'limit' => 1},
        'Initial maximum ID was not captured by one projected query')
      pages = client.queries.drop(1)
      assert(pages.length == (7.0 / cap).ceil, 'Short page ended the scan or maximum ID caused an extra read')
      assert(pages.all? { |query| query['columns'] == COLUMNS && query['order'] == [['__id', 'asc']] &&
        query['limit'] == 1000 && query['where'].keys == ['__id'] && !query.key?('offset') },
        'Recipients used per-user HTTP or unstable offsets/projection')
      before = client.queries.length
      assert(recipients(repository) == %w[ALICE Carol Bob] && client.queries.length == before,
        'Complete bounded query snapshot was not reused')
    end

    check("native own preferences cap #{cap}") do
      client = Client.new(cap)
      client.rows << client.row(8, 'Bob', 'Bob', 'rummy')
      repository = preferences(client)
      assert(repository.load('Bob') == ['uno'], 'Foreign prefix or short page hid the canonical owned preference')
      assert(client.writes.empty?, 'Load changed private settings')
      assert(client.queries.all? { |query| query.dig('where', 'username') == 'Bob' }, 'Own-row filter was lost during pagination')
      recipients(repository)
      assert(repository.save('Bob', ['rummy']) == ['rummy'], 'Could not save paginated own preferences')
      assert(client.rows.select { |entry| entry['__insertion_user'] == 'Bob' }.map { |entry| entry['__id'] } == [6],
        'Save created a new identity or left a later duplicate')
      assert(client.rows.find { |entry| entry['__id'] == 2 }['__insertion_user'] == 'Mallory', 'Foreign row was removed')
      assert(client.writes.map { |method, path, _| [method, path] } == [['PATCH', "#{PATH}/6"], ['POST', "#{PATH}/bulk"]],
        'Save did not update only the canonical row and remove only its owned duplicate')
      assert(recipients(repository) == %w[ALICE Carol], 'Save did not invalidate the complete recipients snapshot')
    end
  end

  check('empty table and explicit EOF after concurrent deletion') do
    client = Client.new(1, [])
    repository = preferences(client)
    assert(recipients(repository).empty? && client.queries.length == 1 && client.writes.empty?, 'Empty table did not stop safely')
    client = Client.new(2)
    client.after_query = ->(source, _query, _result) { source.rows.reject! { |entry| entry['__id'] >= 3 } if source.queries.length == 2 }
    assert(recipients(preferences(client)) == ['ALICE'], 'Mutable table EOF after deletion did not terminate')
    assert(client.queries.length == 3, 'Empty page did not stop pagination')
  end

  check('stable ID boundary and deletion before the next page') do
    client = Client.new(2)
    client.after_query = lambda do |source, _query, _result|
      if source.queries.length == 1
        source.rows << source.row(8, 'Late', 'Late', 'uno')
      elsif source.queries.length == 2
        source.rows.delete_if { |entry| entry['__id'] == 1 }
      end
    end
    repository = preferences(client)
    actual = repository.recipients('uno', online: %w[Alice Bob Carol Late Sender], sender: 'Sender')
    assert(actual == %w[Alice Carol Bob], 'Offset deletion skipped a stable row or a new row crossed the initial boundary')
    assert(client.queries.length == 5 && client.queries.last.dig('where', '__id', 'gte') == 7, 'Cursor did not advance by stable ID')
  end

  check('later failure never caches a partial recipient list') do
    client = Client.new(2)
    client.failure_at = 3
    repository = preferences(client)
    failed = begin; recipients(repository); false; rescue IOError; true; end
    assert(failed, 'Later page error was returned as success')
    client.failure_at = nil
    assert(recipients(repository) == %w[ALICE Carol Bob], 'Later page error cached a partial response')
  end

  [:repeat, :reverse, :duplicate, :zero_id, :string_id, :wrong_filter, :too_many].each do |fault|
    check("invalid native page #{fault}") do
      client = Client.new(2)
      client.after_query = lambda do |source, query, result|
        if source.queries.length == 2
          case fault
          when :reverse then result.reverse!
          when :duplicate then result[1] = result[0].dup
          when :zero_id then result[0]['__id'] = 0
          when :string_id then result[0]['__id'] = '1'
          when :wrong_filter then result[0]['username'] = 'Other'
          when :too_many then 1001.times { result << result[0].dup }
          end
        elsif fault == :repeat && source.queries.length == 3
          result.replace(source.rows.first(2).map(&:dup))
        end
        raise 'Pagination failed to terminate' if source.queries.length > 10
      end
      repository = preferences(client)
      refused = begin
        fault == :wrong_filter ? repository.load('Bob') : recipients(repository)
        false
      rescue IOError
        true
      end
      assert(refused && client.queries.length <= 3, 'Invalid order, identity or filter did not stop the read')
      assert(client.writes.empty?, 'Invalid response caused a write')
      client.after_query = nil
      assert(recipients(repository) == %w[ALICE Carol Bob], 'Invalid response poisoned the snapshot cache')
    end
  end

  [nil, {}, [nil], [{'__id' => 1.0}]].each do |response|
    check("invalid table response #{response.inspect}") do
      table = Object.new
      table.define_singleton_method(:select) { |**_options| response }
      repository = GameRoomTableWatch::Preferences.new(table, games: ['uno'])
      refused = begin; recipients(repository); false; rescue IOError; true; end
      assert(refused, 'Invalid table page was normalized into an empty or valid response')
    end
  end

  raise @failures.join("\n") if @failures && !@failures.empty?
  puts "PASS native table-watch pagination: #{@checks} assertions"
end
