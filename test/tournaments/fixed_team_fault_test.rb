# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
context, service, reference = fixture
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
with_backend(context) do |backend, build, _, _, directory|
  shown = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source), intent_id: 'fault')
  assert(T::LocalFixedTeamPlanBackend.const_defined?(:Unconfirmed), 'RED_FT1: brak jawnej niepewności po replace')
  path = File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')
  original = File.method(:rename)
  primary = IOError.new('Niepewna odpowiedź po atomowym zastąpieniu')
  primary.set_backtrace(['fault_replace.rb:1'])
  renames = 0
  File.define_singleton_method(:rename) do |from, to|
    result = original.call(from, to)
    if to == path
      renames += 1
      raise primary
    end
    result
  end
  begin
    error = assert_raises(T::LocalFixedTeamPlanBackend::Unconfirmed) { backend.accept(preview: shown) }
    assert(error.cause.equal?(primary))
    assert_equal(['fault_replace.rb:1'], error.cause.backtrace)
    assert_equal('fault', error.intent_id)
  ensure
    File.define_singleton_method(:rename, original)
  end
  bytes = File.binread(path)
  record = build.call.readback(intent_id: 'fault')
  assert_equal(shown, record['preview'])
  assert_equal(bytes, File.binread(path))
  assert_equal(1, renames, 'Odzyskanie nie wykonuje ponownej akceptacji')
  oracle_file('oracle.json', {'record' => record, 'renames' => renames, 'uncertainty' => error.class.name,
    'primary' => error.cause.message, 'backtrace' => error.cause.backtrace})
end
puts 'FT1: niepewny replace i odczyt bez ponawiania accept — OK'
