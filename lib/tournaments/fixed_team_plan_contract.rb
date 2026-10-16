# encoding: UTF-8
require_relative 'fixed_team_schedule_candidate'
require_relative 'game_result'

module GameRoomTournaments
  # Spójność danych v2, nie podpis historycznej pierwszej obsady.
  module FixedTeamPlanContract
    Data = Publication::Data
    Invalid = Publication::Invalid
    module_function

    def schema!(data, anchor)
      a = ExecutionPlanContract
      a.fields!(data, %w[version status scope source seal plan plan_digest])
      a.fields!(anchor, a::ANCHOR)
      a.fields!(anchor['publication_ref'], %w[author publication_key])
      a.fields!(data['scope'], MatchBinding::SCOPE)
      source, plan = data.values_at('source', 'plan')
      fields = a::ANCHOR - ['source_digest'] + %w[roster game_id options windows matches source_kind source_version membership team_template roster_digest pairing rematch]
        fields += ['result_policy'] if source.key?('result_policy')
        raise Invalid, :invalid_game_result if source.key?('result_policy') && !GameResult::RESULT_POLICIES.include?(source['result_policy'])
        fields += ['groups'] if source.key?('groups')
        fields += ['knockout'] if source.key?('knockout')
      a.fields!(source, fields)
      a.fields!(source['publication_ref'], %w[author publication_key])
      a.list!(source['roster']).each { |person| a.fields!(person, %w[account username]) }
      a.list!(source['windows']).each { |window| a.fields!(window, a::WINDOW) }
      a.list!(source['matches']).each do |match|
        a.fields!(match, %w[match_id leg accounts window_ids unit_ids])
        %w[accounts window_ids unit_ids].each { |key| a.list!(match[key]) }
      end
      a.fields!(data['seal'], %w[id revision source_digest])
      a.fields!(plan, %w[id revision seal_id seal_revision source_digest approval matches])
      a.fields!(plan['approval'], %w[status policy_ref])
      a.list!(plan['matches']).each do |match|
        a.fields!(match, a::MATCH)
        a.list!(match['players']).each { |person| a.fields!(person, MatchBinding::PERSON) }
        raise Invalid, :invalid_observer unless match['observers'].eql?([])
        a.list!(match['windows']).each { |window| a.fields!(window, a::WINDOW) }
      end
    end

    def source!(source)
      a = ExecutionPlanContract
      a.source!(source)
      unless source['source_kind'] == 'fixed-teams' && [1, 2].any? { |version| source['source_version'].eql?(version) } &&
          source['membership'].is_a?(Hash) && source['membership']['version'].eql?(source['source_version'])
        raise Invalid, :wersja_zrodla
      end
      roster = source['roster']
      raise Invalid, :niezgodny_sklad unless roster == roster.sort_by { |person| person['account'] }
      membership = FixedTeamSeats.membership(source['membership'], roster)
      raise Invalid, :invalid_membership unless membership.eql?(source['membership'])
      if source['source_version'].eql?(2) && (!GameResult::RESULT_POLICIES.include?(source['result_policy']) || source['result_policy'] == GameResult::RESULT_EXPORT_POLICY)
        raise Invalid, :invalid_game_result
      end
      template = FixedTeamSeats.template(source['team_template'], options: source['options'], unit_size: FixedTeamSeats.unit_size(membership))
      raise Invalid, :invalid_rematch unless source['rematch'].equal?(true) || source['rematch'].equal?(false)
      raise Invalid, :invalid_pairing unless %w[all_combinations balanced_cycle].include?(source['pairing'])
      FixedTeamScheduleCandidate.budget!(membership, roster, source['windows'], source['rematch']) unless source.key?('groups') || source.key?('knockout')
      generation = FixedTeamScheduleCandidate.digest(['tournament-fixed-team-roster-v1', source['backend_identity'],
        source['publication_ref'], source['publication_digest'], roster, membership])
      units = membership['units'].to_h { |unit| [unit['unit_id'], unit['accounts']] }
      groups = nil
      if source.key?('knockout')
        raise Invalid, :invalid_rematch unless source['rematch'] == (source['knockout']['rematch'] == true) && !source.key?('groups')
        schedule, fixtures = KnockoutSchedule.matches(metadata: source['knockout'], generation: generation, membership: membership)
        expected = fixtures.map { |match| match.slice('match_id', 'leg', 'unit_ids').merge('accounts' => match['players'],
          'window_ids' => source['windows'].map { |window| window['id'] }) }
        unless source['roster_digest'] == generation && source['roster_generation'] == generation &&
            source['schedule_id'] == schedule && source['matches'].eql?(expected)
          raise Invalid, :niezgodne_zrodlo
        end
        return
      elsif source.key?('groups')
        unless source['groups'].is_a?(Array) && source['groups'].size.between?(2, 128) &&
            source['groups'].first.is_a?(Hash) && roster.size <= 256 && source['windows'].size <= 256
          raise Invalid, :invalid_group_configuration
        end
        settings = {'group_count' => source['groups'].size, 'places_per_group' => source['groups'].first['places'],
          'pairing' => source['pairing'], 'rematch' => source['rematch']}
        matches, groups = GroupSchedule.build(roster: units.keys, settings: settings, players_per_match: 2)
      else
        matches = LeaguePlan.build(participants: units.keys, players_per_match: 2, pairing: source['pairing'], rematch: source['rematch'])
      end
      schedule = FixedTeamScheduleCandidate.digest(['tournament-fixed-team-schedule-v1', generation, source['pairing'], source['rematch'], template,
        matches.map { |match| match.values_at('players', 'leg') }])
      expected = matches.map do |match|
        ids = match['players']
        {'match_id' => FixedTeamScheduleCandidate.digest(['tournament-fixed-team-match-v1', schedule, ids, match['leg']]),
          'leg' => match['leg'], 'unit_ids' => ids, 'accounts' => ids.flat_map { |id| units.fetch(id) },
          'window_ids' => source['windows'].map { |window| window['id'] }}
      end
      unless source['roster_digest'] == generation && source['roster_generation'] == generation &&
          source['schedule_id'] == schedule && source['matches'].eql?(expected)
        raise Invalid, :niezgodne_zrodlo
      end
      if groups && !source['groups'].eql?(GroupSchedule.metadata(groups, expected))
        raise Invalid, :invalid_group_configuration
      end
    end

    def matches!(data, registry)
      a = ExecutionPlanContract
      source, plan = data.values_at('source', 'plan')
      matches = plan['matches']
      unless matches.map { |match| match['match_id'] } == source['matches'].map { |match| match['match_id'] }
        raise Invalid, :niezgodny_mecz
      end
      matches.each do |match|
        unless match['game_id'] == source['game_id'] && match['options'].eql?(source['options'].merge('team_seats' => source['team_template']))
          raise Invalid, :niezgodna_gra
        end
        raise Invalid, :niezgodna_polityka unless match['role_policy_ref'] == FixedTeamSeats.policy(source['membership'])
        raise Invalid, :niezgodne_okna unless match['windows'].eql?(source['windows'])
        match['windows'].each { |window| CoordinationRequest.build(a.payload(data, match, window), registry: registry) }
      end
      candidate = {'membership' => source['membership'], 'team_template' => source['team_template'], 'game_options' => source['options'],
        'matches' => source['matches'].map { |match| match.merge('players' => match['accounts']) }}
      base = matches.select { |match| match['leg'] == 1 }.to_h do |match|
        [match['match_id'], match['players'].sort_by { |person| person['seat'] }.map { |person| person['account'] }]
      end
      expected = FixedTeamSeats.assign(candidate, base, source['roster'])
      unless matches.map { |match| match.slice('match_id', 'leg', 'players', 'observers') }.eql?(expected)
        raise Invalid, :niezgodna_obsada
      end
    end

    def validate(evidence, expected_source, registry:)
      a = ExecutionPlanContract
      data, anchor = a.copy(evidence), a.copy(expected_source)
      schema!(data, anchor)
      raise Invalid, :wersja_planu unless data['version'].eql?(2)
      raise Invalid, :plan_niepotwierdzony unless data['status'] == 'confirmed'
      source!(data['source'])
      a.identity!(data, anchor)
      matches!(data, registry)
      data
    end
  end
end
