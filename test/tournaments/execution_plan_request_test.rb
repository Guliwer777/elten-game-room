# encoding: UTF-8
require_relative '../support/tournament_execution_plan'
E = TournamentExecutionPlanFixture
F = TournamentCoordinationFixture
T = GameRoomTournaments
input = E.evidence
before = E.copy(input)
# Poprawne pełne dane najpierw przechodzą istniejący build.
expected = T::CoordinationRequest.build(E.expected(input), registry: TournamentMatchFixture.registry)
F.assert(expected.to_h.eql?(E.expected(input)), 'Fixture nie spełnia starego kontraktu')
request = E.request(input)
F.assert(request.is_a?(T::CoordinationRequest), 'Wynik nie jest istniejącym requestem')
F.assert(request.to_h.eql?(expected.to_h), 'Zmiana pełnego payloadu')
F.assert(E.frozen_tree?(request.to_h), 'Niepełny deep freeze')
F.assert(input.eql?(before), 'Fabryka zmieniła wejście')
input['plan']['matches'][0]['players'][0]['username'].replace('Zmieniona')
F.assert(request.to_h['players'][0]['username'].eql?('Alice'), 'Wejście współdzieli wynik')
F.assert(E.request.to_h.eql?(request.to_h), 'Brak determinizmu requestu')
puts 'PASS fabryka: pełny payload, odłączenie, freeze, stabilność'

# Schemat wszystkich zagnieżdżeń, nie tylko pola wybranego meczu.
paths = [[], ['scope'], ['source'], ['source','publication_ref'], ['source','roster',0],
  ['source','windows',0], ['source','matches',0], ['seal'], ['plan'], ['plan','approval'],
  ['plan','matches',0], ['plan','matches',0,'players',0], ['plan','matches',0,'observers',0], ['plan','matches',0,'windows',0]]
paths.each do |path|
  original = E.evidence
  node = path.reduce(original) { |value,key| value.fetch(key) }
  node.keys.each do |key|
    changed = E.copy(original)
    path.reduce(changed) { |value,part| value.fetch(part) }.delete(key)
    E.reject(:invalid_fields) { E.request(changed, expected_source: E.anchor(original)) }
  end
  changed = E.copy(original)
  path.reduce(changed) { |value,key| value.fetch(key) }['obce'] = true
  E.reject(:invalid_fields) { E.request(changed, expected_source: E.anchor(original)) }
end
anchor = E.anchor(E.evidence)
anchor.keys.each do |key|
  changed = E.copy(anchor); changed.delete(key)
  E.reject(:invalid_fields) { E.request(expected_source: changed) }
end
E.reject(:invalid_fields) { E.request(expected_source: anchor.merge('obce'=>true)) }
[0, 1.0, '1', nil, true].each do |value|
  changed=E.evidence; changed['version']=value
  E.reject(:wersja_planu) { E.request(changed) }
end
[nil, [], 'confirmed'].each { |value| E.reject(:invalid_fields) { E.request(value, expected_source: anchor) } }
['candidate', 'unassigned', nil, true].each do |value|
  changed=E.evidence; changed['status']=value
  E.reject(:plan_niepotwierdzony) { E.request(changed) }
end
[:symbol, Object.new, Float::NAN].each do |value|
  changed=E.evidence; changed['source']['roster_generation']=value
  E.reject(:invalid_json) { E.request(changed, expected_source: anchor) }
end
changed=E.evidence; changed['plan']['revision']="\xFF".force_encoding('UTF-8')
E.reject(:invalid_utf8) { E.request(changed) }
changed=E.evidence; changed['plan']['revision']='a'*262_145
E.reject(:json_budget) { E.request(changed) }
changed=E.evidence; changed['plan']['revision']=Array.new(16_385, 0)
E.reject(:json_budget) { E.request(changed) }
changed=E.evidence; changed['plan']['revision']=13.times.reduce(0) { |child,_| [child] }
E.reject(:json_budget) { E.request(changed) }
changed=E.evidence; changed['plan']['revision']=changed
E.reject(:json_budget) { E.request(changed) }
puts 'PASS schemat: pełne pola, wersja, typy, UTF-8, bajty/węzły/głębokość/cykl'

# Dwa osobno poprawne dokumenty nie muszą opisywać tego samego źródła.
old = E.evidence
changed = E.copy(old); changed['source']['roster_generation']='roster-2'
changed['seal']['source_digest']=E.digest(changed['source'])
changed['plan']['source_digest']=changed['seal']['source_digest']
changed['plan_digest']=E.digest(changed.slice('scope','plan'))
E.reject(:niezgodne_zrodlo) { E.request(changed, expected_source: E.anchor(old)) }
F.assert(E.request(changed).to_h.eql?(E.expected(changed)), 'Drugie źródło samo w sobie niepoprawne')

