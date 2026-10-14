# encoding: UTF-8
require_relative 'tournament_coordination_fixture'

# Wyłącznie testowe approval/role, nie reguły zatwierdzone przez użytkownika.
module TournamentExecutionPlanFixture
  F = TournamentCoordinationFixture
  T = GameRoomTournaments
  module_function

  def copy(value)
    T::Publication::Data.copy(value, max_bytes: 262_144, max_nodes: 16_384, max_depth: 12)
  end

  def digest(value)
    Digest::SHA256.hexdigest(JSON.generate(copy(value)))
  end

  def evidence
    request = F.request
    # Jawne przypisania, nie kolejność kandydata. Obserwator też ma pełny PERSON.
    request['players'] = [
      {'account'=>'alice','username'=>'Alice','role'=>'player','seat'=>1,'team'=>nil,'game_role'=>'test-role-a'},
      {'account'=>'bob','username'=>'Bob','role'=>'player','seat'=>0,'team'=>nil,'game_role'=>'test-role-b'}]
    request['observers'] = [{'account'=>'carol','username'=>'Carol','role'=>'observer','seat'=>nil,'team'=>nil,'game_role'=>nil}]
    source = {'backend_identity'=>'fixture:publication', 'publication_ref'=>{'author'=>'Test Organizer','publication_key'=>'publication-1'},
      'publication_digest'=>'a'*64, 'roster_generation'=>'roster-1','schedule_id'=>'schedule-1',
      'roster'=>%w[Alice Bob Carol].map { |name| {'account'=>name.downcase,'username'=>name} },
      'game_id'=>request['game_id'],'options'=>request['options'],'windows'=>[request['window']],
      'matches'=>[{'match_id'=>'match-1','leg'=>1,'accounts'=>%w[bob alice],'window_ids'=>['window-1']}]}
    match = request.select { |key,_| %w[match_id leg execution_generation roles_status role_policy_ref players observers game_id options].include?(key) }
    match['windows'] = [request['window']]
    plan = {'id'=>'plan-1','revision'=>'plan-r1','seal_id'=>'seal-1','seal_revision'=>'seal-r1','source_digest'=>digest(source),
      'approval'=>{'status'=>'confirmed','policy_ref'=>'test-only-approval'},'matches'=>[match]}
    copy({'version'=>1,'status'=>'confirmed','scope'=>request['scope'],'source'=>source,
      'seal'=>{'id'=>'seal-1','revision'=>'seal-r1','source_digest'=>digest(source)},'plan'=>plan,'plan_digest'=>digest({'scope'=>request['scope'],'plan'=>plan})})
  end

  def anchor(evidence)
    source = evidence.fetch('source')
    copy(source.select { |key,_| %w[backend_identity publication_ref publication_digest roster_generation schedule_id].include?(key) }
      .merge('source_digest'=>digest(source)))
  end

  def expected(evidence)
    plan = evidence['plan']; match = plan['matches'].first
    copy(match.reject { |key,_| key=='windows' }.merge('contract_version'=>1,'scope'=>evidence['scope'],
      'seal_id'=>evidence['seal']['id'],'seal_revision'=>evidence['seal']['revision'],
      'plan_id'=>plan['id'],'plan_revision'=>plan['revision'],'window'=>match['windows'].first,'visibility'=>'private'))
  end

  def request(evidence = self.evidence, **changes)
    expected_source = changes.key?(:expected_source) ? changes[:expected_source] : anchor(evidence)
    T::CoordinationRequest.from_execution_plan(**{evidence: evidence, expected_source: expected_source,
      match_id: 'match-1', leg: 1, window_id: 'window-1', registry: TournamentMatchFixture.registry}.merge(changes))
  end

  def frozen_tree?(value)
    return false unless value.frozen?
    children = value.is_a?(Hash) ? value.to_a.flatten(1) : value.is_a?(Array) ? value : []
    children.all? { |item| frozen_tree?(item) }
  end

  def reject(code)
    begin
      yield
    rescue T::Publication::Invalid => error
      F.assert(error.code.eql?(code), "Niepoprawna odmowa: #{error.code.inspect}, oczekiwano #{code.inspect}")
      return
    end
    raise "Nie odrzucono: #{code.inspect}"
  end
end
