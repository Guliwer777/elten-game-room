# encoding: UTF-8
require_relative 'tournament_fixed_teams'

# Legalne publikacje i pomiary całego JSON; bez zmiany limitów produkcji.
module FixedTeamBudgetSupport
  include TournamentFixedTeamsSupport
  LIMIT = 1_048_576

  def miary(value, depth = 0)
    children = case value
    when Hash then value.flat_map { |key, child| [key, child] }
    when Array then value
    else []
    end
    nested = children.map { |child| miary(child, depth + 1) }
    {'bytes' => JSON.generate(value).bytesize, 'nodes' => 1 + nested.sum { |row| row['nodes'] },
      'depth' => ([depth] + nested.map { |row| row['depth'] }).max}
  end

  def zapisane_pliki(directory)
    Dir.glob(File.join(directory, '**', '*')).select { |path| File.file?(path) && !path.end_with?('.lock') }.sort.to_h do |path|
      [path, {'sha256' => Digest::SHA256.file(path).hexdigest, 'bytes' => File.size(path), 'mtime' => File.mtime(path).to_r.to_s}]
    end
  end

  def bez_zapisu
    calls = []
    trace = TracePoint.new(:call) do |event|
      if event.defined_class == T::LocalExecutionPlanStorage && [:write, :resource].include?(event.method_id)
        path = event.method_id == :resource ? event.binding.local_variable_get(:path) : nil
        calls << {'method' => event.method_id.to_s, 'path' => path} if event.method_id == :write || path.include?('.tmp-')
      end
    end
    trace.enable(target_thread: nil)
    failure = nil
    begin
      yield
    rescue T::Publication::Invalid => error
      failure = error
    ensure
      trace.disable
    end
    [failure, calls]
  end

  def opis_bledu(error)
    error && {'class' => error.class.name, 'code' => error.code.to_s, 'message' => error.message, 'backtrace' => error.backtrace}
  end

  def druga_publikacja(context, service)
    context.actor, context.now = 'Organizator', 150
    settings = draft('spades').merge('players_per_match' => 4, 'rematch' => true)
    settings['game_options'] = REGISTRY.build('spades').normalize_options('team_size' => 2)
    settings['windows'] << {'date' => '2026-10-16', 'start' => '12:00', 'end_date' => '2026-10-16', 'end' => '21:00'}
    published = service.publish(**params('spades', draft: settings, intent_id: 'druga-publikacja', timezone: 'local_test:system'))
    assert_equal('confirmed', published['status'])
    row = service.list['announcements'].find { |item| item['publication_key'] == published['values']['publication_key'] }
    NAMES.each do |name|
      context.actor = name
      result = context.service(journal: context.reopen_journal).join(tournament_id: row['__id'])
      assert_equal('confirmed', result['status'])
    end
    context.actor, context.now = 'Organizator', 201
    {'author' => 'Organizator', 'publication_key' => row['publication_key']}
  end

  def podglad(context, service, backend, reference, intent)
    source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
    input = {publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source), intent_id: intent}
    [backend.preview(**input), input]
  end

  def regulamin(encoded_bytes)
    token = "ż\"\\\n\t"
    cost = JSON.generate(token).bytesize - 2
    count = [encoded_bytes / cost, T::Publication::MAX_RULES_BYTES / token.bytesize].min
    value = token * count
    padding = [encoded_bytes - (JSON.generate(value).bytesize - 2), T::Publication::MAX_RULES_BYTES - value.bytesize].min
    value + 'r' * padding
  end

  def powieksz(context, backend, input, shown, target)
    original = shown['source']['announcements'].first.reject { |key, _| key.start_with?('__') }
    additions, overhead = [], nil
    80.times do |index|
      previous = JSON.generate(shown).bytesize
      remaining = target - previous
      break if overhead && remaining <= overhead + 2
      desired = overhead ? (remaining - overhead) / 2 : T::Publication::MAX_RULES_BYTES
      rules = regulamin(desired)
      values = original.merge('publication_key' => format('budzet-%03d', index), 'rules' => rules)
      context.provider.insert_row(TournamentPublicServiceSupport::ANN, values)
      shown = backend.preview(**input)
      size = JSON.generate(shown).bytesize
      overhead = size - previous - 2 * (JSON.generate(rules).bytesize - 2)
      additions << {'rules_bytes' => rules.bytesize, 'rules_json_bytes' => JSON.generate(rules).bytesize,
        'shown_bytes' => size, 'overhead' => overhead}
    end
    assert_equal({'announcements' => [], 'registrations' => []}, shown['source']['projection']['diagnostics'], 'Brak ukrytych błędów projekcji')
    assert(JSON.generate(shown).bytesize.between?(target - 4, target), 'Legalny podgląd dochodzi do zadanej granicy')
    [shown, additions]
  end

  def zamrozony(value)
    assert(value.frozen?, 'Wszystkie składowe odzyskanego rekordu są zamrożone')
    case value
    when Hash then value.each { |key, child| zamrozony(key); zamrozony(child) }
    when Array then value.each { |child| zamrozony(child) }
    end
  end

  def dokladne_payloady(record)
    result = []
    record['evidence']['plan']['matches'].each do |match|
      match['windows'].each do |window|
        args = {evidence: record['evidence'], expected_source: record['expected_source'], registry: REGISTRY,
          match_id: match['match_id'], leg: match['leg'], window_id: window['id']}
        request = T::CoordinationRequest.from_execution_plan(**args)
        native = T::FixedTeamNativePayload.from_execution_plan(**args)
        assert_equal(record['request_digests'][match['match_id']][window['id']], request.digest)
        assert_equal(record['native_payload_digests'][match['match_id']][window['id']], native.digest)
        result << {'request' => request.to_h, 'request_digest' => request.digest, 'native' => native.to_h, 'native_digest' => native.digest}
      end
    end
    result
  end
end
