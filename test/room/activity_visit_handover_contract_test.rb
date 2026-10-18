require_relative '../support/native_room_harness'

h = NativeRoomHarness.new(users: %w[Alice])
repositories = {}
append = lambda do |user, kind, message = nil|
  h.as(user) do
    repository = repositories[user] ||= TableActivityRepository.new(server_tables: {}, transport: h.transports.fetch(user))
    current = h.transports.fetch(user).room_snapshot(h.table).fetch(:table)
    repository.append(table: current, kind: kind, actor: user, message: message)
  end
end
read = lambda do |user|
  h.as(user) do
    current = h.transports.fetch(user).room_snapshot(h.table).fetch(:table)
    repositories.fetch(user).entries_for(current, viewer: user)
  end
end

created = append.call('Alice', 'created')
early = append.call('Alice', 'chat', 'Before Bob joined')
h.add_client('Bob')
assert(h.join('Bob'), 'Bob did not join')
joined = append.call('Bob', 'joined')
after_join = append.call('Alice', 'chat', 'During this visit')
before_transfer = read.call('Bob')
assert(before_transfer.map(&:id) == [joined.id, after_join.id], 'The current-visit boundary did not initially apply')

h.as('Alice') { h.transports.fetch('Alice').transfer_room_owner(h.table, 'Bob') }
after_transfer = read.call('Bob')
assert(after_transfer.none? { |entry| [created.id, early.id].include?(entry.id) },
  'Becoming owner exposed activity from before the current visit')
assert(after_transfer.map(&:id).include?(joined.id) && after_transfer.map(&:id).include?(after_join.id),
  'Owner transfer removed the current visit history')
assert(read.call('Alice').any? { |entry| entry.id == early.id }, 'The former owner lost their uninterrupted visit history')

append.call('Alice', 'left')
h.as('Alice') { h.transports.fetch('Alice').deactivate_table(table_id: h.table['__id']) }
between = append.call('Bob', 'chat', 'Between Alice visits')
assert(h.join('Alice'), 'Alice did not rejoin')
rejoined = append.call('Alice', 'joined')
after_return = append.call('Bob', 'chat', 'After Alice returned')
h.as('Bob') { h.transports.fetch('Bob').transfer_room_owner(h.table, 'Alice') }
returned_owner = read.call('Alice')
assert(returned_owner.none? { |entry| entry.id < rejoined.id },
  'Returning original owner recovered history from an earlier visit')
assert(returned_owner.map(&:id).include?(after_return.id) && returned_owner.none? { |entry| entry.id == between.id },
  'Returned owner has an incorrect current-visit boundary')
unfiltered = h.as('Alice') { repositories.fetch('Alice').entries_for(h.table) }
assert(unfiltered.any? { |entry| entry.id == created.id }, 'Filtering a visit mutated the immutable room history')
puts 'Activity visit handover passed (native transfer, former owner, cold return, immutable unfiltered history)'
