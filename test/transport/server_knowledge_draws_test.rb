require_relative '../support/session_runner'
require_relative '../../games/quiz_party'
require_relative '../../games/duck_racing'

class NoKnowledgeEntropy
  def roll(**); raise 'Live draw consulted local entropy'; end
end

[GameRoomGames::Categories.new, GameRoomGames::QuizParty.new, GameRoomGames::DuckRacing.new].each do |game|
  h = NativeRoomHarness.new(game:game,users:%w[Alice Bob Carol])
  h.start
  ctx = GameRoomGames::ActionContext.new(session_id:h.session['__id'],table_owner:'Alice',
    random_source:NoKnowledgeEntropy.new, server_random:true, now:Time.now.to_i,
    local_data:{'duck_host'=>true})
  h.view('Alice').next_random_values = (1..16).to_a
  selection = game.automatic_action(h.replay('Alice'),'Alice',context:ctx)
  h.submit('Alice',selection,context:ctx)
  if game.id == 'quiz'
    actor = h.replay('Alice').current_player
    choice = game.legal_actions(h.replay(actor),actor,context:ctx).first
    h.submit(actor,choice,context:ctx)
    h.view('Alice').next_random_values = Array.new(16,15)
    h.submit('Alice',game.automatic_action(h.replay('Alice'),'Alice',context:ctx),context:ctx)
    assert(h.replay('Alice').state[:phase] == :answering, 'Question not selected')
  elsif game.id == 'categories'
    assert(h.replay('Alice').state[:phase] == :answering, 'Letter not selected')
  else
    assert(h.replay('Alice').state[:race], 'Race not started')
  end
  events = h.events('Alice')
  assert(events.size == h.replay('Alice').accepted_events.size, "#{game.id}: random action rejected")
  # JSON-normalize the RNG-bearing Duck state instead of comparing Random object identities.
  snapshots = h.users.map { |u| Marshal.dump(GameRoomTest::ReplaySnapshot.capture(h.replay(u))) }
  assert(snapshots.uniq.size == 1, "#{game.id}: public state differs")
  legacy = events.map { |e| e.reject { |k,_| k == '__server_random' } }
  restored = game.replay(h.session,legacy,h.repositories['Alice'])
  assert(Marshal.dump(restored.state) == Marshal.dump(h.replay('Alice').state), "#{game.id}: archive replay differs")
  raw = legacy.select { |e| GameRoomServerRandom.actions(game.id).include?(e['action']) }
  begin
    h.write('Alice',raw)
    raise 'Client-authored draw accepted'
  rescue ArgumentError => error
    raise unless error.message.include?('server draw')
  end
  host = h.view('Alice')
  host.transfer_ownership(host.participants.find { |p| p.user == 'Carol' })
  h.view('Bob').leave
  h.add_client('Bob')
  assert(h.join('Bob'), 'Rejoin failed')
  assert(Marshal.dump(h.replay('Bob').state) == Marshal.dump(h.replay('Carol').state), 'Return diverged')
  puts "PASS server #{game.id}: native entropy, shared writer, ordered replay, owner/return, archive dialect"
end
