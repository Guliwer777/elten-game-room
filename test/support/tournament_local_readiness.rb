# encoding: UTF-8
require_relative 'tournament_local_workspace'
require_relative '../../lib/tournaments/local_workspace'
require_relative '../../lib/tournaments/local_readiness_backend'
require_relative '../../lib/tournaments/readiness_service'

module TournamentLocalReadinessSupport
  include TournamentLocalWorkspaceSupport
  T = GameRoomTournaments

  def prepared(ctx, game: 'chess', names: %w[Alicja Bob Celina])
    author = ctx.workspace('Organizator')
    result = author.publish(**local_params(draft: draft(game), intent_id: game))
    raise 'Niepotwierdzona publikacja' unless result['status'] == 'confirmed'
    row = author.load['announcements'].find { |item| item['game'] == game }
    names.each { |actor| raise('Niepotwierdzone dołączenie') unless ctx.workspace(actor).join(row['__id'])['status'] == 'confirmed' }
    ctx.now = 201
    ref = {'author' => row['__insertion_user'], 'publication_key' => row['publication_key']}
    candidate = author.schedule_candidate(publication_ref: ref)
    source = ->(reference) { author.schedule_candidate(publication_ref: reference) }
    backend = T::LocalReadinessBackend.new(directory: File.join(ctx.directory,'k03'), actor: names.first, clock: -> {ctx.now}, source: source)
    anchor = backend.accept(candidate: candidate)
    match = candidate.to_h['matches'].find { |item| item['players'].include?(names.first.downcase) }
    target = backend.target(plan_id: anchor['plan_id'], match_id: match['match_id'])
    context = {'account'=>names.first.downcase,'backend_identity'=>backend.identity,'runtime_id'=>'test-runtime',
      'runtime_epoch'=>1,'auth_epoch'=>1,'backend_epoch'=>1,'cancelled'=>false}
    service = T::ReadinessService.new(port: backend, trusted_identity: backend.identity,
      directory: File.join(ctx.directory,'journal'),context: -> {context})
    request = {'version'=>1,'scope'=>target[:scope],'match_ref'=>target[:match_ref],'availability'=>'ready',
      'expected_ready_revision'=>0,'policy_ref'=>T::LocalReadinessBackend::POLICY}
    {backend: backend, anchor: anchor, target: target, context: context, service: service, request: request,
      candidate: candidate, source: source, directory: File.join(ctx.directory,'journal')}
  end
end
