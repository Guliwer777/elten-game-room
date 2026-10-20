# frozen_string_literal: true
require_relative 'base'

module GameRoomGames
  # The catalog book owns all languages; internal adapters select chapters
  # from the same source instead of maintaining duplicate translated books.
  module MahjongRules
    def rule_sections
      mahjong_select_rule_sections(generated_rule_sections)
    end

    def localized_rule_sections
      sections = super
      sections && mahjong_select_rule_sections(sections)
    end

    private

    def mahjong_rulebook_scope; :all; end

    def mahjong_select_rule_sections(sections)
      scope = mahjong_rulebook_scope
      return sections if scope == :all
      sections.select { |section| section.id == :controls || section.id.to_s.start_with?('table_') == (scope == :table) }
    end
  end
end
require_relative 'generated/rulebooks/mahjong'
