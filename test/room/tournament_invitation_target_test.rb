# encoding: UTF-8
require_relative '../support/invitation_fresh_endpoint'

broker = NativeLiveSessionsBroker.new
gateway = DurableNoticeGateway.new
alice = InvitationAppDriver.new(broker, 'Alice', gateway)
bob = InvitationAppDriver.new(broker, 'Bob', gateway)
$game_room_test_user = 'Alice'
old = alice.transport.create_room(name: 'Stary', game: 'uno', owner: 'Alice', game_options: '{}')
$game_room_test_user = 'Bob'
target = bob.transport.create_room(name: 'Cel', game: 'uno', owner: 'Bob', game_options: '{}', private_table: true)
bob.send(:deliver_table_invitation, target, 'Alice')
$game_room_test_user = 'Alice'
invitation = alice.send(:load_pending_invitations).first.fetch(:invitation)
acceptance = alice.send(:invitation_acceptance)
outcome = begin
  acceptance.join(invitation, current: old, binding: {})
rescue ArgumentError => error
  error
end
assert(outcome.respond_to?(:result) && outcome.result == :coordination_unavailable,
  'Bound bez capability ma jawnie odmówić, a nie zgubić opcjonalny kontrakt')
assert(broker.cores.fetch(old['__live_session_id']).participants.key?('alice'), 'Stary stół utracony')
assert(!broker.cores.fetch(target['__live_session_id']).participants.key?('alice'), 'Establish mimo odmowy')
assert(gateway.rows['Alice'].none?(&:revoked), 'Complete mimo odmowy')
puts 'PASS bound bez capability: zero establish/leave/complete'

require_relative '../support/tournament_match_invitation'
scenario = TournamentMatchScenario.new
outcome = scenario.join
assert(outcome.result.respond_to?(:entered?) && outcome.result.entered? && outcome.left_current, "Zgodny bound nie wszedł: #{outcome.inspect}; consent=#{scenario.consent.inspect}")
assert(scenario.calls[:leave] == 1 && scenario.calls[:complete] == 1, 'Brak końca poprawnego przepływu')
assert(scenario.membership.release_count == 0, 'Posprzątano przyjętą membership')
puts 'PASS bound zgodny: rzeczywisty AcceptInvitation i NativeLiveSessions fixture'

scenario = TournamentMatchScenario.new
scenario.membership.after_establish = -> { scenario.change_target { |data| data['players'].reverse! } }
outcome = scenario.join
assert(outcome.result == :target_changed && !outcome.left_current, 'Zmiana podczas establish nie zatrzymała leave')
assert(scenario.old_present? && !scenario.target_present?, 'Nie zachowano starej / nie sprzątnięto nowej membership')
assert(scenario.calls[:complete] == 0 && scenario.membership.release_count == 1, 'Niepoprawny cleanup lub complete')

[2, 3].each do |count|
  scenario = TournamentMatchScenario.new(game_id: count == 2 ? 'uno' : 'three_five_eight', names: %w[Alice Bob Carol].take(count))
  scenario.port.during_read = lambda do
    if scenario.port.calls.size == 4
      scenario.change_target { |data| data['reservation']['revision'] = 'changed-before-leave' }
    end
  end
  outcome = scenario.join
  assert(outcome.result == :target_changed && scenario.calls[:leave] == 0, 'Brak świeżego guardu bezpośrednio przed leave')
  assert(scenario.old_present? && !scenario.target_present?, 'Beforeleave nie zachował starego stołu')
end
puts 'PASS granice po establish i przed leave: 2/3 osoby, cleanup'

# Alternatywne wejście nie może wywołać starego reconnect bez guardu.
scenario = TournamentMatchScenario.new
scenario.context['cancelled'] = true
reconnected = begin
  scenario.acceptance.reconnect(scenario.invitation, binding: scenario.binding, consent: scenario.consent)
rescue ArgumentError => error
  error
end
assert(reconnected.equal?(false) && scenario.calls[:reconnect] == 0 && scenario.membership.establish_count == 0,
  'Reconnect bound musi odmówić anulowanej zgodzie')
puts 'PASS reconnect nie omija guardu'

# Bound nie może stosować zwykłych defaults roli po zatwierdzeniu celu.
scenario = TournamentMatchScenario.new
outcome = scenario.join
assert(outcome.result.entered? && scenario.calls[:apply_role] == 0, 'Bound zastosował zwykły przydział ról')
# Zmiana kontekstu podczas opuszczania stołu nie uprawnia do complete.
scenario = TournamentMatchScenario.new
callbacks = scenario.acceptance.instance_variable_get(:@membership)
leave = callbacks.leave
callbacks.leave = ->(table) { result = leave.call(table); scenario.context['epoch'] += 1; result }
outcome = scenario.join
assert(outcome.left_current && outcome.result == :context_changed && scenario.calls[:complete] == 0,
  'Callback po leave użył starej zgody')
puts 'PASS bound: brak defaults ról, guard po I/O leave'

# Nie wystarczy porównać obiektu celu PRZED callbackiem odczytu.
scenario = TournamentMatchScenario.new
scenario.port.during_read = -> { scenario.invitation.table['__live_session_id'] = 'substituted-native' if scenario.port.calls.size == 2 }
outcome = begin
  scenario.join
rescue KeyError => error
  error
end
assert(scenario.membership.establish_count == 0 && outcome.result == :target_changed && scenario.old_present?,
  'Podmiana obiektu celu podczas readback przeszła do establish')
puts 'PASS dokładny target po I/O'

require_relative '../support/tournament_match_cases'
TournamentMatchCases.dialog_changes
TournamentMatchCases.context_changes
TournamentMatchCases.readback_failures
TournamentMatchCases.program_errors
TournamentMatchCases.ownership
puts 'PASS macierz dialog/kontekst/receipt/ProgramError/timeout/ownership'

