# encoding: UTF-8
require_relative 'drafts'
require_relative 'draft_screen'
require_relative '../game_option_editor'

module GameRoomTournaments
  class DraftWorkspace
    using GameRoomLocalization::Translations

    def initialize(program:, registry:, user:, alert:, confirm:)
      @program, @registry, @user, @alert, @confirm = program, registry, user, alert, confirm
      @owner = user.call.to_s.strip.downcase.freeze
    end

    def run
      DraftScreen.new(program: @program, registry: @registry, load: method(:load),
        persist: method(:persist), remove: method(:remove), configure: method(:configure),
        alert: @alert, confirm: @confirm).run
    end

    def load
      access(_("Loading tournament drafts")) { |store| store.list }
    end

    def persist(row, attributes)
      access(_("Saving tournament draft")) do |store|
        if row
          store.update(row.fetch('id'), attributes, expected_revision: row.fetch('revision'))
        else
          store.create(attributes)
        end
      end
    end

    def remove(row)
      access(_("Deleting tournament draft")) { |store| store.delete(row.fetch('id'), expected_revision: row.fetch('revision')) }
    end

    def configure(game, options)
      GameRoomOptionEditor.new(program: @program, defaults: ->(model, _definitions) { model.default_options },
        remember: ->(*) {}, alert: @alert).edit(game, initial_options: options, submit_label: _("Next"),require_confirmation:true)
    end

    private

    class AccountChanged < StandardError; end

    def access(title)
      check_account
      result = EltenAPI::Tasks.run(title: GameRoomContent.utf8(title), ui: :none, cancellable: false) do
        check_account
        @store ||= Drafts.new(@program, owner: @owner)
        check_account
        yield @store
      end
      check_account
      result
    rescue AccountChanged
      failure(_("The account changed. Close this window and reopen tournament drafts."))
    rescue Drafts::Conflict
      failure(_("This draft changed or was deleted in another window. Reopen it before saving."))
    rescue Drafts::Corrupt
      failure(_("The local draft storage is damaged or incompatible. It has not been replaced."))
    rescue Drafts::Invalid => error
      failure(error.code == :invalid_name ? _("Enter a tournament name (1-120 characters, one line).") :
        _("The tournament draft contains invalid settings or exceeds the storage limit."))
    rescue IOError, SystemCallError
      failure(_("The draft operation could not be completed. Reopen the list to check the saved state."))
    end

    def check_account
      raise AccountChanged if @owner.empty? || @user.call.to_s.strip.downcase != @owner
    end

    def failure(message)
      @alert.call(GameRoomContent.utf8(message))
      nil
    end
  end
end
