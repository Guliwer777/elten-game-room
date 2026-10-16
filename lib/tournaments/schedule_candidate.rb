# encoding: UTF-8
require 'digest'
require_relative 'schedule_source'
require_relative 'league_plan'
require_relative 'group_schedule'
require_relative 'knockout_schedule'

module GameRoomTournaments
  # Pure observed candidate, not a final roster, reservation or permission to play.
  class ScheduleCandidate
    Data = Publication::Data
    Invalid = Publication::Invalid

    # Granica całego wyniku, nie zwiększenie domyślnych limitów Publication::Data.
    # LeaguePlan odmawia >5000 spotkań PRZED kombinacjami; skład ma <=8 nazw.
    # Raw nazwa ma <=64 znaki. Unicode downcase może dać 128 znaków (U+0130),
    # ale nadal <=256 bajtów UTF-8: najwyżej 4 bajty na surowy znak. Próba
    # unicode_byte_bound_probe potwierdza też <=4 bajty JSON na surowy znak,
    # łącznie z escapowaniem: <=256 bajtów tekstu + 2 cudzysłowy + przecinek.
    # Rekord ma 9 węzłów + nazwy (liczymy także klucze Hash). Roster: <=256 nazw.
    # Metadane mieszczą się w 64 węzłach; dokumenty mają po <=4096 węzłów.
    # Budżet bajtów metadanych WSPÓŁDZIELI zapas z dokumentem okien: samo
    # escapowanie backendu może przekroczyć 8192. Test granic daje 9456 bajtów
    # kontekstu i 27817 bajtów dla 366 okien, razem <8192+MAX_JSON_BYTES.
    # Drugi MAX_JSON_BYTES pokrywa opcje. Test dowodu liczy też przecinki spotkań;
    # bounded_copy odmawia nadmiernej tablicy przed mapowaniem i serializacją.
    MATCH_FIXED_BYTES = '{"number":5000,"players":[],"leg":2,"match_id":""}'.bytesize + 64
    MAX_RESULT_NODES = 64 + 257 + 2 * 4096 + 5000 * (9 + 8)
    MAX_RESULT_BYTES = 8192 + 256 * (256 + 3) + 2 * Publication::MAX_JSON_BYTES +
      5000 * (MATCH_FIXED_BYTES + 8 * (256 + 3))

    def self.build(projection:, publication_ref:, backend_identity:, observed_at:)
      observed = ScheduleSource.build(projection: projection, publication_ref: publication_ref,
        backend_identity: backend_identity, observed_at: observed_at)
      row, settings, schedule, members, publication_ref, backend_identity =
        observed.values_at(:row, :settings, :schedule, :members, :publication_ref, :backend_identity)
      roster = members.map { |member| member.fetch('account') }
      accounts = members.to_h { |member| [member.fetch('username'), member.fetch('account')] }
      # LeaguePlan validates RAW spelling (<=64 characters), not expanded downcase.
      # Keep canonical order and restore canonical players before computing any ID.
      names = members.map { |member| member.fetch('username') }
      groups = nil
      direct = settings['format'] == 'groups_knockout' && ['automatic_cross_groups_v1', 'automatic_compact_groups_v2'].include?(settings['group_advancement']) && roster.size == 2
      if direct
        compositions = plan(names, settings.merge('rematch' => false))
      elsif settings['format'] == 'groups_knockout'
        compositions, groups = GroupSchedule.build(roster: names, settings: settings, players_per_match: settings['players_per_match'])
      else
        compositions = plan(names, settings)
      end
      matches = compositions.map do |match|
        match.merge('players' => match.fetch('players').map { |username| accounts.fetch(username) })
      end
      content = Publication::COLUMNS.to_h { |key| [key, row.fetch(key)] }
      content_digest = digest(content)
      generation = digest(['tournament-roster-v1', backend_identity, publication_ref, content_digest, roster])
      schedule_id = digest(['tournament-schedule-v1', generation,
        matches.map { |match| match.values_at('players', 'leg') }])
      matches = matches.map do |match|
        # Preserve the planner's ORDERED players: do not collapse future seat/role semantics.
        match.merge('match_id' => digest(['tournament-match-v1', schedule_id,
          match.fetch('players'), match.fetch('leg')]))
      end
      data = { 'schedule_id' => schedule_id, 'roster_generation' => generation,
        'backend_identity' => backend_identity, 'publication_ref' => publication_ref,
        'publication_digest' => content_digest, 'format' => settings.fetch('format'),
        'pairing' => settings.fetch('pairing'), 'rematch' => settings.fetch('rematch'),
        'players_per_match' => settings.fetch('players_per_match'), 'roles_teams' => 'unassigned',
        'timezone' => row.fetch('timezone'),
        'registration_opens_at' => row.fetch('registration_opens_at'),
        'registration_closes_at' => row.fetch('registration_closes_at'),
        'state' => 'observed_candidate', 'finality' => 'unknown', 'dispatch_allowed' => false,
        'finalize_allowed' => false, 'start_allowed' => false, 'observed_at' => observed_at,
        'roster' => roster, 'matches' => matches, 'game_id' => row.fetch('game'),
        'game_options' => settings.fetch('game_options'), 'windows' => schedule.fetch('windows') }
      data['groups'] = GroupSchedule.metadata(groups, matches, unit_mapping: accounts) if groups
      data['starts_at']=schedule['starts_at'] if TournamentTiming.optional?(row)
      data['group_advancement'] = settings['group_advancement'] if settings.key?('group_advancement')
      Publication::ROUND_SETTINGS.each { |key| data[key] = settings[key] } if settings.key?('knockout_rematch')
      Publication::WIN_SETTINGS.each{|key|data[key]=settings[key] if settings.key?(key)}
      if direct
        data.merge!('format' => 'knockout', 'rematch' => settings['final_rematch'] == true,
          'knockout' => KnockoutSchedule.direct_metadata(seeds: roster, generation: generation, publication_digest: content_digest, rematch: settings['final_rematch'] == true,target:settings['final_wins_to']))
        data['schedule_id'], data['matches'] = KnockoutSchedule.matches(metadata: data['knockout'], generation: generation)
      end
      new(bounded_copy(data))
    end

    def self.plan(roster, settings)
      LeaguePlan.build(participants: roster, players_per_match: settings.fetch('players_per_match'),
        pairing: settings.fetch('pairing'), rematch: settings.fetch('rematch'))
    rescue LeaguePlan::Invalid => error
      # Tłumaczymy tylko faktyczne odmowy planera, nie błędy programu lub nowe kody.
      code = case error.code
      when :too_many_matches then :plan_too_large
      when :invalid_participants
        if roster.empty?
          :no_players
        elsif roster.length < 2
          :too_few_players
        elsif roster.length > 256
          :too_many_players
        end
      when :invalid_players_per_match
        :too_few_players if roster.length < settings.fetch('players_per_match')
      end
      raise unless code
      raise Invalid.new(code), cause: error
    end
    private_class_method :plan

    def self.bounded_copy(value)
      Data.copy(value, max_bytes: MAX_RESULT_BYTES, max_nodes: MAX_RESULT_NODES, max_depth: 8)
    end
    private_class_method :bounded_copy

    def self.digest(value)
      Digest::SHA256.hexdigest(JSON.generate(bounded_copy(value)))
    end
    private_class_method :digest

    def initialize(data)
      @data = Data.freeze_tree(data)
      freeze
    end
    private_class_method :new

    def to_h
      @data
    end
  end
end
