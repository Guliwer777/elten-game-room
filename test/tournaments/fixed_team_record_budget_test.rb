# encoding: UTF-8
require_relative '../support/fixed_team_budget_support'
include FixedTeamBudgetSupport
results = []
[false, true].each do |with_healthy|
  context, service, reference = fixture
  with_backend(context) do |backend, build, _, _, directory|
    healthy = nil
    if with_healthy
      initial, = podglad(context, service, backend, reference, 'zdrowy')
      healthy = backend.accept(preview: initial)
      reference = druga_publikacja(context, service)
    end
    shown, input = podglad(context, service, backend, reference, 'odmowa-budzetu')
    shown, additions = powieksz(context, backend, input, shown, 1_047_000)
    before = zapisane_pliki(directory)
    error, calls = bez_zapisu { backend.accept(preview: shown) }
    after = zapisane_pliki(directory)
    path = File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')
    document = File.exist?(path) ? JSON.parse(File.binread(path)) : nil
    results << {'healthy' => healthy, 'shown' => shown, 'shown_measures' => miary(shown), 'additions' => additions,
      'error' => opis_bledu(error), 'calls' => calls, 'before' => before, 'after' => after, 'document' => document}
    oracle_file("odmowa-#{with_healthy}.json", results.last)
    assert(error.instance_of?(T::Publication::Invalid), 'Zwykła odmowa, nie niepewność po skutku')
    assert_equal(:json_budget, error.code, 'Dokładny kod przekroczenia budżetu całego rekordu')
    assert_equal([], calls, 'FT1-R1: json_budget PRZED storage.write i utworzeniem pliku tymczasowego')
    assert_equal(before, after, 'Odmowa nie tworzy ani nie podmienia dokumentu')
    assert_equal(with_healthy ? [healthy] : [], document ? document['records'] : [])
    assert_equal(with_healthy ? ['zdrowy'] : [], document ? document['intents'].map { |link| link['intent_id'] } : [])
    assert_equal(nil, build.call.readback(intent_id: 'odmowa-budzetu'))
    assert_equal(healthy, build.call.readback(intent_id: 'zdrowy')) if healthy
    assert_equal(after, zapisane_pliki(directory), 'Odzyskanie zdrowego rekordu nie zapisuje')
  end
end
oracle_file('oracle.json', results)
puts 'FT1-R1: ścisła odmowa pustego i istniejącego magazynu przed skutkiem — OK'
