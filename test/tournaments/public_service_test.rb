# encoding: UTF-8
require_relative '../support/tournament_public_service'
source = File.expand_path('../../lib/tournaments/public_service.rb', __dir__)
require source if File.file?(source)

module TournamentPublicServiceTest
  extend GameRoomTest::Assertions
  extend TournamentPublicServiceSupport
  T = GameRoomTournaments
  ANN = TournamentPublicServiceSupport::ANN
  REG = TournamentPublicServiceSupport::REG
  module_function

  def test_01_lista_dwa_swieze_odczyty_i_pelna_projekcja
    assert(defined?(T::PublicService), 'Brak warstwy PublicService')
    sandbox do |c|
      c.gateway.append(ANN, publication)
      c.gateway.append(REG, T::RegistrationProjection.join_values(tournament_id: 1, operation_key: 'inny-klient'))
      service = c.service
      first = service.list
      assert_equal(%w[announcements diagnostics members operations], first.keys.sort)
      assert_equal([ANN, REG], c.reads)
      assert_equal(1, first['members'].length)
      assert_equal('Jawny regulamin próby.', first['announcements'].first['rules'])
      assert_raises(FrozenError) { first['announcements'].first['alias_ids'].clear }
      assert_raises(FrozenError) { first['members'].first['account'].clear }
      c.gateway.append(ANN, publication.merge('publication_key' => 'nastepne'))
      assert_equal(2, service.list['announcements'].length)
      assert_equal(1, first['announcements'].length)
      c.before_read = ->(name) { raise T::TablesGateway::Unavailable if name == REG }
      assert_raises(T::TablesGateway::Unavailable) { service.list }
    end
  end

  def test_02_konto_i_backend_na_kazdej_granicy_odczytu
    sandbox do |c|
      service = c.service
      c.actor = 'Inne konto'
      error = assert_raises(T::PublicService::Error) { service.list }
      assert_equal(:account_changed, error.code)
      assert_equal([], c.reads)
      c.actor = 'Testowa Żaneta'
      bad = assert_raises(T::PublicService::Error) { c.service(backend: 'server:inne') }
      assert_equal(:backend_changed, bad.code)
      c.after_read = ->(_name, _rows) { c.actor = nil }
      assert_raises(T::PublicService::Error) { service.list }
      assert_equal([ANN], c.reads)
      c.actor = 'Testowa Żaneta'
      c.after_read = nil
      c.before_read = ->(_name) { raise NoMethodError, 'Błąd programu' }
      assert_raises(NoMethodError) { service.list }
    end
  end

  def test_03_publikacja_32_gier_trwala_i_niezmienna
    sandbox do |c|
      service = c.service
      assert(service.respond_to?(:publish), 'Brak publikowania przez dziennik')
      records = GameRoomGames::CATALOG.ids.map do |id|
        input = params(id)
        before = Marshal.dump(input)
        result = service.publish(**input)
        assert_equal('confirmed', result['status'])
        assert_equal('publication', result['kind'])
        assert_equal(before, Marshal.dump(input))
        assert(!JSON.generate(result['values']).include?('Nie publikuj rosteru'))
        assert_equal(id, result['values']['game'])
        assert_raises(FrozenError) { result['values']['title'].clear }
        result
      end
      assert_equal(GameRoomGames::CATALOG.ids.length, c.inserts.length)
      assert_equal(GameRoomGames::CATALOG.ids.length, service.list['announcements'].length)
      reopened = c.reopen_journal
      again = c.service(journal: reopened).publish(**params)
      first = records.find { |r| r['values']['game'] == 'chess' }
      assert_equal(first['id'], again['id'])
      assert_equal(first['values'], again['values'])
      assert_equal(GameRoomGames::CATALOG.ids.length, c.inserts.length)
      assert_raises(T::OperationJournal::Conflict) { service.publish(**params(rules: 'Inna treść')) }
      assert_equal(GameRoomGames::CATALOG.ids.length, c.inserts.length)
    end
  end

  def test_04_utrata_odpowiedzi_po_commit_restart_tylko_uzgadnia
    sandbox do |c|
      service = c.service
      assert(service.respond_to?(:reconcile), 'Brak jawnego uzgadniania')
      c.after_insert = ->(*) { raise T::LocalTestTables::Error, :store_io_error }
      assert_raises(T::TablesGateway::UnconfirmedWrite) { service.publish(**params) }
      attempted = c.journal.list.fetch(0)
      assert_equal('attempted', attempted['status'])
      assert_equal(1, c.inserts.length)
      c.after_insert = nil
      record = c.service(journal: c.reopen_journal).reconcile(operation_id: attempted['id'])
      assert_equal('confirmed', record['status'])
      assert_equal([1], record['evidence']['record_ids'])
      assert_equal('confirmed', c.service.publish(**params)['status'])
      assert_equal(1, c.inserts.length)
      missing = c.journal.prepare(kind: 'publication', intent_id: 'bez-wiersza', values: publication)
      c.journal.claim(missing['id'])
      assert_equal('attempted', service.reconcile(operation_id: missing['id'])['status'])
      assert_equal('attempted', service.publish(**params(intent_id: 'bez-wiersza'))['status'])
      assert_equal(1, c.inserts.length)
      assert_raises(T::PublicService::Error) { service.reconcile(operation_id: 1) }
      error = assert_raises(T::PublicService::Error) { service.reconcile(operation_id: SecureRandom.uuid) }
      assert_equal(:missing_operation, error.code)
    end
  end

  def test_05_konflikty_publikacji_aliasy_i_dowody_tylko_zwalidowane
    [:tresc, :wadliwy_alias, :cudzy_autor, :sam_wadliwy, :aliasy].each do |mode|
      sandbox do |c|
        values = publication
        record = c.journal.prepare(kind: 'publication', intent_id: 'publikacja-chess', values: values)
        if mode == :sam_wadliwy
          c.gateway.append(ANN, values.merge('settings_json' => '{'))
        else
          c.gateway.append(ANN, values)
          c.actor = 'Obcy' if mode == :cudzy_autor
          second = case mode
          when :tresc then values.merge('rules' => 'Zmieniono regulamin')
          when :wadliwy_alias then values.merge('settings_json' => '{')
          else values
          end
          c.gateway.append(ANN, second)
          c.actor = 'TESTOWA ŻANETA'
        end
        count = c.inserts.length
        result = c.service.reconcile(operation_id: record['id'])
        expected = [:tresc, :wadliwy_alias].include?(mode) ? 'conflict' : mode == :sam_wadliwy ? 'prepared' : 'confirmed'
        assert_equal(expected, result['status'], mode.to_s)
        assert_equal(count, c.inserts.length)
        next unless result['evidence']
        assert_equal(mode == :tresc || mode == :aliasy ? [1, 2] : [1], result['evidence']['record_ids'])
        assert(!JSON.generate(result['evidence']).include?('__'))
        assert_equal('testowa żaneta', result['evidence']['author'])
        again = c.service.publish(**params)
        assert_equal(expected, again['status'])
        assert_equal(count, c.inserts.length)
      end
    end
    sandbox do |c|
      record = c.journal.prepare(kind: 'publication', intent_id: 'obca-publikacja', values: publication)
      c.journal.claim(record['id'])
      c.actor = 'Obcy'
      c.gateway.append(ANN, publication)
      c.actor = 'Testowa Żaneta'
      assert_equal('attempted', c.service.reconcile(operation_id: record['id'])['status'])
      confirmed = c.service.publish(**params)
      c.gateway.append(ANN, confirmed['values'].merge('rules' => 'Konflikt po potwierdzeniu'))
      assert_equal('conflict', c.service.reconcile(operation_id: confirmed['id'])['status'])
    end
  end

  def test_06_budzet_bramki_i_walidacja_przed_claim
    sandbox do |c|
      value = draft
      value['windows'] = Array.new(366) do |index|
        date = (Date.new(2026, 1, 1) + index).strftime('%Y-%m-%d')
        {'date' => date, 'start' => '12:00', 'end_date' => date, 'end' => '21:00'}
      end
      input = params(draft: value, rules: '\\' * 16_384)
      snapshot = T::Publication.from_draft(**input.reject { |key, _| key == :intent_id },
        registry: GameRoomGames::CATALOG, publication_key: 'budzet').to_row
      assert(JSON.generate(snapshot).bytesize > T::TablesGateway::MAX_PAYLOAD_BYTES)
      error = assert_raises(T::PublicService::Error) { c.service.publish(**input) }
      assert_equal(:payload_too_large, error.code)
      assert_equal([], c.inserts)
      assert(c.journal.list.all? { |row| row['status'] == 'prepared' })
      [nil, '100', 100.0, -1].each do |number|
        assert_raises(T::Publication::Invalid) { c.service.publish(**params(registration_opens_at: number)) }
      end
      ["\xFF".b, 'Ż'.encode('Windows-1250')].each do |text|
        assert_raises(T::Publication::Invalid) { c.service.publish(**params(rules: text)) }
      end
      assert_equal([], c.inserts)
    end
  end

  def test_07_join_32_gier_dwa_konta_i_powrot_przez_alias
    sandbox do |c|
      service = c.service
      assert(service.respond_to?(:join), 'Brak samodzielnego zapisu')
      GameRoomGames::CATALOG.ids.each { |id| service.publish(**params(id)) }
      rows = service.list['announcements']
      c.actor = 'Testowy Bartek'
      second = c.service(journal: c.reopen_journal)
      rows.each do |row|
        joined = second.join(tournament_id: row['__id'])
        assert_equal('confirmed', joined['status'])
        assert_equal("join:#{row['__id']}", joined['intent_id'])
      end
      c.actor = 'TESTOWA ŻANETA'
      first = service.join(tournament_id: rows.first['__id'])
      assert_equal('confirmed', first['status'])
      alias_row = c.gateway.append(ANN, rows.first.reject { |key, _| key.start_with?('__') || key == 'alias_ids' })
      count = c.inserts.length
      c.now = 500
      restarted = TournamentPublicServiceSupport::Context.new(c.directory, c.actor)
      restarted.now = 500
      again = restarted.service.join(tournament_id: alias_row['__id'])
      assert_equal([], restarted.inserts)
      assert_equal(first['id'], again['id'])
      assert_equal(first['values'], again['values'])
      assert_equal(count, c.inserts.length)
      state = service.list
      assert_equal(GameRoomGames::CATALOG.ids.length + 1, state['members'].length)
      assert_equal([], state['diagnostics']['registrations'])
      [nil, '1', 1.0, -1, 0, 2**63].each do |id|
        assert_raises(T::PublicService::Error) { service.join(tournament_id: id) }
      end
      assert_equal(:unknown_tournament, assert_raises(T::PublicService::Error) { service.join(tournament_id: 9000) }.code)
      assert_equal(count, c.inserts.length)
    end
  end

  def test_08_preflight_okno_i_czas_rzeczywistego_insertu
    sandbox do |c|
      c.service.publish(**params)
      [99, 200, 201, nil, '150', 150.0, -1, 2**63].each do |now|
        c.now = now
        code = now == 99 ? :not_open : [200, 201].include?(now) ? :closed : :invalid_clock
        assert_equal(code, assert_raises(T::PublicService::Error) { c.service.join(tournament_id: 1) }.code)
        assert_equal(1, c.inserts.length)
        assert(c.journal.list.none? { |r| r['kind'] == 'join' && r['status'] == 'attempted' })
      end
      c.now, c.insert_time = 199, 200
      result = c.service.join(tournament_id: 1)
      assert_equal('outside_window', result['status'])
      assert_equal([], c.service.list['members'])
      c.now, c.insert_time = 150, nil
      assert_equal(result['id'], c.service.join(tournament_id: 1)['id'])
      assert_equal(2, c.inserts.length)
    end
    sandbox do |c|
      c.service.publish(**params)
      c.now = 100
      assert_equal('confirmed', c.service.join(tournament_id: 1)['status'])
    end
  end

  def test_09_zapis_innego_klienta_przejmuje_rzeczywisty_klucz_i_alias
    [:confirmed, :outside_window].each do |status|
      sandbox do |c|
        c.service.publish(**params)
        c.gateway.append(ANN, c.journal.list.first['values'])
        c.actor = 'Inny gracz'
        journal = c.reopen_journal
        c.now = status == :confirmed ? 150 : 200
        values = T::RegistrationProjection.join_values(tournament_id: 2, operation_key: 'klucz-z-innego-klienta')
        inserted = c.gateway.append(REG, values)
        count = c.inserts.length
        c.now = 500
        record = c.service(journal: journal).join(tournament_id: 1)
        assert_equal(status.to_s, record['status'])
        assert_equal(values, record['values'])
        assert_equal('join:1', record['intent_id'])
        assert_equal([inserted['__id']], record['evidence']['record_ids'])
        assert_equal('klucz-z-innego-klienta', record['evidence']['key'])
        assert_equal(1, record['evidence']['canonical_id'])
        assert_equal(count, c.inserts.length)
        assert_equal(record['id'], c.service(journal: c.reopen_journal).join(tournament_id: 2)['id'])
      end
    end
  end

  def test_10_join_konflikt_celu_klucza_i_zatrzask_terminalny
    [:inny_cel, :wadliwy_alias, :obcy_autor, :inny_klucz].each do |mode|
      sandbox do |c|
        c.service.publish(**params)
        c.service.publish(**params(intent_id: 'drugi', rules: 'Drugi regulamin'))
        values = T::RegistrationProjection.join_values(tournament_id: 1, operation_key: 'cel-join')
        prepared = c.journal.prepare(kind: 'join', intent_id: 'join:1', values: values)
        c.journal.claim(prepared['id'])
        if mode == :inny_cel
          c.gateway.append(REG, values.merge('tournament_id' => 2))
        elsif mode == :wadliwy_alias
          c.gateway.append(REG, values)
          c.gateway.append(REG, values.merge('kind' => 'inny'))
        else
          c.actor = 'Obcy' if mode == :obcy_autor
          c.gateway.append(REG, mode == :inny_klucz ? values.merge('operation_key' => 'CEL-JOIN') : values)
          c.actor = 'Testowa Żaneta'
        end
        count = c.inserts.length
        result = c.service.reconcile(operation_id: prepared['id'])
        expected = [:inny_cel, :wadliwy_alias].include?(mode) ? 'conflict' : 'attempted'
        assert_equal(expected, result['status'], mode.to_s)
        assert_equal([1], result['evidence']['record_ids']) if expected == 'conflict'
        assert_equal(expected, c.service.join(tournament_id: 1)['status'])
        assert_equal(count, c.inserts.length)
      end
    end
    sandbox do |c|
      c.service.publish(**params)
      record = c.service.join(tournament_id: 1)
      c.after_read = ->(name, rows) { rows.clear if name == REG }
      assert_equal('confirmed', c.service.reconcile(operation_id: record['id'])['status'])
      c.after_read = nil
      c.gateway.append(REG, record['values'].merge('kind' => 'obcy'))
      assert_equal('conflict', c.service.reconcile(operation_id: record['id'])['status'])
    end
  end

  def test_11_niejednoznaczne_czlonkostwo_bez_nowej_proby
    [:wadliwy, :konflikt].each do |mode|
      sandbox do |c|
        c.service.publish(**params)
        values = T::RegistrationProjection.join_values(tournament_id: 1, operation_key: 'dawny')
        c.gateway.append(REG, values) if mode == :konflikt
        c.gateway.append(REG, values.merge('kind' => 'uszkodzony'))
        count = c.inserts.length
        assert_raises(T::PublicService::Error) { c.service.join(tournament_id: 1) }
        assert_equal(count, c.inserts.length)
        assert(c.journal.list.none? { |r| r['kind'] == 'join' })
      end
    end
    sandbox do |c|
      c.service.publish(**params)
      local = c.journal.prepare(kind: 'join', intent_id: 'join:1', values:
        T::RegistrationProjection.join_values(tournament_id: 1, operation_key: 'lokalny'))
      c.gateway.append(REG, T::RegistrationProjection.join_values(tournament_id: 1, operation_key: 'inny-klient'))
      count = c.inserts.length
      assert_equal(local, c.service.join(tournament_id: 1))
      assert_equal(count, c.inserts.length)
    end
  end

  def test_12_kanoniczne_json_i_rozne_lokalne_intenty_aliasow
    sandbox do |c|
      canonical = publication
      altered = canonical.merge('settings_json' => JSON.pretty_generate(JSON.parse(canonical['settings_json']).to_a.reverse.to_h),
        'schedule_json' => JSON.pretty_generate(JSON.parse(canonical['schedule_json'])))
      record = c.journal.prepare(kind: 'publication', intent_id: 'kanoniczny', values: altered)
      c.gateway.append(ANN, canonical)
      assert_equal('confirmed', c.service.reconcile(operation_id: record['id'])['status'])
      c.gateway.append(ANN, canonical)
      c.journal.prepare(kind: 'join', intent_id: 'join:1', values:
        T::RegistrationProjection.join_values(tournament_id: 1, operation_key: 'a'))
      other = c.journal.prepare(kind: 'join', intent_id: 'join:2', values:
        T::RegistrationProjection.join_values(tournament_id: 2, operation_key: 'b'))
      c.journal.claim(other['id'])
      assert_equal(:ambiguous_intent, assert_raises(T::PublicService::Error) { c.service.join(tournament_id: 1) }.code)
      assert_equal(2, c.inserts.length)
    end
  end

  def test_13_bledy_odczytu_resolve_i_brak_providera_nie_powtarzaja_insertu
    [:odczyt_po_zapisie, :resolve, :przed_commit].each do |mode|
      sandbox do |c|
        if mode == :odczyt_po_zapisie
          c.after_insert = ->(*) { c.before_read = ->(*) { raise T::TablesGateway::Unavailable } }
          expected = T::TablesGateway::Unavailable
        elsif mode == :resolve
          original = c.journal.method(:resolve)
          c.journal.define_singleton_method(:resolve) { |*args, **kwargs| raise T::OperationJournal::Error, :journal_io_error }
          expected = T::OperationJournal::Error
        else
          c.before_insert = ->(*) { raise T::LocalTestTables::Error, :store_io_error }
          expected = T::TablesGateway::UnconfirmedWrite
        end
        assert_raises(expected) { c.service.publish(**params) }
        assert_equal('attempted', c.journal.list.first['status'])
        c.after_insert = c.before_insert = c.before_read = nil
        c.journal.define_singleton_method(:resolve, original) if original
        record = c.service(journal: c.reopen_journal).publish(**params)
        assert_equal(mode == :przed_commit ? 'attempted' : 'confirmed', record['status'])
        assert_equal(1, c.inserts.length)
      end
    end
    sandbox do |c|
      c.available = false
      assert_raises(T::TablesGateway::Unavailable) { c.service.publish(**params) }
      assert_equal([], c.inserts)
      c.available = true
      File.binwrite(c.journal.path, '{')
      assert_raises(T::OperationJournal::Corrupt) { c.service.publish(**params) }
      assert_equal('{', File.binread(c.journal.path))
      assert_equal([], c.inserts)
    end
  end

  def test_14_kontekst_po_kazdym_io_dziennika_i_przed_wysylka
    [:find, :prepare, :claim].product([:account, :backend]).each do |method, kind|
      sandbox do |c|
        service = c.service
        original = c.journal.method(method)
        c.journal.define_singleton_method(method) do |*args, **kwargs|
          result = original.call(*args, **kwargs)
          if kind == :account
            c.actor = 'Inne konto'
          else
            c.journal.define_singleton_method(:backend_identity) { 'server:zmieniony' }
          end
          result
        end
        assert_raises(T::PublicService::Error) { service.publish(**params) }
        assert_equal([], c.inserts)
      end
    end
    sandbox do |c|
      c.service.publish(**params)
      original = c.journal.method(:list)
      c.journal.define_singleton_method(:list) { result = original.call; c.actor = nil; result }
      assert_raises(T::PublicService::Error) { c.service.join(tournament_id: 1) }
      assert_equal(1, c.inserts.length)
    end
    sandbox do |c|
      c.service.publish(**params)
      c.after_insert = ->(*) { c.actor = 'Obcy' }
      service = c.service
      assert_raises(T::TablesGateway::UnconfirmedWrite) { service.join(tournament_id: 1) }
      c.actor = 'Testowa Żaneta'
      assert_equal('attempted', c.journal.list.last['status'])
      c.after_insert = nil
      assert_equal('confirmed', service.join(tournament_id: 1)['status'])
      assert_equal(2, c.inserts.length)
    end
  end

  def test_15_zakresy_kont_backendow_i_brak_migracji
    sandbox do |c|
      record = c.service.publish(**params)
      local_bytes = File.binread(c.journal.path)
      c.actor = 'Drugie konto'
      other = c.service(journal: c.reopen_journal)
      assert_equal(:missing_operation, assert_raises(T::PublicService::Error) { other.reconcile(operation_id: record['id']) }.code)
      c.actor = 'Testowa Żaneta'
      remote = c.reopen_journal(backend: 'server:opaque-identity')
      assert_equal([], remote.list)
      isolated = c.service(journal: remote, backend: 'server:opaque-identity')
      assert_equal(:missing_operation, assert_raises(T::PublicService::Error) { isolated.reconcile(operation_id: record['id']) }.code)
      assert_equal(local_bytes, File.binread(c.journal.path))
      assert_equal(1, c.inserts.length)
      assert_raises(T::PublicService::Error) { c.service(backend: 1) }
      c.actor = 'Ż'.encode('Windows-1250')
      assert_raises(T::PublicService::Error) { c.service }
    end
  end

  def test_16_claim_dwie_instancje_i_stara_rewizja
    sandbox do |c|
      second = c.reopen_journal
      ready, release = Queue.new, Queue.new
      [c.journal, second].each do |journal|
        claim = journal.method(:claim)
        journal.define_singleton_method(:claim) { |id| ready << true; release.pop; claim.call(id) }
      end
      workers = [c.journal, second].map do |journal|
        Thread.new do
          begin
            c.service(journal: journal).publish(**params)
          rescue T::OperationJournal::Conflict => error
            error
          end
        end
      end
      2.times { ready.pop }
      2.times { release << true }
      results = workers.map(&:value)
      assert(results.all? { |r| r.is_a?(Hash) || r.code == :revision_conflict })
      assert_equal(1, c.inserts.length)
      assert_equal('confirmed', c.service(journal: c.reopen_journal).reconcile(operation_id: c.journal.list.first['id'])['status'])
    end
    sandbox do |c|
      record = c.service.publish(**params)
      other = c.reopen_journal
      original = c.journal.method(:resolve)
      c.journal.define_singleton_method(:resolve) do |id, **args|
        other.resolve(id, status: 'conflict', evidence: {'status' => 'conflict'}, expected_revision: args[:expected_revision])
        original.call(id, **args)
      end
      error = assert_raises(T::OperationJournal::Conflict) { c.service.reconcile(operation_id: record['id']) }
      assert_equal(:revision_conflict, error.code)
      assert_equal('conflict', other.fetch(record['id'])['status'])
      assert_equal(1, c.inserts.length)
    end
  end

  def test_17_blad_programu_nie_jest_utrata_kontekstu
    sandbox do |c|
      c.before_insert = ->(*) { c.actor = nil; raise NoMethodError, 'Błąd programu po zmianie konta' }
      service = c.service
      assert_raises(NoMethodError) { service.publish(**params) }
      c.actor = 'Testowa Żaneta'
      assert_equal('attempted', c.journal.list.first['status'])
      assert_equal(1, c.inserts.length)
    end
  end

  def test_18_duplikaty_aliasy_i_konflikt_id_izolowany_do_operacji
    sandbox do |c|
      published = c.service.publish(**params)
      c.gateway.append(ANN, published['values'])
      values = T::RegistrationProjection.join_values(tournament_id: 2, operation_key: 'join-alias')
      record = c.journal.prepare(kind: 'join', intent_id: 'join:2', values: values)
      c.gateway.append(REG, values)
      c.gateway.append(REG, values.merge('tournament_id' => 1))
      result = c.service.join(tournament_id: 1)
      assert_equal(record['id'], result['id'])
      assert_equal([1, 2], result['evidence']['record_ids'])
      assert_equal(1, c.service.list['members'].length)
      count = c.inserts.length
      # Wadliwa odpowiedź po prawdziwym odczycie izoluje test modelowej kolizji:
      # realny sandbox i sama bramka odrzucają kolizje ID wcześniej.
      c.after_read = lambda do |name, rows|
        rows << rows.first.merge('operation_key' => 'inny-klucz') if name == REG
      end
      conflict = c.service.reconcile(operation_id: record['id'])
      assert_equal('conflict', conflict['status'])
      assert_equal(count, c.inserts.length)
      diagnostics = c.service.list['diagnostics']['registrations']
      assert(diagnostics.any? { |item| item['code'] == 'id_conflict' })
      assert(diagnostics.any? { |item| item['code'] == 'key_conflict' && item['key'] == 'join-alias' })
      c.after_read = nil
      assert_equal('conflict', c.service.reconcile(operation_id: record['id'])['status'])
    end
  end

  def test_19_join_utrata_odpowiedzi_po_commit_i_puste_attempted
    sandbox do |c|
      c.service.publish(**params)
      c.after_insert = ->(*) { raise T::LocalTestTables::Error, :store_io_error }
      assert_raises(T::TablesGateway::UnconfirmedWrite) { c.service.join(tournament_id: 1) }
      attempted = c.journal.list.last
      assert_equal('attempted', attempted['status'])
      c.after_insert = nil
      c.now = 500
      result = c.service(journal: c.reopen_journal).join(tournament_id: 1)
      assert_equal(attempted['id'], result['id'])
      assert_equal('confirmed', result['status'])
      assert_equal(2, c.inserts.length)
      c.actor = 'Drugi aktor'
      other = c.reopen_journal
      no_row = other.prepare(kind: 'join', intent_id: 'join:1', values:
        T::RegistrationProjection.join_values(tournament_id: 1, operation_key: 'bez-wiersza'))
      other.claim(no_row['id'])
      assert_equal('attempted', c.service(journal: other).join(tournament_id: 1)['status'])
      assert_equal(2, c.inserts.length)
    end
  end

  def test_20_payload_przygotowanego_zamiaru_autorytatywny_po_wyscigu
    sandbox do |c|
      original = c.journal.method(:prepare)
      c.journal.define_singleton_method(:prepare) do |**args|
        original.call(**args.merge(values: args[:values].merge('publication_key' => 'pierwszy-klucz')))
        original.call(**args)
      end
      result = c.service.publish(**params)
      assert_equal('confirmed', result['status'])
      assert_equal('pierwszy-klucz', result['values']['publication_key'])
      assert_equal('pierwszy-klucz', c.inserts.first[1]['publication_key'])
      assert_equal(1, c.inserts.length)
    end
    sandbox do |c|
      c.after_insert = lambda do |name, values, _row|
        c.after_insert = nil
        c.provider.insert_row(name, values.merge('rules' => 'Równoległy konflikt'))
      end
      assert_equal('conflict', c.service.publish(**params)['status'])
    end
  end

  def test_21_niepewny_claim_po_commit_bez_prawa_do_wysylki
    sandbox do |c|
      original = c.journal.method(:claim)
      c.journal.define_singleton_method(:claim) { |id| original.call(id); raise T::OperationJournal::Error, :journal_io_error }
      assert_raises(T::OperationJournal::Error) { c.service.publish(**params) }
      assert_equal('attempted', c.reopen_journal.list.first['status'])
      assert_equal('attempted', c.service(journal: c.reopen_journal).publish(**params)['status'])
      assert_equal([], c.inserts)
    end
  end

  def test_22_join_uzgadnia_autorytatywny_prepare_przed_claim
    sandbox do |c|
      c.service.publish(**params)
      original = c.journal.method(:prepare)
      c.journal.define_singleton_method(:prepare) do |**args|
        values = args[:values].merge('operation_key' => 'wczesniejszy-klucz')
        original.call(**args.merge(values: values))
        c.gateway.append(REG, values)
        original.call(**args)
      end
      result = c.service.join(tournament_id: 1)
      assert_equal('confirmed', result['status'])
      assert_equal('wczesniejszy-klucz', result['values']['operation_key'])
      assert_equal(2, c.inserts.length, 'Znaleziony po prepare join nie wymaga drugiego insertu')
      assert_equal(2, result['revision'], 'Potwierdzenie prepared bez claim')
    end
  end

  def test_23_guard_w_rescue_wywolujacego_nadal_odrzuca_zmiane_konta
    sandbox do |c|
      service = c.service
      c.after_read = ->(name, _rows) { c.actor = 'Inny' if name == REG }
      begin
        raise T::TablesGateway::Unavailable, 'Wcześniejsza obsłużona awaria'
      rescue T::TablesGateway::Unavailable
        assert_raises(T::PublicService::Error) { service.list }
      end
    end
  end

  def test_24_io_w_wybranym_workerze_i_brak_naruszenia_wejsc
    sandbox do |c|
      caller_thread = Thread.current
      inputs = params
      original = Marshal.dump(inputs)
      worker = Thread.new do
        current = Thread.current
        check = ->(*) { assert_equal(current, Thread.current); assert(Thread.current != caller_thread) }
        c.before_read = c.after_read = c.before_insert = c.after_insert = check
        service = c.service(user: -> { check.call; c.actor }, clock: -> { check.call; c.now })
        record = service.publish(**inputs)
        inputs[:draft]['name'].clear
        inputs[:rules].clear
        assert_equal('Jawny regulamin próby.', c.journal.fetch(record['id'])['values']['rules'])
        service.join(tournament_id: 1)
        service.reconcile(operation_id: record['id'])
        service.list
      end
      result = worker.value
      assert_equal(1, result['members'].length)
      assert_equal('Próba chess', result['announcements'].first['title'])
      assert(original != Marshal.dump(inputs))
      assert(result.frozen?)
    end
  end

  def run
    selected = ENV['TOURNAMENT_SERVICE_TEST']
    methods(false).grep(/^test_/).sort.each do |name|
      next if selected && !name.to_s.include?(selected)
      public_send(name)
      puts "PASS #{name}"
    end
  end
end

TournamentPublicServiceTest.run