# Prawdziwy prywatny guard starego stołu, bez zmiany oryginalnej regresji.
game = GameRoomGames::Battleship.new
harness = NativeRoomHarness.new(game: game, users: %w[Alice Carol])
scenario = TournamentMatchScenario.new(original: harness)
scenario.membership.after_establish = lambda do
  harness.start
  initial = GameRoomSimulation::Environment.new_game(game: game, players: %w[Alice Carol], seed: 11)
  initial.events.each do |event|
    harness.repositories.fetch('Alice').append_events(session: harness.session, sequence: event['sequence'],
      events: [GameRoomGames::EventCommand.new(action: event['action'], value: event['value'])],
      actor: event['actor'], controller: true)
  end
end
blocked = begin
  scenario.join
rescue GameRoomNetworkErrors::GamePaused => error
  error
end
assert(blocked.is_a?(GameRoomNetworkErrors::GamePaused), 'Bound ominął late private-phase guard')
assert(scenario.old_present? && !scenario.target_present? && scenario.calls[:complete] == 0,
  'Late private-phase utracił stół lub membership/complete')
assert(harness.core.owner == 'Alice' && !harness.core.closed, 'Prywatny stół zmienił gospodarza')
puts 'PASS bound late private phase przez NativeRoomHarness i rzeczywiste departure guard'

[false, true].each do |bound|
  scenario = TournamentMatchScenario.new
  changed = scenario.binding.to_h['options'].merge('draw_responses' => !scenario.binding.to_h['options']['draw_responses'])
  confirms = 0
  scenario.alice.define_singleton_method(:confirm) do |_text|
    confirms += 1
    $game_room_test_user = 'Bob'
    scenario.bob.transport.update_room(scenario.target, { 'game_options' => JSON.generate(changed) }, actor: 'Bob')
    $game_room_test_user = 'Alice'
    # Symulacja portu odzwierciedla rzeczywistą zmianę projekcji native fixture.
    scenario.change_target { |data| data['options'] = changed }
    true
  end
  if bound
    scenario.alice.confirm('Zgoda na dokładny cel')
    outcome = scenario.join
    assert(outcome.result == :target_changed && scenario.old_present? && !scenario.target_present?, 'Bound przyjął zmienione opcje po confirm')
  else
    joined = scenario.alice.send(:accept_pending_invitation, scenario.invitation)
    assert(joined && JSON.parse(joined['game_options']) == changed && !scenario.old_present?, 'Zmieniono zwykłą zgodę na legalne opcje')
  end
  assert(confirms == 1, 'Pominięto albo powtórzono confirm')
end

scenario = TournamentMatchScenario.new
scenario.alice.send(:leave_current_table, scenario.old)
scenario.alice.send(:establish_invited_table_transport, scenario.invitation.table)
assert(scenario.acceptance.reconnect(scenario.invitation, binding: scenario.binding, consent: scenario.consent), 'Zgodny bound reconnect odmówiony')
assert(scenario.calls[:reconnect] == 0 && scenario.calls[:complete] == 1 && scenario.membership.release_count == 0,
  'Reconnect użył ordinary lub sprzątnął already_here')
puts 'PASS realna zmiana opcji w confirm: bound/ordinary; zgodny reconnect'

scenario = TournamentMatchScenario.new
scenario.port.during_read = lambda do
  if scenario.port.calls.size == 3
    core = scenario.broker.cores.fetch(scenario.target['__live_session_id'])
    core.participants['alice'] = NativeLiveSessionsBroker::Participant.new(id: 'replacement-after-receipt', user: 'Alice')
    scenario.membership.last_receipt['participant_id'].replace('replacement-after-receipt')
    scenario.context['epoch'] += 1
  end
end
outcome = scenario.join
assert(outcome.result == :context_changed && scenario.target_present? && scenario.old_present?,
  'Mutowalny receipt skierował cleanup do zastąpionej generacji')
puts 'PASS detached receipt własnej membership'

scenario = TournamentMatchScenario.new
callbacks = scenario.acceptance.instance_variable_get(:@membership)
complete = callbacks.complete
callbacks.complete = ->(*args) { result = complete.call(*args); scenario.context['epoch'] += 1; result }
outcome = scenario.join
assert(outcome.result == :context_changed && outcome.left_current && !scenario.target_present?,
  'Callback po complete przywrócił prawo starego kontekstu')
puts 'PASS wynik complete nie omija kontroli kontekstu'

scenario = TournamentMatchScenario.new(game_id: 'three_five_eight', names: %w[Alice Bob Carol])
outcome = scenario.join
assert(outcome.result.entered? && scenario.port.calls.all? { |call| call.first['players'].map { |p| p['account'] } == %w[alice bob carol] },
  'Zgodne wejście trzyosobowe obcięło skład')
# Niepełnego dowodu własności nie wolno naprawiać niebezpiecznym table_id cleanup.
scenario = TournamentMatchScenario.new
port = scenario.membership
establish = port.method(:establish)
port.define_singleton_method(:establish) do |**kwargs|
  receipt = establish.call(**kwargs).dup
  receipt.delete('membership_generation')
  receipt.freeze
end
outcome = scenario.join
assert(outcome.result == :membership_unconfirmed && scenario.calls[:leave] == 0 && scenario.calls[:complete] == 0 && scenario.membership.release_count == 0,
  'Niepełny receipt po establish nadał uprawnienie lub niebezpieczny cleanup')
assert(scenario.old_present?, 'Niepełny receipt utracił stary stół')
puts 'PASS pełne trzy osoby i odmowa niepełnego receipt membership (wymaga reconcile portu)'
