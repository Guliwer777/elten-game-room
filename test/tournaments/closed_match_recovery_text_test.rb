require_relative '../support/settings_widget'

app = EltenGameRoom.new
messages = []
service = Object.new
service.define_singleton_method(:open_match) do |**|
  raise GameRoomTournaments::OrdinaryMatchService::Blocked, :closed_match_needs_recovery
end
app.define_singleton_method(:ordinary_tournament_service) { |_| service }
app.define_singleton_method(:run_network_task) { |*, **, &work| work.call }
app.define_singleton_method(:alert) { |message| messages << message }
%i[activate_table_transport deliver_table_invitation show_table_screen].each do |method|
  app.define_singleton_method(method) { |*| raise "Blocked match attempted #{method}" }
end
app.send(:open_ordinary_tournament_match, {}, {'match_id' => 'unavailable', 'leg' => 1})
assert(messages.size == 1, 'Blocked match must explain its state once')
assert(messages.first.include?('cannot be started again'), 'Uncertain started match must not advise a second start')
assert(messages.first.include?('Check pending changes'), 'Recovery must name the available tournament-list action')
assert(!messages.first.downcase.include?('saved game'), 'Tournament saves cannot recover this match')
puts 'PASS unavailable started match advises an available read-only recovery action, without a save or retry'
