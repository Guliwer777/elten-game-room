require_relative "../../tools/translations"
require_relative "../../lib/game_room_localization"
require_relative "../../games/base"
require_relative "../../games/chess"
require_relative "../../tools/compile-rulebooks"
require_relative "../../tools/support/release_files"

root = File.expand_path("../..", __dir__)
catalog_tools = GameRoomTranslationCatalog
po = catalog_tools.read_po(File.join(root, 'locale/RU.po'))
catalog_tools.validate!(po)
catalog_tools.compile_file(File.join(root, 'locale/RU.po'), File.join(root, 'locale/RU.mo'), check: true)
messages = catalog_tools.message_map(po)
raise 'Russian catalogue lost its original messages' unless messages.length > 4949
headers = catalog_tools.metadata(po)
raise 'Wrong language' unless headers['Language'] == 'ru'
raise 'Russian needs three plural forms' unless headers['Plural-Forms'].start_with?('nplurals=3;')

forbidden_yo_spellings = /\b(?:ее|партнер(?:а|ов|ы|ом|ами)?|счет(?:а|ов|ом|у|е|ный)?|подсчет(?:а|ов|ом|у|е)?|отсчет(?:а|ов|ом|у|е)?|объем(?:а|ов|ом|у|е)?|трех|четырех|все еще|все равно)\b/i
po.each do |entry|
  next if entry.obsolete? || entry.header?
  raise "Reviewed translation is fuzzy: #{entry.msgid}" if entry.fuzzy?
  raise "Obsolete review marker: #{entry.msgid}" if entry.extracted_comment.to_s.include?('Требует проверки.')
  raise "Russian translation omits ё: #{entry.msgid}" if entry.msgstr.to_s.match?(forbidden_yo_spellings)
end

# The complete Russian rulebooks replace the old bilingual paragraphs.
# They are embedded directly, not looked up through the PO. Validate those
# authored/compiled editions; do not require unused drafts in the catalogue.
raise 'Stale authored rulebooks' unless GameRoomRulebookCompiler.run(root: root, check: true).empty?
localized_books = Dir.glob('*.json', base: File.join(root, 'tools/data/rulebooks/RU')).map { |name| File.basename(name, '.json') }

# Use the same AST extractor and context-aware PO parser as the compiler.
# Comparing plain msgid strings would mix the regular and cat_head_tail texts.
release_sources = GameRoomReleaseFiles.files(root).grep(/\.rb\z/).to_h { |path| [path, true] }
raise 'Release source list is incomplete' unless release_sources['__app.rb'] && release_sources['lib/tournaments/shared_hub.rb']
GameRoomTranslationExtractor.extract(root).each do |message|
  # Local tournament laboratories are intentionally absent from the installer.
  # Every message used by any shipped source remains mandatory, including those
  # shared with the laboratories. The allowlist comes from the actual packager.
  next unless message[:references].any? { |reference| release_sources[reference.sub(/:\d+\z/, '')] }
  entry = po[message[:msgctxt], message.fetch(:msgid)]
  raise "Missing Russian source message: #{message.inspect}" unless entry && !entry.obsolete? && !entry.fuzzy?
  if entry.msgstr.to_s.delete("\0").empty?
    replaced_rule = !message[:references].empty? && message[:references].all? do |reference|
      match = %r{\Agames/generated/rulebooks/([a-z0-9_]+)\.rb:\d+\z}.match(reference)
      match && localized_books.include?(match[1])
    end
    raise "Missing translation: #{entry.msgid}" unless replaced_rule
  end
  if message[:msgid_plural]
    raise "Lost plural: #{message.inspect}" unless entry.msgid_plural == message[:msgid_plural]
  end
end
banked = '%{player} banked %{points} points and now has %{total}.'
raise 'Plain banking entry lost' unless messages.key?(banked)
raise 'Context banking entry lost' unless messages.key?("cat_head_tail\004#{banked}")

manifest = JSON.parse(File.read(File.join(root, 'manifest.json'), encoding: 'UTF-8'))
embedded = File.read(File.join(root, '__app.rb'), encoding: 'UTF-8').match(/=begin Elten3AppInfo\s*(.*?)\s*=end Elten3AppInfo/m)[1]
embedded = JSON.parse(embedded)
%w[supported_languages localized_descriptions version build_id].each do |key|
  raise "Manifests disagree: #{key}" unless manifest[key] == embedded[key]
end
raise 'Russian not registered' unless manifest.fetch('supported_languages').include?('ru')
raise 'Missing Russian description' if manifest.fetch('localized_descriptions').fetch('ru').empty?

GameRoomLocalization.boot(directory: File.join(root, 'locale'), host_language: 'en',
  settings: {'interface_language' => 'ru', 'known_languages' => ['ru']})
{'yellow' => 'жёлтый', 'green' => 'зелёный', 'black queen' => 'чёрный ферзь',
 'queen' => 'дама', 'Russian' => 'Русский'}.each do |original, expected|
  raise "Incorrect Russian translation: #{original}" unless GameRoomLocalization.translate(original) == expected
end
chess = GameRoomGames::Chess.new
raise 'Chess promotion uses card terminology' unless chess.send(:translated_piece_name, 'Q') == 'ферзь'
raise 'Chess context lookup failed' unless GameRoomLocalization.translate('queen', context: 'chess') == 'ферзь'
raise 'Categories river context failed' unless GameRoomLocalization.translate('River', context: 'categories') == 'Река'
raise 'Poker river context failed' unless GameRoomLocalization.translate('River', context: 'poker') == 'Ривер'

singular = 'There is currently %{current} user at the table.'
plural = 'There are currently %{current} users at the table.'
{0=>'пользователей', 1=>'пользователь', 2=>'пользователя', 5=>'пользователей',
 11=>'пользователей', 21=>'пользователь', 22=>'пользователя'}.each do |count, ending|
  actual = GameRoomLocalization.translate(singular, plural: plural, count: count) % {current: count}
  raise "Wrong Russian plural for #{count}: #{actual}" unless actual == "Сейчас за столом #{count} #{ending}."
end
GameRoomLocalization.boot(directory: File.join(root, 'locale'), host_language: 'en',
  settings: {'interface_language' => 'en', 'known_languages' => ['en']})
raise 'English chess label changed unnecessarily' unless chess.send(:translated_piece_name, 'Q') == 'queen'

puts "Russian: context-aware PO/MO, current source coverage, review status, spelling, plurals, manifests and real chess translation passed (#{messages.length - 1} messages)"
