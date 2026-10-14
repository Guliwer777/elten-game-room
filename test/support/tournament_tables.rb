# encoding: UTF-8
require "json"
require "timeout"
require_relative "host_source"
require EltenTestHost.file("src/eltenlink/error.rb")
require EltenTestHost.file("src/eltenlink/apps.rb")
require_relative "../../lib/game_room_server_tables"

# Brak sesji, sieci i stamp; prawdziwy AppTable rozmawia tylko z MemoryClient.
module EltenLink
  class Client
    def self.session_object
      nil
    end
  end
end

module TournamentTablesTestSupport
  def assert(condition, message = "Niespełniona asercja")
    raise message unless condition
  end

  def equal(expected, actual)
    assert(expected.eql?(actual), "Oczekiwano #{expected.inspect}, otrzymano #{actual.inspect}")
  end

  def raises(type)
    begin
      yield
    rescue type => error
      return error
    end
    raise "Oczekiwano #{type}"
  end

  def record(id, **extra)
    {"__id" => id, "__insertion_user" => "Alice", "__insertion_time" => 1_800_000_000,
      "operation_key" => "operation-#{id}"}.merge(extra.transform_keys(&:to_s))
  end

  class Table
    attr_accessor :rows, :cap, :on_select, :on_insert
    attr_reader :selects, :inserts

    def initialize(rows = [])
      @rows, @selects, @inserts = rows, [], []
    end

    def select(where: {}, order: nil, limit: nil)
      @selects << {where: Marshal.load(Marshal.dump(where)), order: order, limit: limit}
      return @on_select.call(@selects.last, @selects.length) if @on_select
      selected = @rows.select do |row|
        where.all? do |key, value|
          if value.is_a?(Hash)
            value.all? do |operator, bound|
              case operator
              when "gte" then row.fetch(key) >= bound
              when "lte" then row.fetch(key) <= bound
              else raise "Nieobsługiwany operator atrapy: #{operator}"
              end
            end
          else
            row[key] == value
          end
        end
      end
      selected = selected.sort_by { |row| row.fetch("__id") }
      selected.reverse! if order == [["__id", "desc"]]
      Marshal.load(Marshal.dump(selected.first([limit || selected.length, @cap || selected.length].min)))
    end

    def insert(values)
      @inserts << Marshal.load(Marshal.dump(values))
      return @on_insert.call(values) if @on_insert
      id = (@rows.map { |row| row.fetch("__id") }.max || 0) + 1
      row = values.merge("__id" => id, "__insertion_user" => "Alice", "__insertion_time" => 1_800_000_000)
      @rows << Marshal.load(Marshal.dump(row))
      row
    end
  end

  class Provider
    attr_accessor :available, :on_fetch
    attr_reader :fetches, :table

    def initialize(table)
      @table, @available, @fetches = table, true, []
    end

    def available?
      @available
    end

    def fetch(name)
      @fetches << name
      @on_fetch.call if @on_fetch
      @table
    end
  end

  class MemoryClient
    attr_accessor :handler
    attr_reader :calls

    def initialize(&handler)
      @handler, @calls = handler, []
    end

    def api_data(method, path, params)
      @calls << [method, path, params]
      @handler.call(method, path, params)
    end
  end
end
