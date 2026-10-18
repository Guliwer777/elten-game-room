require_relative '../support/private_card_games'
require_relative '../support/native_private_messages'
require_relative '../../games/taboo'

game = GameRoomGames::Taboo.new
h, runners = PrivateCardGamesTest.create(game, users:%w[Alice Bob Carol Dave])
h.add_client('Observer')
assert(h.join('Observer'), 'observer join failed')
h.as('Observer') { h.transports['Observer'].set_observer(h.table,true,actor:'Observer') }
h.view('Alice').transfer_ownership(h.view('Alice').participants.find { |p| p.user == 'Observer' })
runners['Observer'] = runner_for(h,'Observer')
4.times { PrivateCardGamesTest.tick(h,runners) }
giver = h.replay('Observer').current_player
h.instance_variable_set(:@session,h.repositories[giver].snapshot_for(h.session).session)
r = h.replay(giver)
h.submit(giver,{'action'=>'start','token'=>game.token(r.state)},context:GameRoomGames::ActionContext.new(now:r.state[:time],table_owner:'Observer'))
clock = Struct.new(:value) { def now(_); value; end; def now_f(_); value.to_f; end }.new(h.replay(giver).state[:deadline])
runners['Observer'].instance_variable_set(:@clock,clock)
8.times { PrivateCardGamesTest.tick(h,runners) }
assert(h.replay('Observer').state[:phase] == :describing,'observer did not start timer')
assert(game.card_lines(h.replay('Observer').state,'Observer').empty?,'observer sees secret')
r = h.replay('Observer')
ctx = GameRoomGames::ActionContext.new(now:r.state[:deadline],table_owner:'Observer')
result, plan = game.action_for({'action'=>'timeout','token'=>game.token(r.state)},r,'Alice',context:ctx)
assert(result == :ok,'observer timeout planning failed')
h.as('Observer') { h.repositories['Observer'].append_events(session:h.repositories['Observer'].snapshot_for(h.session).session,
  sequence:h.repositories['Observer'].next_sequence(h.session,h.events('Observer')),events:plan.events,actor:'Alice',controller:true) }
8.times { PrivateCardGamesTest.tick(h,runners) }
assert(h.replay('Observer').state[:phase] == :review,'observer timeout failed')
assert(game.send(:private_review_ready?,h.replay('Observer').state),'observer review stalled')
# A host's moderation permission must not authorize guessing for a player.
packet = GameRoomActionPayload.commands('taboo',{'action'=>'correct','revision'=>0,'time'=>1,'token'=>'fake'})
commands = packet.map { |c| {'action'=>c.action,'value'=>c.value} }
assert(!GameRoomPrivateCards.valid_commands?('taboo',commands,controlled:true,host:true,pool:nil,random:nil),'host can impersonate a guess')
runners.each_value(&:close)
puts 'PASS private Taboo observer host: timer, reveal, review, no secret and no player impersonation'
