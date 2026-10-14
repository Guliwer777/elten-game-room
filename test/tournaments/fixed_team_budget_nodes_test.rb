# encoding: UTF-8
require_relative '../support/fixed_team_budget_support'
include FixedTeamBudgetSupport
results = []
[false, true].each do |excess|
  context, service, reference = fixture
  with_backend(context) do |backend, build, _, _, directory|
    small, input = podglad(context, service, backend, reference, 'wezly')
    baseline = miary(small)
    overhead = miary(backend.send(:compile, small))['nodes'] - baseline['nodes']
    original = small['source']['registrations'].first
    context.actor, context.insert_time = original['__insertion_user'], 150
    values = original.reject { |key, _| key.start_with?('__') }
    context.provider.insert_row(TournamentPublicServiceSupport::REG, values.merge('operation_key' => 'wezly-0000'))
    context.actor = 'Organizator'
    single = backend.preview(**input)
    step = miary(single)['nodes'] - baseline['nodes']
    target = 65_536 - overhead + (excess ? step : -step)
    count = (target - baseline['nodes']) / step
    context.actor = original['__insertion_user']
    (1...count).each do |index|
      context.provider.insert_row(TournamentPublicServiceSupport::REG, values.merge('operation_key' => format('wezly-%04d', index)))
    end
    context.actor, context.insert_time = 'Organizator', nil
    shown = backend.preview(**input)
    measures = miary(shown)
    assert_equal(baseline['nodes'] + count * step, measures['nodes'])
    assert_equal({'announcements' => [], 'registrations' => []}, shown['source']['projection']['diagnostics'])
    assert(measures['bytes'] < LIMIT - 30_000 && measures['depth'] < 16, 'Granica węzłów, nie bajtów lub głębokości')
    before = zapisane_pliki(directory)
    if excess
      error, calls = bez_zapisu { backend.accept(preview: shown) }
      result = {'excess' => true, 'shown' => shown, 'measures' => measures, 'nodes_full' => measures['nodes'] + overhead,
        'overhead_nodes' => overhead, 'count' => count, 'step' => step, 'error' => opis_bledu(error), 'calls' => calls,
        'before' => before, 'after' => zapisane_pliki(directory)}
      oracle_file('wezly-odmowa.json', result)
      assert_equal(:json_budget, error&.code)
      assert_equal([], calls)
      assert_equal(before, zapisane_pliki(directory))
      assert_equal(nil, build.call.readback(intent_id: 'wezly'))
    else
      record = backend.accept(preview: shown)
      full = miary(record)
      assert(full['nodes'].between?(65_536 - 2 * step, 65_536), 'Cały legalny rekord przy granicy węzłów')
      before_read = zapisane_pliki(directory)
      assert_equal(record, build.call.readback(intent_id: 'wezly'))
      assert_equal(record, build.call.accept(preview: shown))
      assert_equal(before_read, zapisane_pliki(directory))
      result = {'excess' => false, 'record' => record, 'measures' => full, 'shown_measures' => measures,
        'overhead_nodes' => overhead, 'count' => count, 'step' => step}
      oracle_file('wezly-dodatnie.json', result)
    end
    results << result
  end
end
oracle_file('oracle.json', results)
puts 'FT1-R1: rzeczywiste legalne rejestracje przy granicy węzłów — OK'
