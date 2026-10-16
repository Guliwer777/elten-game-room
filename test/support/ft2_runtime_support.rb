# encoding: UTF-8
require_relative 'tournament_fixed_team_execution_process'
module FT2RuntimeSupport
  include TournamentFixedTeamExecutionProcess
  def state_path(context)
    File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
  end
  def state(context)
    JSON.parse(File.binread(state_path(context)))
  end
  def all_ready(context, record, index = 0)
    record['evidence']['plan']['matches'][index]['players'].each do |person|
      execution_for(context, record, person['username']) do |facade|
        select_match(facade, record, index)
        revision = facade.current[:current]&.fetch('ready_revision', 0) || 0
        assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: revision)[:state])
      end
    end
  end
  def historical_select(facade, record, index = 0, intent: 'ft2a-plan')
    match = record['evidence']['plan']['matches'][index]
    method = facade.respond_to?(:select_for_reconcile) ? :select_for_reconcile : :select
    facade.public_send(method, intent_id: intent, match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'])
  end
  def outcome
    value = yield
    value.is_a?(Hash) ? value : {value: value}
  rescue T::Publication::Invalid, T::ReadinessContract::Blocked, T::CoordinationContract::Blocked => error
    {state: :blocked, reason: error.code, error: error.class.name}
  end
  def observe_change(context, record)
    context.actor = 'Organizator'; context.now = 150
    result = context.service(journal: context.reopen_journal).publish(**params('chess', intent_id: 'ft2-runtime-inna-publikacja'))
    assert_equal('confirmed', result['status'])
    context.now = 201
    with_backend(context) do |backend|
      args = record['preview']
      shown = backend.preview(publication_ref: args['source']['candidate']['publication_ref'], membership: args['membership'],
        team_template: args['team_template'], base_seats: args['base_seats'], intent_id: 'ft2-runtime-alias')
      assert_equal(record, backend.accept(preview: shown), 'Legalny alias nie tworzy drugiej obsady')
    end
  end
end
