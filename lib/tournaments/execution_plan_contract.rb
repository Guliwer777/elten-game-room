# encoding: UTF-8
require_relative 'publication'
require_relative 'fixed_team_plan_contract'
require_relative 'game_result'

module GameRoomTournaments
  # Propozycja danych K02, nie producent autorytetu. Bez I/O i dopełniania ról.
  module ExecutionPlanContract
    Data = Publication::Data
    Invalid = Publication::Invalid
    ANCHOR = %w[backend_identity publication_ref publication_digest roster_generation schedule_id source_digest].freeze
    MATCH = %w[match_id leg execution_generation roles_status role_policy_ref players observers game_id options windows].freeze
    WINDOW = %w[id opens closes policy_ref].freeze
    module_function

    def copy(value)
      Data.copy(value, max_bytes: 262_144, max_nodes: 16_384, max_depth: 12)
    end

    def fields!(value, keys)
      CoordinationRequest.fields!(value, keys)
    end

    def list!(value)
      raise Invalid, :lista_planu unless value.is_a?(Array) && value.size.between?(1, 256)
      value
    end

    def schema!(data, anchor)
      fields!(data, %w[version status scope source seal plan plan_digest])
      fields!(anchor, ANCHOR)
      fields!(anchor['publication_ref'], %w[author publication_key])
      fields!(data['scope'], MatchBinding::SCOPE)
      source, plan = data.values_at('source', 'plan')
      source_fields = ANCHOR - ['source_digest'] + %w[roster game_id options windows matches]
      source_fields += ['knockout'] if source.key?('knockout')
      source_fields += ['result_policy'] if source.key?('result_policy')
      fields!(source, source_fields)
      raise Invalid, :invalid_game_result if source.key?('result_policy') && !GameResult::EXPORT_POLICIES.include?(source['result_policy'])
      fields!(source['publication_ref'], %w[author publication_key])
      list!(source['roster']).each { |person| fields!(person, %w[account username]) }
      list!(source['windows']).each { |window| fields!(window, WINDOW) }
      list!(source['matches']).each do |match|
        fields!(match, %w[match_id leg accounts window_ids])
        list!(match['accounts'])
        list!(match['window_ids'])
      end
      fields!(data['seal'], %w[id revision source_digest])
      fields!(plan, %w[id revision seal_id seal_revision source_digest approval matches])
      fields!(plan['approval'], %w[status policy_ref])
      list!(plan['matches']).each do |match|
        fields!(match, MATCH)
        list!(match['players']).each { |person| fields!(person, MatchBinding::PERSON) }
        observers = match['observers']
        raise Invalid, :invalid_people unless observers.is_a?(Array) && observers.size <= 256
        observers.each { |person| fields!(person, MatchBinding::PERSON) }
        list!(match['windows']).each { |window| fields!(window, WINDOW) }
      end
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(copy(value)))
    end

    def text!(value)
      Data.text!(value, bytes: 256)
    end

    def digest!(value)
      raise Invalid, :format_digestu unless Data.text?(value) && value.match?(/\A[0-9a-f]{64}\z/)
    end

    def policy!(value)
      text!(value)
      raise Invalid, :nieustalona_polityka if %w[unassigned NIEUSTALONE].include?(value)
    end

    def unique!(values, code = :powtorzone_id)
      raise Invalid, code unless values.uniq.size.eql?(values.size)
    end

    def source!(source)
      Data.text!(source['backend_identity'], bytes: 4096)
      %w[roster_generation schedule_id game_id].each { |key| text!(source[key]) }
      source['publication_ref'].each_value { |value| text!(value) }
      digest!(source['publication_digest'])
      if source['knockout'].is_a?(Hash) && source['knockout']['origin'] == 'direct_final'
        raise Invalid, :niezgodne_zrodlo unless source['knockout']['publication_digest'] == source['publication_digest']
      end
      roster = source['roster']
      roster.each do |person|
        raise Invalid, :invalid_account unless person['account'].eql?(Data.account(person['username']).downcase)
      end
      accounts = roster.map { |person| person['account'] }
      unique!(accounts, :duplicate_account)
      source['windows'].each do |window|
        CoordinationRequest.window!(window)
        policy!(window['policy_ref'])
      end
      windows = source['windows'].map { |window| window['id'] }
      unique!(windows)
      source['matches'].each do |match|
        text!(match['match_id'])
        raise Invalid, :invalid_leg unless Data.integer?(match['leg'], 1)
        unique!(match['accounts'], :duplicate_account)
        unique!(match['window_ids'])
        raise Invalid, :niezgodny_sklad unless match['accounts'].all? { |account| accounts.include?(account) }
        raise Invalid, :niezgodne_okna unless match['window_ids'].all? { |id| windows.include?(id) }
      end
      unique!(source['matches'].map { |match| match['match_id'] })
      if source.key?('knockout') && !source.key?('membership')
        schedule, fixtures = KnockoutSchedule.matches(metadata: source['knockout'], generation: source['roster_generation'])
        expected = fixtures.map { |match| match.slice('match_id', 'leg').merge('accounts' => match['players'],
          'window_ids' => source['windows'].map { |window| window['id'] }) }
        unless source['schedule_id'] == schedule && source['matches'].eql?(expected) &&
            source['roster'].map { |person| person['account'] }.sort == source['knockout']['seeds'].sort
          raise Invalid, :niezgodne_zrodlo
        end
      end
    end

    def identity!(data, anchor)
      source, seal, plan = data.values_at('source', 'seal', 'plan')
      Data.text!(anchor['backend_identity'], bytes: 4096)
      %w[roster_generation schedule_id].each { |key| text!(anchor[key]) }
      anchor['publication_ref'].each_value { |value| text!(value) }
      [anchor['publication_digest'], anchor['source_digest'], seal['source_digest'], plan['source_digest'], data['plan_digest']].each { |value| digest!(value) }
      expected = source.select { |key, _| ANCHOR.include?(key) }.merge('source_digest' => digest(source))
      raise Invalid, :niezgodne_zrodlo unless anchor.eql?(expected)
      %w[id revision].each { |key| text!(seal[key]); text!(plan[key]) }
      %w[seal_id seal_revision].each { |key| text!(plan[key]) }
      unless seal['source_digest'].eql?(anchor['source_digest']) && plan['source_digest'].eql?(anchor['source_digest']) &&
          plan['seal_id'].eql?(seal['id']) && plan['seal_revision'].eql?(seal['revision'])
        raise Invalid, :niezgodny_seal
      end
      raise Invalid, :niezgodny_digest_planu unless data['plan_digest'].eql?(digest(data.slice('scope', 'plan')))
      raise Invalid, :brak_akceptacji unless plan['approval']['status'].eql?('confirmed')
      policy!(plan['approval']['policy_ref'])
    end

    def payload(data, match, window)
      match.reject { |key, _| key == 'windows' }.merge('contract_version' => 1,
        'scope' => data['scope'], 'seal_id' => data['seal']['id'], 'seal_revision' => data['seal']['revision'],
        'plan_id' => data['plan']['id'], 'plan_revision' => data['plan']['revision'],
        'window' => window, 'visibility' => 'private')
    end

    def matches!(data, registry)
      source, plan = data.values_at('source', 'plan')
      matches = plan['matches']
      matches.each { |match| text!(match['match_id']) }
      unique!(matches.map { |match| match['match_id'] })
      unless matches.map { |match| match['match_id'] }.sort.eql?(source['matches'].map { |match| match['match_id'] }.sort)
        raise Invalid, :niezgodny_mecz
      end
      matches.each do |match|
        # Każdy wpis przechodzi stary build PRZED wyborem jednego meczu/okna.
        policy!(match['role_policy_ref'])
        match['windows'].each do |window|
          policy!(window['policy_ref'])
          CoordinationRequest.build(payload(data, match, window), registry: registry)
        end
        origin = source['matches'].find { |item| item['match_id'].eql?(match['match_id']) }
        raise Invalid, :niezgodny_mecz unless match['leg'].eql?(origin['leg'])
        unless match['game_id'].eql?(source['game_id']) && match['options'].eql?(source['options'])
          raise Invalid, :niezgodna_gra
        end
        people = match['players'] + match['observers']
        unless match['players'].map { |person| person['account'] }.sort.eql?(origin['accounts'].sort) &&
            people.all? { |person| source['roster'].any? { |entry| entry.eql?(person.slice('account', 'username')) } }
          raise Invalid, :niezgodny_sklad
        end
        windows = origin['window_ids'].map { |id| source['windows'].find { |window| window['id'].eql?(id) } }
        raise Invalid, :niezgodne_okna unless match['windows'].eql?(windows)
      end
    end

    def validate(evidence, expected_source, registry:)
      data, anchor = copy(evidence), copy(expected_source)
      if data.is_a?(Hash) && data['version'].eql?(2)
        return FixedTeamPlanContract.validate(data, anchor, registry: registry)
      end
      schema!(data, anchor)
      raise Invalid, :wersja_planu unless data['version'].eql?(1)
      raise Invalid, :plan_niepotwierdzony unless data['status'].eql?('confirmed')
      source!(data['source'])
      identity!(data, anchor)
      matches!(data, registry)
      data
    end
  end
end