cases = [
  [:niezgodne_zrodlo, ['source','backend_identity'], 'local-test-k03:inne'],
  [:niezgodne_zrodlo, ['source','publication_ref','author'], 'Inny'],
  [:niezgodne_zrodlo, ['source','publication_ref','publication_key'], 'inna'],
  [:niezgodne_zrodlo, ['source','publication_digest'], 'b'*64],
  [:niezgodne_zrodlo, ['source','schedule_id'], 'inny'],
  [:niezgodny_seal, ['seal','source_digest'], 'b'*64],
  [:niezgodny_seal, ['seal','id'], 'inny'],
  [:niezgodny_seal, ['seal','revision'], 'inna'],
  [:niezgodny_seal, ['plan','source_digest'], 'b'*64],
  [:niezgodny_seal, ['plan','seal_id'], 'inny'],
  [:niezgodny_seal, ['plan','seal_revision'], 'inna'],
  [:niezgodny_digest_planu, ['plan','id'], 'inny'],
  [:niezgodny_digest_planu, ['plan','revision'], 'inna'],
  [:niezgodny_digest_planu, ['plan','matches',0,'execution_generation'], 'nowa'],
  [:niezgodny_digest_planu, ['plan_digest'], 'b'*64]
]
cases.each do |code,path,value|
  changed=E.evidence; last=path.last
  path[0...-1].reduce(changed) { |node,key| node.fetch(key) }[last]=value
  E.reject(code) { E.request(changed, expected_source: E.anchor(E.evidence)) }
end

# Zmiany wewnątrz planu mają aktualny digest, żeby dojść do konkretnej granicy.
plan_cases = [
  [:brak_akceptacji, ->(p) { p['approval']['status']='unassigned' }],
  [:nieustalona_polityka, ->(p) { p['approval']['policy_ref']='NIEUSTALONE' }],
  [:niezgodny_mecz, ->(p) { p['matches'][0]['match_id']='inne' }],
  [:niezgodny_mecz, ->(p) { p['matches'][0]['leg']=2 }],
  [:invalid_leg, ->(p) { p['matches'][0]['leg']=1.0 }],
  [:invalid_text, ->(p) { p['matches'][0]['execution_generation']=nil }],
  [:invalid_fields, ->(p) { p['matches'][0]['players'][0].delete('game_role') }],
  [:duplicate_account, ->(p) { p['matches'][0]['players'][1]=E.copy(p['matches'][0]['players'][0]) }],
  [:duplicate_seat, ->(p) { p['matches'][0]['players'][1]['seat']=1 }],
  [:unassigned_roles, ->(p) { p['matches'][0]['players'][0]['game_role']='unassigned' }],
  [:unassigned_roles, ->(p) { p['matches'][0]['players'][0]['team']='NIEUSTALONE' }],
  [:unassigned_roles, ->(p) { p['matches'][0]['roles_status']='unassigned' }],
  [:nieustalona_polityka, ->(p) { p['matches'][0]['role_policy_ref']='unassigned' }],
  [:invalid_options, ->(p) { p['matches'][0]['options']['draw_responses']='true' }],
  [:niezgodna_gra, ->(p) { p['matches'][0]['options']['draw_responses']=!p['matches'][0]['options']['draw_responses'] }],
  [:niezgodne_okna, ->(p) { p['matches'][0]['windows'][0]['opens']=101 }],
  [:invalid_window, ->(p) { p['matches'][0]['windows'][0]['opens']=100.0 }],
  [:powtorzone_id, ->(p) { p['matches'] << E.copy(p['matches'][0]) }],
  [:niezgodny_sklad, ->(p) { p['matches'][0]['observers'][0]['username']='CAROL' }]
]
plan_cases.each do |code,change|
  changed=E.evidence; change.call(changed['plan']); changed['plan_digest']=E.digest(changed.slice('scope','plan'))
  E.reject(code) { E.request(changed) }
end

