# encoding: UTF-8
module GameRoomTournaments
  # Wyłącznie wybór FT2: odtworzenie danych nie emituje dodatkowego focus.
  module LocalFixedTeamExecutionUISelection
    private

    def make_form(fields, cancel:)
      super.tap { |form| form.entry_presentation = method(:restore_fixed_presentation) }
    end

    def interaction(restore: true)
      return if @busy || @readiness_pending || @finished
      @fixed_presentation = if restore && @form
        {selection: selectors, field: @form.index,
          positions: @form.fields.filter_map do |field|
            [field, field.index, field.check] if field.is_a?(EditBox)
          end}
      end
      begin
        super
      ensure
        @fixed_presentation = nil
      end
    end

    def restore_fixed_presentation
      snapshot = @fixed_presentation
      return unless snapshot && !@restoring_fixed && current?
      @restoring_fixed = true
      begin
        selection = snapshot[:selection]
        if selection
          @tournaments.index = @controller.view[:tournaments].index { |row| row['__id'] == selection[:intent_id] }
          @matches.index = @controller.view[:matches].index { |row| row['match_id'] == selection[:match_id] }
          update_windows
          match = @controller.view[:matches][@matches.index]
          @windows.index = match['windows'].index { |row| row['id'] == selection[:window_id] }
          @status.set_text(status_text)
        end
        snapshot[:positions].each { |field, index, check| field.index, field.check = index, check }
        @form.index = snapshot[:field]
      ensure
        @restoring_fixed = false
      end
    end
  end
end
