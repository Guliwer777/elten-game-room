# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/assertions'
include GameRoomTest::Assertions
require_relative '../support/tournament_match_readback'
path = File.expand_path('../../lib/tournaments/match_target_guard.rb', __dir__)
require path if File.file?(path)
assert(defined?(GameRoomTournaments::MatchTargetGuard), 'Brak read-only guardu')
fixture = TournamentMatchFixture
binding = GameRoomTournaments::MatchBinding.build(fixture.payload, registry: fixture.registry)
context = fixture.context(binding)
reference = fixture.reference
port = TournamentMatchReadback.new(binding, context, reference)
guard = GameRoomTournaments::MatchTargetGuard.new(port: port, port_identity: 'fixture-authority', context: -> { context })
consent = guard.consent(binding: binding, invitation_ref: reference)
target = { '__id' => 42, '__live_session_id' => binding.to_h['native_uuid'] }
check = -> { guard.check(binding: binding, consent: consent, table: target, invitation_id: 123, user: 'Alice') }
assert(check.call == :ok, 'Zgodny świeży odczyt odmówiony')
assert(check.call == :ok && port.calls.map(&:last).uniq.size == 2, 'Cache zamiast świeżego odczytu')
original = port.response
[
  ->(r) { r['status'] = 'pending' }, ->(r) { r['status'] = 'unknown' },
  ->(r) { r['status'] = 'unsupported' }, ->(r) { r['status'] = 'conflict' },
  ->(r) { r['capabilities'] = {} }, ->(r) { r['receipt'].delete('receipt_revision') },
  ->(r) { r['receipt']['generation'] = 'old' }, ->(r) { r['receipt']['state'] = 'received' },
  ->(r) { r['account'] = 'bob' }, ->(r) { r['scope']['backend_identity'] = 'other' },
  ->(r) { r['port_identity'] = 'untrusted' },
  ->(r) { r['binding']['reservation']['fencing'] = 8 },
  ->(r) { r['binding']['players'].reverse! },
  ->(r) { r['binding']['players'][0]['role'] = 'observer' },
  ->(r) { r['binding']['options']['draw_responses'] = 1 },
  ->(r) { r['binding']['native_uuid'] = 'other' }
].each_with_index do |mutation, index|
  port.response = GameRoomTournaments::Publication::Data.copy(original)
  mutation.call(port.response)
  assert(check.call != :ok, "Guard przyjął konflikt #{index}")
end
port.response = original
port.during_read = -> { context['epoch'] += 2 }
assert(check.call == :context_changed, 'A→B→A przywróciło prawa starego callbacka')
port.during_read = nil
assert(check.call == :context_changed, 'Stara zgoda ożyła po zmianie epoki')
puts 'PASS guard: świeży port, exact target/receipt, strict typy, context epoch'

context = fixture.context(binding)
port = TournamentMatchReadback.new(binding, context, reference)
port.response['port_identity'] = ''
empty_guard = GameRoomTournaments::MatchTargetGuard.new(port: port, port_identity: '', context: -> { context })
empty_consent = empty_guard.consent(binding: binding, invitation_ref: reference)
assert(empty_guard.check(binding: binding, consent: empty_consent, table: target, invitation_id: 123, user: 'Alice') == :coordination_unavailable,
  'Pusta tożsamość portu udaje zaufany autorytet')
puts 'PASS brak tożsamości portu odmawia'
