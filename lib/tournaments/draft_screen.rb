# encoding: UTF-8
require_relative 'draft_editor'
require_relative 'draft_preview'

module GameRoomTournaments
  class DraftScreen
    using GameRoomLocalization::Translations

    def initialize(program:, registry:, load:, persist:, remove:, configure:, alert:, confirm:)
      @program, @registry, @load, @persist = program, registry, load, persist
      @remove, @configure, @alert, @confirm = remove, configure, alert, confirm
    end

    def run
      @rows = @load.call
      return unless @rows
      @list = ListBox.new([], header: text(_("Tournament drafts")), quiet: true,
        empty_label: text(_("No local tournament drafts.")))
      status = EditBox.new(text(_("Status")), type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine,
        text: text(_("Local drafts are stored for this account on this computer. They are not published; registrations, invitations and matches are not active yet.")), quiet: true)
      create = Button.new(text(_("New draft")))
      view = Button.new(text(_("View draft")))
      open = Button.new(text(_("Edit draft")))
      remove = Button.new(text(_("Delete draft")))
      refresh = Button.new(text(_("Refresh")))
      back = Button.new(text(_("Back")))
      @form = GameRoomUI::Form.new([@list, status, view, create, open, remove, refresh, back], program: @program, quiet: true)
      @form.cancel_button, @form.accept_button = back, view
      view.on(:press) { interaction { preview } }
      create.on(:press) { interaction { edit(nil) } }
      open.on(:press) { interaction { edit(@rows[@list.index]) if @rows[@list.index] } }
      remove.on(:press) { interaction { delete_selected } }
      refresh.on(:press) { interaction { refresh_rows } }
      back.on(:press) { interaction { @finished = true; @form.resume } }
      render_rows
      @form.wait
    end

    private

    def interaction
      return if @busy || @finished
      @busy = true
      begin
        yield
      ensure
        @busy = false
      end
    end

    def preview
      row = @rows[@list.index]
      return unless row
      previous_index = @form.index
      DraftPreview.new(program: @program, registry: @registry, draft: row, alert: @alert).wait
      @form.index = previous_index if @form.index != previous_index
      @form.focus
    end

    def edit(row)
      saved = DraftEditor.new(program: @program, registry: @registry, draft: row,
        configure: @configure, alert: @alert, save: ->(attributes) { @persist.call(row, attributes) }).wait
      return unless saved
      @rows = @rows.reject { |item| item['id'] == saved['id'] } + [saved]
      render_rows
      refresh_rows
      @list.index = @rows.index { |item| item['id'] == saved['id'] } || 0
      @alert.call(text(_("Draft saved locally. It has not been published.")))
    end

    def refresh_rows
      refreshed = @load.call
      return unless refreshed
      @rows = refreshed
      render_rows
    end

    def delete_selected
      row = @rows[@list.index]
      return unless row && @confirm.call(text(_("Delete this local tournament draft?")))
      return unless @remove.call(row)
      @rows = @rows.reject { |item| item['id'] == row['id'] }
      render_rows
      @alert.call(text(_("Local draft deleted.")))
    end

    def render_rows
      labels = @rows.map do |row|
        text(_("%{name}; %{game}; local draft")) % {
          name: text(row.fetch('name')), game: text(@registry.name(row.fetch('game_id'))) }
      end
      @list.update_options(labels, keys: @rows.map { |row| row.fetch('id') })
    end

    def text(value)
      GameRoomContent.utf8(value)
    end
  end
end
