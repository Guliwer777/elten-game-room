# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
require_relative '../../lib/use_cases/accept_invitation'
include TournamentFixedTeamExecutionSupport
class BrakZgodyFT2A
  attr_reader :calls
  def initialize; @calls = []; end
  def read_target(**input)
    @calls << input
    {'status' => 'unconfirmed'}
  end
end
results = []
[[[0, 0, 1, 1], 3], [[0, 1, 0, 1], 0], [[0, 1, 0, 1], 3]].each_with_index do |(template, index), variant|
  context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')) + variant.to_s, template: template)
  players = record['evidence']['plan']['matches'][index]['players'].map { |person| person['username'] }
  players.each do |actor|
    execution_for(context, record, actor) do |facade|
      select_match(facade, record, index)
      assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade, session|
    selected = select_match(facade, record, index)
    result = facade.request_match
    assert_equal(:bound, result[:state])
    target = result[:target].to_h
    assert_equal(selected[:native].to_h, target['native'])
    assert_equal(template, target['native']['options']['team_seats'])
    binding = result[:binding]
    calls = []
    tracker = TracePoint.new(:call) do |point|
      calls << [point.defined_class.to_s, point.method_id.to_s] if %i[start_game start_session invite invite_user].include?(point.method_id)
    end
    table = target['readback']['table']
    invitation = Struct.new(:table, :id).new(table, 17)
    port = BrakZgodyFT2A.new
    target_context = -> { {'scope' => binding.to_h['scope'], 'account' => players.first.downcase,
      'runtime_id' => session.runtime_id, 'epoch' => session.runtime_epoch, 'cancelled' => session.closed?} }
    guard = T::MatchTargetGuard.new(port: port, port_identity: 'lokalna-proba-ft2a', context: target_context)
    reference = {'app_invitation_id' => 17, 'native_invitation_id' => 'niewyslane', 'generation' => 'test-ref',
      'expires_at' => record['evidence']['plan']['matches'][index]['windows'].first['closes'], 'receipt_revision' => 'brak'}
    consent = guard.consent(binding: binding, invitation_ref: reference)
    assert(consent, 'Lokalny obiekt dialogu nie jest autorytatywnym accepted')
    begin
      tracker.enable(target_thread: nil)
      assert_equal(:unconfirmed_target, guard.check(binding: binding, consent: consent, table: table,
        invitation_id: 17, user: players.first, invitation: invitation))
      accept = GameRoomUseCases::AcceptInvitation.new(lobby: nil, transport: nil, invitations: nil,
        membership: nil, user: -> { players.first }, target_guard: guard, bound_membership: nil)
      assert_equal(:unconfirmed_target, accept.join(invitation, current: nil, binding: binding, consent: consent).result)
      assert_equal(:invalid_binding, accept.join(invitation, current: nil, binding: binding, consent: nil).result)
    ensure
      tracker.disable
    end
    assert_equal([], calls)
    assert_equal(2, port.calls.size)
    results << {record: record, target: target, refused_without_k06: true, calls: calls}
  end
end
oracle_file('templates-and-no-consent.json', results)
puts 'GREEN: obydwa szablony i leg2 mają dokładny prywatny cel; realne wejście odmawia bez K06'
