require_relative "game_room_clock"
require_relative "table_query_snapshot"
class GameRoomUserRegistry
  TABLE_NAME = "game_room_users".freeze
  PAGE_LIMIT = 1_000

  def initialize(server_tables:)
    @server_tables = server_tables
    @query_snapshot = GameRoomTableQuerySnapshot.new
  end

  def register(username:, version:, build_id:, capabilities: [])
    clean_username = username.to_s.strip
    raise ArgumentError, "Game Room username is required" if clean_username.empty?

    values = {
      "username" => clean_username,
      "version" => version.to_s,
      "build_id" => build_id.to_i,
      "capabilities" => Array(capabilities).map(&:to_s).reject(&:empty?).uniq.sort.join(",")
    }
    existing = rows_for(clean_username).find { |row| owned_identity?(row, clean_username) }
    return users_table.insert(values.merge("registered_at" => GameRoomClock.now.to_i)) if existing == nil

    changes = values.reject { |key, value| existing[key].to_s == value.to_s }
    return existing if changes.empty?

    updated = users_table.update(row_id(existing), changes)
    updated.is_a?(Hash) ? updated : existing.merge(changes)
  ensure
    @query_snapshot.invalidate
  end

  def registered(users)
    return [] if users.to_a.empty?
    rows = @query_snapshot.fetch { verified_usernames.map { |name| { 'username' => name } } }
    registered = rows.each_with_object({}) do |row, result|
      username = row.fetch('username')
      result[username.downcase] = true
    end
    users.to_a.select { |user| registered.key?(user.to_s.strip.downcase) }
  end

  private

  def users_table
    @users_table ||= @server_tables.fetch(TABLE_NAME)
  end

  def rows_for(username)
    users_table.select(
      where: { "username" => username.to_s },
      order: [["registered_at", "asc"]],
      limit: 100
    ).to_a
  end

  def verified_usernames
    latest = registry_rows(columns: ['__id'], order: [['__id', 'desc']], limit: 1).first
    return [] unless latest

    upper, previous = latest.fetch('__id'), 0
    result = []
    loop do
      rows = registry_rows(where: {'__id' => {'gte' => previous + 1}},
        columns: ['username', '__insertion_user', '__id'],
        order: [['__id', 'asc']], limit: PAGE_LIMIT)
      break if rows.empty?

      unless rows.first.fetch('__id') > previous &&
          rows.each_cons(2).all? { |first, second| first.fetch('__id') < second.fetch('__id') }
        raise IOError, 'Game Room registry pagination did not advance'
      end
      rows.each do |row|
        break if row.fetch('__id') > upper
        username = verified_username(row)
        result << username if username != nil
      end
      previous = rows.last.fetch('__id')
      # A short nonempty page is not EOF; stay within the initial ID boundary.
      break if previous >= upper
    end
    result.uniq { |username| username.downcase }
  end

  def registry_rows(**options)
    rows = users_table.select(**options)
    unless rows.is_a?(Array) && rows.length <= options.fetch(:limit) &&
        rows.all? { |row| row.is_a?(Hash) && row['__id'].is_a?(Integer) && row['__id'].positive? }
      raise IOError, 'Invalid Game Room registry response'
    end
    rows
  end

  def verified_username(row)
    username = row["username"].to_s.strip
    author = row["__insertion_user"].to_s.strip
    return nil if username.empty? || author.empty? || username.casecmp(author) != 0

    author
  end

  def owned_identity?(row, username)
    verified = verified_username(row)
    verified != nil && verified.casecmp(username.to_s) == 0 && row_id(row) > 0
  end

  def row_id(row)
    (row["__id"] || row["id"]).to_i
  end
end
