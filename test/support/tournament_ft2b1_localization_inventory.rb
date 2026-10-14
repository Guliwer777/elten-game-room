# encoding: UTF-8
require 'json'
require 'digest'
require_relative '../../tools/support/translation_extractor'

module TournamentFT2B1LocalizationInventory
  ROOT = File.expand_path('../..', __dir__)
  PATHS = %w[lib/game_room_transport.rb lib/live_session_store.rb
    lib/tournaments/fixed_team_native_target_adapter.rb
    lib/tournaments/local_fixed_team_connection.rb lib/tournaments/local_fixed_team_entry.rb
    lib/tournaments/local_fixed_team_execution.rb lib/tournaments/local_fixed_team_execution_details.rb
    lib/tournaments/local_fixed_team_execution_screen.rb lib/tournaments/local_fixed_team_native_endpoint.rb
    lib/tournaments/local_fixed_team_native_provider.rb lib/tournaments/local_fixed_team_plan_backend.rb
    lib/tournaments/local_test_hub.rb lib/tournaments/local_workspace.rb lib/tournaments/match_entry_screen.rb
    lib/tournaments/local_fixed_team_execution_ui_modal.rb lib/tournaments/local_fixed_team_execution_ui_selection.rb].freeze
  module_function
  def collect(root = ROOT)
    records, warnings, files = {}, [], []
    PATHS.each do |path|
      bytes = File.binread(File.join(root, path))
      tree = Prism.parse(bytes.dup.force_encoding('UTF-8'))
      raise "Błąd AST #{path}" unless tree.errors.empty?
      extracted = GameRoomTranslationExtractor.extract_source(bytes.dup.force_encoding('UTF-8'), path: path, warnings: warnings)
      extracted.each { |row| GameRoomTranslationExtractor.merge_record(records, **row) }
      files << {path: path, sha256: Digest::SHA256.hexdigest(bytes), messages: extracted.size}
    end
    raise "Niepełne AST: #{warnings.inspect}" unless warnings.empty?
    # Parametr bloku nie jest wywołaniem gettext.
    probe = GameRoomTranslationExtractor.extract_source('items.reject { |k, _| k == :x }; _("probe")', path: 'probe.rb', warnings: warnings)
    raise 'Błędna klasyfikacja parametru _' unless probe.map { |r| r[:msgid] } == ['probe'] && warnings.empty?
    {files: files, messages: records.values, warnings: warnings}
  end
end
