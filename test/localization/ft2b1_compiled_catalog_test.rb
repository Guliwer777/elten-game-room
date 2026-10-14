# encoding: UTF-8
require_relative '../../tools/translations'
require_relative '../support/tournament_ft2b1_localization_inventory'
require_relative '../../lib/game_room_localization'
f = TournamentFT2B1LocalizationInventory
inventory = f.collect
po = GameRoomTranslationCatalog.read_po(File.join(f::ROOT, 'locale/PL.po'))
GameRoomTranslationCatalog.validate!(po)
mo = GetText::MO.open(File.join(f::ROOT, 'locale/PL.mo')).to_h
catalog = GameRoomLocalization::Catalog.new(File.binread(File.join(f::ROOT, 'locale/PL.mo')))
base = ENV['FT2_SCRATCH'] && GameRoomTranslationCatalog.read_po(File.join(ENV.fetch('FT2_SCRATCH'), 'before/locale/PL.po'))
rows = inventory[:messages].map do |record|
  id, context, plural = record.values_at(:msgid, :msgctxt, :msgid_plural)
  key = [context, id].compact.join("\004") + (plural ? "\0#{plural}" : '')
  # MO porównujemy po dokładnych bajtach klucza, a API katalogu po UTF-8.
  raw_key = mo.keys.find { |k| k.b == key.b }
  entry = po[context, id]
  result = record.merge(new: base ? base[context, id].nil? : nil,
    compiled: raw_key && mo[raw_key].dup.force_encoding('UTF-8'), key_encoding: raw_key&.encoding&.name,
    flags: entry&.flags, obsolete: entry&.obsolete?, po: entry&.msgstr)
  result[:valid] = !!(entry && !entry.fuzzy? && !entry.obsolete? && raw_key &&
    !mo[raw_key].empty? && mo[raw_key].b == entry.msgstr.b &&
    catalog.translate(id, context: context) == entry.msgstr.split("\0").first)
  if plural
    [1, 2, 5, 12, 22].each { |n| result[:valid] &&= !catalog.translate(id, context: context, count: n).to_s.empty? }
  end
  result
end
result = inventory.merge(messages: rows, counts: {all: rows.size, new: rows.count { |r| r[:new] }, missing: rows.count { |r| !r[:valid] }})
File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'inventory.json'), JSON.pretty_generate(result)) if ENV['ENTRY_EVIDENCE']
missing = rows.reject { |r| r[:valid] }
puts JSON.generate(result[:counts])
raise "Brak ścisłego compiled PL: #{missing.map { |r| r[:msgid] }.inspect}" unless missing.empty?
puts 'PASS: wszystkie komunikaty całych zmienionych plików w compiled PL'
