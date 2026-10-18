require_relative "log"
require_relative "../../lib/table_watch"

def assert(value, message); raise message unless value; end

class WatchTable
  attr_accessor :user
  attr_reader :rows, :writes, :queries
  def initialize; @rows = []; @writes = []; @queries = []; @user = "Alice"; end
  def select(where: nil, offset: 0, limit: 1000, columns: nil, order: nil, **_)
    @queries << {where: where, offset: offset, limit: limit, columns: columns, order: order}
    rows = @rows.select do |row|
      !where || where.all? do |key, value|
        value.is_a?(Hash) ? value.keys == ["gte"] && row[key] >= value.fetch("gte") : row[key] == value
      end
    end.sort_by { |row| row["__id"] }
    rows.reverse! if order == [["__id", "desc"]]
    (rows[offset, limit] || []).map { |row| columns ? row.slice(*columns) : row.dup }
  end
  def insert(values)
    row = values.merge("__id" => (@rows.map { |item| item["__id"] }.max || 0) + 1, "__insertion_user" => @user)
    @rows << row; @writes << [:insert, row]; row
  end
  def update(id, values)
    row = @rows.find { |item| item["__id"] == id }
    raise "foreign write" unless row["__insertion_user"] == @user
    row.merge!(values); @writes << [:update, id]; row
  end
  def delete(id)
    row = @rows.find { |item| item["__id"] == id }
    raise "foreign deletion" unless row["__insertion_user"] == @user
    @rows.delete(row); @writes << [:delete, id]
  end

  def delete_many(ids)
    ids.each { |id| delete(id) }
    ids.length
  end
end

WatchNotice = Struct.new(:id, :app_uuid, :type, :sender, :metadata, keyword_init: true)

class WatchWorker
  def closed?; @closed == true; end
  def busy?; @operation != nil || @result != nil; end
  def start(&operation); raise "concurrent operation" if busy?; @operation = operation; true; end
  def finish(error = nil)
    @result = error ? [nil, error] : [@operation.call, nil]
    @operation = nil
  end
  def take; result = @result; @result = nil; result; end
  def close; @closed = true; end
end
Limited = Class.new(StandardError) { def status; 429; end }
Uncertain = Class.new(StandardError)
