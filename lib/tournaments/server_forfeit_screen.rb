# encoding: UTF-8
require_relative 'ui_dialogs'
require_relative 'standings'
require_relative 'administrative_result'
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

    def initialize(program:, names:, units: nil, policy: nil)
      @program,@names,@units,@policy=program,names,units,policy
    end
    private
    def build_form
      return @units.size==2 ? build_duel_editor : build_editor if @units
      @loser=ListBox.new(@names,header:text(_("Who loses by forfeit?")),quiet:true)
      next_step=button(_("Next")){finish(@loser.index)}
      cancel=button(_("Cancel"))
      make_form([@loser,next_step,cancel],cancel:cancel)
    end

    def build_duel_editor
      @loser=ListBox.new(@units.map { |unit| @names.fetch(unit,unit) },header:text(_("Who loses by forfeit?")),quiet:true)
      @loser.index=1
      @duel_scores=@policy ? @units.to_h do |unit|
        [unit,EditBox.new(text(_("Administrative small points"))+": "+@names.fetch(unit,unit),text:'',quiet:true)]
      end : {}
      refresh_duel_scores
      @loser.on(:move) { refresh_duel_scores }
      review=button(_("Review result")) do
        loser=@units.fetch(@loser.index)
        scores=@duel_scores.empty? ? nil : @duel_scores.to_h do |unit,field|
          raw=field.text.to_s.strip
          unless /\A-?\d+(?:\.\d+)?\z/.match?(raw)
            @program.send(:alert,text(_("Enter small points for %{player}."))%{player:@names.fetch(unit,unit)})
            break
          end
          [unit,raw.include?('.') ? raw.to_f : raw.to_i]
        end
        next if !@duel_scores.empty? && !scores.is_a?(Hash)
        decision={places:[@units-[loser],[loser]],forfeits:[loser],scores:scores}
        begin
          AdministrativeResult.build(units:@units,policy:@policy,**decision)
          finish(decision)
        rescue Publication::Invalid
          @program.send(:alert,text(_("Check the result: a winner cannot lose by forfeit, and all small-point values must be valid.")))
        end
      end
      zero=button(_("Award zero points to everyone")) { finish({all_zero:true}) }
      cancel=button(_("Cancel"))
      make_form([@loser,*@duel_scores.values,review,zero,cancel],cancel:cancel)
    end

    def refresh_duel_scores
      @duel_scores.each do |unit,field|
        old=@duel_defaults && @duel_defaults[unit]
        value=@policy.fetch(unit==@units[@loser.index] ? :loser : :winner).to_s
        field.set_text(value) if old.nil? || field.text == old
        (@duel_defaults ||= {})[unit]=value
      end
    end

    def build_editor
      @rows = @units.each_with_index.map do |unit,index|
        {unit: unit, place: index + 1, forfeit: index == @units.size - 1,
          score: @policy && @policy.fetch(index == @units.size - 1 ? :loser : :winner).to_s}
      end
      @list = ListBox.new([],header:text(_("Players or teams")),quiet:true)
      @place = ListBox.new((1..@units.size).map(&:to_s),header:text(_("Place")),quiet:true)
      @forfeit = CheckBox.new(text(_("Loses by forfeit")),checked:false)
      @score = EditBox.new(text(_("Administrative small points")),text:'',quiet:true) if @policy
      next_step = button(_("Review result")) { review_editor }
      all_zero = button(_("Award zero points to everyone")) { finish({all_zero: true}) }
      cancel = button(_("Cancel"))
      make_form([@list,@place,@forfeit,@score,next_step,all_zero,cancel].compact,cancel:cancel)
      refresh_rows
      load_row(0)
      @list.on(:move) { interaction(restore:false,focus:false) { store_row; load_row(@list.index); refresh_rows } }
      @forfeit.on(:change) do
        if @policy && @row
          old=@policy.fetch(@row[:forfeit] ? :loser : :winner).to_s
          value=@policy.fetch(@forfeit.checked ? :loser : :winner).to_s
          @score.set_text(value) if @score.text.to_s==old
        end
        store_row
        refresh_rows
      end
    end

    def store_row
      return unless @row
      @row[:place] = @place.index + 1
      @row[:forfeit] = @forfeit.checked == true
      @row[:score] = @score.text.to_s.strip if @score
    end

    def load_row(index)
      @row = @rows.fetch(index)
      @place.index = @row[:place] - 1
      @forfeit.checked = @row[:forfeit]
      @score.set_text(@row[:score]) if @score
    end

    def refresh_rows
      @list.update_options(@rows.map do |row|
        label = "#{row[:place]}. #{@names.fetch(row[:unit],row[:unit])}"
        label += "; " + text(_("Forfeit")) if row[:forfeit]
        label += "; " + row[:score] if @score
        label
      end,keys:@units)
    end

    def review_editor
      store_row
      grouped = @rows.group_by { |row| row[:place] }.sort
      rank = 1
      valid_places = grouped.all? { |place, rows| valid = place == rank; rank += rows.size; valid }
      unless valid_places
        @program.send(:alert,text(_("Check the places. After a shared place, skip the places occupied by that group.")))
        return
      end
      values = if @score
        @rows.to_h do |row|
          raw = row[:score]
          unless /\A-?\d+(?:\.\d+)?\z/.match?(raw)
            @program.send(:alert,text(_("Enter small points for %{player}."))%{player:@names.fetch(row[:unit],row[:unit])})
            return
          end
          [row[:unit],raw.include?('.') ? raw.to_f : raw.to_i]
        end
      end
      decision = {places: grouped.map { |_rank,rows| rows.map { |row| row[:unit] } },
        forfeits: @rows.select { |row| row[:forfeit] }.map { |row| row[:unit] }, scores: values}
      AdministrativeResult.build(units:@units,policy:@policy,**decision)
      finish(decision)
    rescue Publication::Invalid
      @program.send(:alert,text(_("Check the result: a winner cannot lose by forfeit, and all small-point values must be valid.")))
    end

    class Confirmation < Dialogs::Window
      using GameRoomLocalization::Translations
      def initialize(program:, preview:, names: {})
        @program,@preview,@names=program,preview,names
      end
      private
      def build_form
        return build_administrative_form if @preview['kind']=='ordinary-match-forfeit-v3'
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

      def build_administrative_form
        summary = @preview.fetch('summary')
        zero = summary['resolution'] == 'all_zero'
        points = Standings.calculate(units:summary['participants'],
          results:[summary.slice('participants','winners','scores','score_order','places','forfeits','resolution').merge('id'=>'preview')],
          points:Standings::MATCH_POINTS).to_h { |row| [row['unit'],row['points']] }
        lines = [text(zero ? _("Everyone receives zero tournament points. No winner is recorded.") : _("Review the final places and points."))]
        place = 1
        (summary['places'] || [summary['participants']]).each do |group|
          group.each do |unit|
            line = zero ? "#{@names.fetch(unit,unit)}: 0" : text(_("%{place}. %{player}; tournament points: %{points}"))%{
              place:place,player:@names.fetch(unit,unit),points:points.fetch(unit)}
            line += "; " + text(_("Forfeit")) if summary.fetch('forfeits',[]).include?(unit)
            line += "; " + text(_("Small points: %{score}"))%{score:summary['scores'].fetch(unit)} if summary['scores']
            lines << line
          end
          place += group.size
        end
        details=readonly(_("Forfeit consequences"),lines.join("\n"))
        confirm=button(_("Confirm result")) { finish(true) }
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
