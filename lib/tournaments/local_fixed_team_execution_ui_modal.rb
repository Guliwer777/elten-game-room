# encoding: UTF-8
module GameRoomTournaments
  # Tylko modal FT2: przywrócenie kursora również po callbacku before_focus.
  # Natychmiastową prezentację nadal wykonuje istniejący LeaseWindow.
  module LocalFixedTeamExecutionUIModal
    private

    def make_form(fields, cancel:)
      super.tap { |form| form.entry_presentation = method(:restore_modal_presentation) }
    end

    def interaction(restore: true)
      return if @busy || @finished
      @modal_presentation = if restore && @form
        {field: @form.index, positions: @form.fields.filter_map do |field|
          if field.is_a?(EditBox)
            [field, field.index, field.check]
          elsif field.is_a?(ListBox)
            [field, field.index, nil]
          end
        end}
      end
      begin
        super
      ensure
        @modal_presentation = nil
      end
    end

    def restore_modal_presentation
      snapshot = @modal_presentation
      return unless snapshot && @context.current?(@lease)
      snapshot[:positions].each do |field, index, check|
        field.index = index
        field.check = check if field.is_a?(EditBox)
      end
      @form.index = snapshot[:field]
    end
  end
end