# Poprawny drugi mecz pozwala badać walidację PRZED filtrowaniem.
two=E.evidence
two['source']['matches'] << E.copy(two['source']['matches'][0]).merge('match_id'=>'match-2','leg'=>2)
two['plan']['matches'] << E.copy(two['plan']['matches'][0]).merge('match_id'=>'match-2','leg'=>2,'execution_generation'=>'execution-2')
two['seal']['source_digest']=E.digest(two['source']); two['plan']['source_digest']=two['seal']['source_digest']
two['plan_digest']=E.digest(two.slice('scope','plan'))
F.assert(E.request(two).to_h['match_id']=='match-1', 'Poprawny pełny plan wielomeczowy')
changed=E.copy(two); changed['plan']['matches'][1]['players'][0]['game_role']='unassigned'; changed['plan_digest']=E.digest(changed.slice('scope','plan'))
E.reject(:unassigned_roles) { E.request(changed) }
changed=E.copy(two); changed['plan']['matches'].pop; changed['plan_digest']=E.digest(changed.slice('scope','plan'))
E.reject(:niezgodny_mecz) { E.request(changed) }
changed=E.evidence; changed['source']['roster'] << E.copy(changed['source']['roster'][0])
changed['seal']['source_digest']=E.digest(changed['source']); changed['plan']['source_digest']=changed['seal']['source_digest']; changed['plan_digest']=E.digest(changed.slice('scope','plan'))
E.reject(:duplicate_account) { E.request(changed) }
[1.0, '1', nil].each { |leg| E.reject(:invalid_leg) { E.request(leg: leg) } }
E.reject(:brak_wyboru) { E.request(match_id:'inne') }
E.reject(:brak_wyboru) { E.request(leg:2) }
E.reject(:brak_wyboru) { E.request(window_id:'inne') }
puts 'PASS relacje: źródło/seal/digest/plany/składy/role/options/okna, niewybrane mecze'

# Typ ID musi zostać odrzucony walidacją, nie wyjątkiem sortowania mieszanego zbioru.
changed=E.copy(two); changed['plan']['matches'][1]['match_id']=nil; changed['plan_digest']=E.digest(changed.slice('scope','plan'))
E.reject(:invalid_text) { E.request(changed) }

# Wszystkie niewybrane wpisy źródła również pozostają częścią kontraktu.
source_cases = [
  [:niezgodny_sklad, ->(s) { s['roster'].reject! { |p| p['account']=='bob' } }],
  [:niezgodny_sklad, ->(s) { s['matches'][0]['accounts'].pop }],
  [:duplicate_account, ->(s) { s['matches'][0]['accounts'] << 'alice' }],
  [:powtorzone_id, ->(s) { s['matches'] << E.copy(s['matches'][0]) }],
  [:powtorzone_id, ->(s) { s['windows'] << E.copy(s['windows'][0]) }],
  [:powtorzone_id, ->(s) { s['matches'][0]['window_ids'] << 'window-1' }],
  [:niezgodne_okna, ->(s) { s['matches'][0]['window_ids']=['obce'] }],
  [:invalid_window, ->(s) { s['windows'] << s['windows'][0].merge('id'=>'inne','closes'=>100) }],
  [:format_digestu, ->(s) { s['publication_digest']='A'*64 }],
  [:invalid_account, ->(s) { s['roster'] << {'account'=>'x','username'=>'Bob'} }]
]
source_cases.each do |code,change|
  changed=E.evidence; change.call(changed['source'])
  changed['seal']['source_digest']=E.digest(changed['source']); changed['plan']['source_digest']=changed['seal']['source_digest']
  changed['plan_digest']=E.digest(changed.slice('scope','plan'))
  E.reject(code) { E.request(changed) }
end

# Fabryka już załadowana; obserwator obejmuje wyłącznie mapowanie danych.
input=E.evidence; anchor=E.anchor(input); effects=[]
trace=TracePoint.new(:call,:c_call) do |event|
  owner=event.defined_class.to_s
  forbidden = (owner.match?(/File|IO|Dir|Socket|Process/) && %i[open read write binread binwrite spawn exec system].include?(event.method_id)) ||
    %i[rand srand uuid random_number sleep fork].include?(event.method_id) ||
    (owner.include?('Thread') && event.method_id==:new)
  effects << [owner,event.method_id] if forbidden
end
trace.enable(target_thread:nil)
begin
  pure=E.request(input,expected_source:anchor)
ensure
  trace.disable
end
F.assert(effects.empty?, "Niedozwolone skutki fabryki: #{effects.inspect}")
F.assert(!pure.to_h.key?('operation_id'), 'Fabryka nadała UUID operacji')
F.assert(input.eql?(E.evidence) && anchor.eql?(E.anchor(input)), 'Zmienione wejścia fabryki')
puts 'PASS typy ID, pełne źródło i brak I/O/RNG/UUID/workera w fabryce'
changed=E.evidence; changed['scope']['namespace']='inny-zakres'
E.reject(:niezgodny_digest_planu) { E.request(changed) }
