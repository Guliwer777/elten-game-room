require 'json'

module GameRoomTest
  # Complete authored editions, not the older translation-key catalogue.
  # Missing-translation runtimes use the complete English edition too.
  module Rulebooks
    ROOT = File.expand_path('../..', __dir__)
    module_function

    def language(value)
      %w[fallback missing_translation].include?(value.to_s) ? 'en' : value.to_s
    end

    def read(id, locale, root: ROOT)
      key = language(locale)
      JSON.parse(File.read(File.join(root, 'tools/data/rulebooks', key.upcase, "#{id}.json"), encoding: 'UTF-8'))
    end

    def sections(id, locale, root: ROOT)
      read(id, locale, root: root).fetch('sections')
    end

    def paragraphs(id, locale, root: ROOT)
      key = language(locale)
      sections(id, locale, root: root).flat_map { |section| section.fetch('paragraphs').map { |pair| pair.fetch(key) } }
    end
  end
end
