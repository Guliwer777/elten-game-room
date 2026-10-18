# encoding: UTF-8
module GameRoomTournaments
  # One player-facing name for schedules, standings and phase notifications.
  module PhaseDescription
    using GameRoomLocalization::Translations
    module_function

    def identity(candidate)
      case candidate['format']
      when 'groups_knockout' then ['groups']
      when 'knockout'
        knockout=candidate.fetch('knockout')
        knockout['qualification'] ? ['qualification'] : ['knockout',knockout.fetch('round'),knockout.fetch('seeds').sort]
      else [candidate['format']]
      end
    end

    def label(candidate)
      value=case candidate['format']
      when 'round_robin' then _("Round robin")
      when 'groups_knockout' then _("Group stage")
      when 'knockout'
        knockout=candidate.fetch('knockout')
        if knockout['qualification']
          _("Additional matches to resolve group qualification")
        else
          name=if knockout['players_per_match']==2
            case knockout.fetch('seeds').size
            when 2 then _("Final")
            when 3..4 then _("Semifinals")
            when 5..8 then _("Quarterfinals")
            when 9..16 then _("Round of 16")
            end
          end
          name || (GameRoomContent.utf8(_("Knockout round: %{round}"))%{round:knockout.fetch('round')})
        end
      else _("Tournament phase")
      end
      GameRoomContent.utf8(value)
    end

    def label_data(candidate)
      data=candidate.slice('format')
      data['knockout']=candidate.fetch('knockout').slice('round','seeds','players_per_match','qualification') if candidate['format']=='knockout'
      data
    end

    # History is reconstructed from verified results by ServerPhaseStore.
    # Advancing a tied leg/series does not finish the sporting phase.
    def transitions(source)
      history=source.fetch('phase_history',[])
      phases=history.map{|entry|entry.fetch('candidate')}+[source.fetch('candidate')]
      history.each_with_index.filter_map do |entry,index|
        previous,following=phases[index,2]
        next if identity(previous)==identity(following)
        time=entry.fetch('view').fetch('progress_times',[]).max
        next unless time.is_a?(Integer) && time>0
        {'phase_id'=>previous.fetch('schedule_id'),'phase'=>previous,'next_phase'=>following,'completed_at'=>time}
      end
    end
  end
end
