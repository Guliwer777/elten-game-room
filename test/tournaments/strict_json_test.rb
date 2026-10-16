# encoding: UTF-8
require 'json'
require_relative '../support/assertions'
require_relative '../../lib/tournaments/publication'
require_relative '../../games/catalog'
source = File.expand_path('../../lib/tournaments/strict_json.rb', __dir__)
require source if File.file?(source)

# Emulacja parsera ignorującego oba zabezpieczenia musi zakończyć się
# fail-closed, niezależnie od wersji rzeczywistej biblioteki.
module TournamentStrictJsonProbe
  def parse(source, **options)
    options = options.merge(allow_duplicate_key: true, object_class: Hash) if Thread.current[:ignore_duplicate_option]
    super(source, **options)
  end
end
JSON.singleton_class.prepend(TournamentStrictJsonProbe)
include GameRoomTest::Assertions
puts JSON.generate(ruby: RUBY_VERSION, platform: RUBY_PLATFORM, json: JSON::VERSION,
  parser: JSON.parser.name, json_source: $LOADED_FEATURES.find { |file| file.end_with?('/json/version.rb') })
assert(defined?(GameRoomTournaments::StrictJson), 'Brak wspólnego ścisłego parsera')
parser = GameRoomTournaments::StrictJson
assert_equal({ 'a' => [{ 'key' => 1 }, { 'key' => 2 }] }, parser.parse('{"a":[{"key":1},{"key":2}]}', max_nesting: 8))
mutable = parser.parse('{"a":[{"key":1}]}', max_nesting: 8)
mutable['a'].first['key'] = 2
assert_equal({ 'a' => [{ 'key' => 2 }] }, mutable)
['{"key":1,"key":1}', '{"key":0,"key":1}', '{"key":1,"\\u006bey":1}',
  '{"a":[{"b":{"key":null,"key":1}}]}'].each do |source|
  assert_raises(JSON::ParserError) { parser.parse(source, max_nesting: 8) }
end
assert_raises(JSON::NestingError) { parser.parse('{"a":[{"b":1}]}', max_nesting: 2) }
assert_raises(JSON::ParserError) { parser.parse('{', max_nesting: 8) }
begin
  Thread.current[:ignore_duplicate_option] = true
  assert_raises(parser::IncompatibleRuntime) { parser.parse('{"key":1}', max_nesting: 8) }
  row = { 'publication_key' => 'probe', '__id' => 1, '__insertion_user' => 'Test',
    '__insertion_time' => 90, 'settings_json' => '{}', 'schedule_json' => '{}' }
  result = GameRoomTournaments::Publication.project(rows: [row], registry: GameRoomGames::CATALOG, complete: true)
  assert_equal([], result['announcements'])
  assert_equal(['incompatible_runtime'], result['diagnostics'].map { |item| item['code'] })
ensure
  Thread.current[:ignore_duplicate_option] = nil
end
assert_equal({ 'key' => 1 }, parser.parse('{"key":1}', max_nesting: 8))
puts 'PASS strict JSON: real duplicate rejection, escaped/nested keys, fail-closed and nesting budget'
