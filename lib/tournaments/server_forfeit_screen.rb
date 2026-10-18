# encoding: UTF-8
require_relative 'ui_dialogs'
require_relative 'standings'
module GameRoomTournaments
  class ServerForfeitScreen < Dialogs::Window
    using GameRoomLocalization::Translations
    def self.explanation(preview)
      case preview.dig('decision','basis')
      when 'unstarted'
        preview.fetch('summary').fetch('participants').size>2 ?
          _("The match had not started. The remaining participants share first place.") : _("Forfeit before the match started.")
      when 'no_scored_round'
        _("No round was completed. The remaining participants share first place.")
      when 'scored_round'
        preview.dig('decision','checkpoint','kind')=='deal' ?
          _("Places are based on the scores after the last completed deal.") :
          _("Places are based on the scores after the last completed round.")
      end
    end

    def initialize(program:, names:)
      @program,@names=program,names
    end
    private
    def build_form
      @loser=ListBox.new(@names,header:text(_("Who loses by forfeit?")),quiet:true)
      next_step=button(_("Next")){finish(@loser.index)}
      cancel=button(_("Cancel"))
      make_form([@loser,next_step,cancel],cancel:cancel)
    end

    class Confirmation < Dialogs::Window
      using GameRoomLocalization::Translations
      def initialize(program:, preview:, names: {})
        @program,@preview,@names=program,preview,names
      end
      private
      def build_form
        return build_continuation_form if @preview.dig('decision','mode')=='continue'
        summary=@preview.fetch('summary')
        loser=@preview.fetch('decision').fetch('loser')
        points=Standings.calculate(units:summary['participants'],
          results:[summary.slice('participants','winners','scores','score_order','places').merge('id'=>'preview')],
          points:Standings::MATCH_POINTS).to_h { |row| [row['unit'],row['points']] }
        lines=[text(_("%{player} loses by forfeit. This ends the match in the tournament."))%{player:@names.fetch(loser,loser)}]
        explanation=ServerForfeitScreen.explanation(@preview)
        lines << text(explanation) if explanation
        place=1
        summary.fetch('places').each do |group|
          group.each do |unit|
            lines << text(_("%{place}. %{player}; tournament points: %{points}"))%{
              place:place,player:@names.fetch(unit,unit),points:points.fetch(unit)}
          end
          place+=group.size
        end
        if summary['scores']
          scores=summary['participants'].map { |unit| "#{@names.fetch(unit,unit)}: #{summary['scores'].fetch(unit)}" }.join('; ')
          lines << text(_("Game scores after the last completed round: %{scores}"))%{scores:scores}
        end
        details=readonly(_("Forfeit consequences"),lines.join("\n"))
        confirm=button(_("Confirm forfeit")){finish(true)}
        cancel=button(_("Cancel"))
        make_form([details,confirm,cancel],cancel:cancel)
      end

      def build_continuation_form
        loser=@preview.fetch('decision').fetch('loser')
        message=text(_("%{player} is eliminated by forfeit. The remaining participants continue playing."))%{
          player:@names.fetch(loser,loser)}
        details=readonly(_("Forfeit consequences"),message)
        confirm=button(_("Confirm forfeit")){finish(true)}
        cancel=button(_("Cancel"))
        make_form([details,confirm,cancel],cancel:cancel)
      end
    end
  end
end
