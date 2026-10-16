# encoding: UTF-8
require 'json'
require_relative '../game_content'
require_relative '../game_room_localization'
require_relative '../game_option_values'
require_relative 'local_registration_time'
require_relative 'tournament_lifecycle'

module GameRoomTournaments
  # Formatuje wyłącznie zwalidowaną projekcję; bez planowania lub odczytu konta.
  class PublicText
    using GameRoomLocalization::Translations

    def initialize(registry:, mode_label:, actor:, local_time: ->(seconds) { Time.at(seconds).getlocal })
      unless [mode_label, actor].all? { |value| value.is_a?(String) && !text(value).strip.empty? }
        raise ArgumentError, 'mode_label and actor must be explicit nonempty strings'
      end
      @registry, @mode_label, @actor = registry, text(mode_label), text(actor)
      @local_time = local_time
    end

    def members(publication, snapshot)
      snapshot.fetch('members').select { |member| member.fetch('tournament_id') == publication.fetch('__id') }
    end

    def row_label(publication, snapshot)
      label=text(_("%{name}; %{game}; participants: %{count}")) % {
        name: text(publication.fetch('title')), game: text(@registry.name(publication.fetch('game'))),
        organizer: text(publication.fetch('__insertion_user')), count: members(publication, snapshot).length }
      if publication['__insertion_user'].downcase==@actor.downcase
        label += '; ' + text(_("You organize this tournament"))
      elsif members(publication,snapshot).any?{|person|person['account'].downcase==@actor.downcase}
        label += '; ' + text(_("You are registered"))
      end
      label
    end

    def lifecycle_label(state)
      text(case state
      when :registration then _("Registration open")
      when :soon then _("Registration not open yet")
      when :waiting then _("Waiting for tournament start")
      when :running then _("Tournament in progress")
      when :ended then _("Ended — scheduled time has passed")
      when :completed then _("Completed — all required matches have been resolved")
      else _("Tournament status unavailable")
      end)
    end

    def diagnostics(snapshot)
      reports = snapshot.fetch('diagnostics')
      text(_("Rejected or conflicting entry reports — announcements: %{announcements}; registrations: %{registrations}. These are not accepted entries.")) % {
        announcements: reports.fetch('announcements').length, registrations: reports.fetch('registrations').length }
    end

    def context
      [@mode_label, text(_("Current identity: %{actor}")) % { actor: @actor }].join("\r\n")
    end

    def summary(publication,snapshot,now:Time.now.to_i)
      state=TournamentLifecycle.classify(publication,now:now)
      accepted=members(publication,snapshot)
      registered=accepted.any?{|person|person['account']==@actor.downcase}
      lines=[text(publication['title']),text(@registry.name(publication['game'])),lifecycle_label(state[:state]),
        pair(_("Organizer"),publication['__insertion_user']),pair(_("Participants"),accepted.size)]
      lines << text(_("You are registered")) if registered
      lines << text(_("The planned deadline has passed. Remaining matches can still be played.")) if state[:overdue]
      limit=JSON.parse(publication['settings_json'])['participant_limit']
      if !registered
        lines << text(if state[:state]==:soon then _("Registration has not opened yet.")
          elsif state[:state]!=:registration then _("Registration is closed.")
          elsif limit && accepted.size>=limit then _("The tournament is full.")
          else _("Choose Join tournament to take part.")
          end)
      end
      lines.join("\r\n")
    end

    def can_join?(publication,snapshot,now:Time.now.to_i)
      limit=JSON.parse(publication['settings_json'])['participant_limit']
      TournamentLifecycle.classify(publication,now:now)[:state]==:registration &&
        (!limit || members(publication,snapshot).size<limit)
    end

    def action_header(publication,snapshot,now:Time.now.to_i)
      state=TournamentLifecycle.classify(publication,now:now)[:state]
      status=lifecycle_label(state)
      status=text(_("The tournament is full.")) if state==:registration && !can_join?(publication,snapshot,now:now)
      text(publication['title'])+text(' — ')+status
    end

    def description(publication, snapshot)
      game = @registry.build(publication.fetch('game'))
      settings = JSON.parse(publication.fetch('settings_json'))
      lines = [pair(_("Tournament name"), publication.fetch('title')),
        pair(_("Game"), game.name),
        pair(_("Tournament format"), { 'round_robin' => _("Round robin"), 'groups_knockout' => _("Groups and knockout") }.fetch(settings.fetch('format'))),
        pair(_("Return matches"), settings.fetch('rematch') ? _("Yes") : _("No")),
        pair(_("Players per match"), settings.fetch('players_per_match')),
        pair(_("Multiplayer pairings"), { 'all_combinations' => _("All possible compositions"),
          'balanced_cycle' => _("Rotating compositions; equal appearances") }.fetch(settings.fetch('pairing'))),
        pair(_("Tournament rules"), publication.fetch('rules')),
        pair(_("Registration opens"), optional_date(publication.fetch('registration_opens_at'))),
        pair(_("Registration closes"), optional_date(publication.fetch('registration_closes_at')))]
      lines << text(_("Each match awards 2 tournament points per opponent beaten and 1 per tied opponent. Teams count as single opponents."))
      if TournamentTiming.optional?(publication)
        lines << pair(_("Tournament starts"),optional_date(TournamentTiming.starts_at(publication)))
        lines << pair(_("Tournament deadline"),TournamentTiming.deadline_at(publication) ? local_date(TournamentTiming.deadline_at(publication)) : _("Not set"))
        lines << text(_("Matches may be played at any time after the tournament starts.")) if TournamentTiming.schedule(publication)['windows'].empty?
      end
      if settings['format'] == 'groups_knockout' && settings['group_advancement'] == 'automatic_compact_groups_v2'
        lines << text(_("Groups of three or four; four preferred. Extra qualifying places compare results without matches against the last player of a larger group."))
      elsif settings['format'] == 'groups_knockout' && settings['group_advancement'] == 'automatic_cross_groups_v1'
        lines << text(_("Automatic qualification: two groups through 16 participants, four above 16; the largest power of two advances. Cross-pair first with last."))
      elsif settings['format'] == 'groups_knockout' && settings['group_count']
        lines << pair(_("Number of groups"), settings['group_count'])
        lines << pair(_("Qualifying places per group"), settings['places_per_group'])
        lines << text(_("Groups use the confirmed roster order. Group results and qualification must be completed before knockout matches are planned."))
      end
      if settings.key?('knockout_rematch')
        lines << pair(_("Return matches in knockout rounds"), settings['knockout_wins_to'] ? _("Play until a specified number of wins") : settings['knockout_rematch'] ? _("Yes") : _("No"))
        lines << pair(_("Return match in the final"), settings['final_wins_to'] ? _("Play until a specified number of wins") : settings['final_rematch'] ? _("Yes") : _("No"))
        lines << text(_("Two-leg knockout ties use match points, then complete game scores. If still tied, an additional single game is played.")) if Publication::ROUND_SETTINGS.any?{|key|settings[key]}
      end
      [['knockout_wins_to',_("Wins required in knockout rounds")],['final_wins_to',_("Wins required in the final")]].each do |key,label|
        lines << pair(label,settings[key]) if settings.key?(key)
      end
      JSON.parse(publication.fetch('schedule_json')).fetch('windows').each do |window|
        window = viewer_window(window) if publication['timezone'] == 'UTC'
        lines << (text(_("%{start_date} %{start_time} to %{end_date} %{end_time}")) % {
          start_date: text(window.fetch('date')), start_time: text(window.fetch('start')),
          end_date: text(window.fetch('end_date')), end_time: text(window.fetch('end')) })
      end
      game_lines = [text(_("Game settings"))]
      options = settings.fetch('game_options')
      game_lines.concat(GameRoomOptionValues.lines(game, options))
      lines.insert(3,*game_lines)
      accepted = members(publication, snapshot)
      lines << pair(_("Maximum tournament participants"), settings['participant_limit']) if settings['participant_limit']
      lines << pair(_("Organizer"), publication.fetch('__insertion_user'))
      lines << (text(_("Accepted participants: %{count}")) % { count: accepted.length })
      lines.concat(accepted.map { |member| text(member.fetch('username')) })
      pairs = (snapshot['pairs'] || []).select { |row| row['tournament_id'] == publication['__id'] }
      unless pairs.empty?
        names = accepted.to_h { |person| [person['account'], person['username']] }
        lines << text(_("Tournament pairs"))
        lines.concat(pairs.map { |row| row['accounts'].map { |account| text(names.fetch(account, account)) }.join(' — ') })
      end
      lines.flat_map{|line|line.split(/\r?\n/)}.reject{|line|line.strip.empty?}.join("\r\n")
    end

    private

    def optional_date(value)
      value && value>0 ? local_date(value) : text(_("Organizer decides"))
    end

    def viewer_window(window)
      first = @local_time.call(LocalRegistrationTime.convert_utc(window.fetch('date'), window.fetch('start')))
      last = @local_time.call(LocalRegistrationTime.convert_utc(window.fetch('end_date'), window.fetch('end')))
      {'date' => first.strftime('%Y-%m-%d'), 'start' => first.strftime('%H:%M %:z'),
        'end_date' => last.strftime('%Y-%m-%d'), 'end' => last.strftime('%H:%M %:z')}
    end

    def local_date(seconds)
      @local_time.call(seconds).strftime('%Y-%m-%d %H:%M:%S %:z')
    end

    def pair(label, value)
      text(label) + ': ' + text(value)
    end

    def text(value)
      GameRoomContent.utf8(value)
    end
  end
end
