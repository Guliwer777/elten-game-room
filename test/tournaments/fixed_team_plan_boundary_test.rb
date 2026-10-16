# encoding: UTF-8
require_relative '../support/tournament_ft2b1_entry'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
directory = Dir.mktmpdir('b', File.expand_path('../../tmp', __dir__))
fixture = F.fixture(directory, accept_plan: false)
program = fixture[:program]
account, now = F::OWNER, 201
workspace = T::LocalWorkspace.new(program: program, registry: F::REGISTRY, user: -> { account },
  actor: 'Organizator', alert: ->(*) {}, clock: -> { now })
session = T::LocalReadinessSession.new
session.choose_actor('Organizator')
entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime,
  owner_reader: -> { account }, actor: 'Organizator', account_events: session.actor_events)
lease = entry.capture
operation = ->(action, input) { workspace.fixed_team_plan(action: action, input: input, context: entry, lease: lease, session: session) }
input = {'publication_ref' => fixture[:reference], 'pairs' => [%w[Anna Ala], %w[Bartek Beata], %w[Celina Cezary]],
  'team_template' => [0, 1, 0, 1], 'intent_id' => 'producer-boundary'}
begin
  now = 150
  assert_equal(:registration_open, operation.call(:preview, input)[:reason])
  now = 201
  bad = input.merge('pairs' => [%w[Anna Ala], %w[Bartek Ala], %w[Celina Cezary]])
  assert_equal(:invalid_membership, operation.call(:preview, bad)[:reason])
  preview = operation.call(:preview, input).fetch(:value)
  assert_equal(%w[anna bartek ala beata], preview['assignments'].first['players'].map { |person| person['account'] })
  tampered = T::Publication::Data.copy(preview, max_bytes: 1_048_576, max_depth: 16, max_nodes: 65_536)
  tampered['assignments'].first['players'].first['seat'] = 3
  assert_equal(:invalid_preview, operation.call(:accept, tampered)[:reason])
  # Zmiana źródła blokuje akceptację starego podglądu.
  now = 150
  assert_equal(:registration_open, operation.call(:accept, preview)[:reason])
  now = 201
  # Symulowana utrata odpowiedzi PO rzeczywistym atomowym zapisie.
  fault = Module.new do
    def write(document)
      result = super
      if $producer_lost_response
        $producer_lost_response = false
        raise IOError, 'lost response after replace'
      end
      result
    end
  end
  T::LocalExecutionPlanStorage.prepend(fault)
  $producer_lost_response = true
  uncertain = operation.call(:accept, preview)
  assert_equal(:uncertain, uncertain[:state])
  assert_equal('producer-boundary', uncertain[:intent_id])
  readback = operation.call(:readback, {'intent_id' => uncertain[:intent_id]})
  assert_equal(:confirmed, readback[:state])
  assert_equal(preview, readback[:value]['preview'])
  # Zamiana konta nie pozwala zapisać nawet gdy wróci ono do starej nazwy.
  account = 'InneKonto'
  assert_equal(nil, operation.call(:preview, input))
  account = F::OWNER
  assert_equal(nil, operation.call(:preview, input))
  puts 'PASS producer boundaries: registration, duplicate roster, tamper, lost response/readback, account epoch'
ensure
  entry.close
  session.close
  program.finalize
  program.class.app_runtime.close
end
