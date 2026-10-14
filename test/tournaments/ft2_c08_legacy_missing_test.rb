# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared/ft2_c08_legacy1594')
input = JSON.parse(File.binread(File.join(directory, 'legacy-input.json')))
context = TournamentPublicServiceSupport::Context.new(directory, input['actor'])
context.now = 201
path = File.join(directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
bound = File.binread(path)
ready = File.binread(File.join(directory, 'ready-only1594.json'))
rows = []
[ready, JSON.generate(JSON.parse(bound).tap { |d| d['executions'].values.first['record_intent'] = 'nieznany-intent' })].each do |bytes|
  File.binwrite(path, bytes)
  result, mutations = c08_observe do
    execution_for(context, input['record'], input['actor']) do |facade|
      select_match(facade, input['record'])
      break facade.current
    end
  end
  actual = {result: result, mutations: mutations, exact: bytes.b == File.binread(path)}
  expected = {result: {state: :blocked, reason: :legacy_record_reference_missing, current: nil, receipt: nil, operation_id: nil}, mutations: [], exact: true}
  rows << {expected: expected, actual: actual}
  File.binwrite(path, bound)
end
oracle_file('ft2_c08_legacy_missing.json', rows)
rows.each { |r| assert_equal(r[:expected], r[:actual]) }
puts 'GREEN C08: stary ready-only bez record_intent nie zyskuje fikcyjnego autorytetu, oryginalne bajty zachowane'
