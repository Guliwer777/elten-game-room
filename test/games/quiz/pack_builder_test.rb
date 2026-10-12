require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"


def assert(condition, message)
  raise message if !condition
end

Dir.mktmpdir("quiz-pack-builder") do |directory|
  root = File.expand_path(directory)
  content = File.join(root, "content")
  library = File.join(root, "lib")
  FileUtils.mkdir_p(content)
  FileUtils.mkdir_p(library)

  File.write(
    File.join(library, "game_content.rb"),
    "module GameRoomContent\n" \
      "  class Pack\n" \
      "    def initialize(**values); values[:loader]&.call; end\n" \
      "  end\n" \
      "  class Registry\n" \
      "    def register_pack(_pack); end\n" \
      "  end\n" \
      "  def self.registry; @registry ||= Registry.new; end\n" \
      "end\n",
    encoding: "utf-8"
  )

  prompt_marker = File.join(root, "prompt-injection")
  source_marker = File.join(root, "source-injection")
  title_marker = File.join(root, "title-injection")
  input = File.join(root, "questions.json")
  output = File.join(content, "quiz_test.rb")
  prompt = "\#{File.write(#{prompt_marker.inspect}, 'executed')}"
  source = "trusted source\nFile.write(#{source_marker.inspect}, 'executed')"
  title = "Security\nFile.write(#{title_marker.inspect}, 'executed')"
  File.write(
    input,
    JSON.generate([
      {
        "category" => "security",
        "level" => "medium",
        "prompt" => prompt,
        "correct" => "safe",
        "wrong" => ["one", "two", "three"]
      }
    ]),
    encoding: "utf-8"
  )

  builder = File.expand_path("../../../tools/build-quiz-pack.rb", __dir__)
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby,
    builder,
    "--json", input,
    "--out", output,
    "--set-id", "quiz.security",
    "--pack-id", "quiz.security.en",
    "--title", title,
    "--language", "en",
    "--source", source
  )
  assert(status.success?, "the builder failed: #{stdout} #{stderr}")

  load_stdout, load_stderr, load_status = Open3.capture3(RbConfig.ruby, output)
  assert(load_status.success?, "the generated pack did not load: #{load_stdout} #{load_stderr}")
  assert(!File.exist?(prompt_marker), "question text executed Ruby interpolation")
  assert(!File.exist?(source_marker), "a source line escaped its generated comment")
  assert(!File.exist?(title_marker), "a title line escaped its generated comment")
end

puts "Quiz pack builder tests passed"

# Translated metadata uses the application catalogue and preserves checksums.
require "tmpdir"
require "ripper"
require_relative "../../../tools/support/quiz_pack_writer"

[['en', 'General knowledge'], ['pl-PL', 'General knowledge'],
  ['ru-RU', 'General knowledge'], ['pl-PL', 'Witcher — books']].each do |language, title|
  metadata = { id: "localization.test.#{language}", set_id: "localization.test", kind: "quiz",
    language_id: language, version: 1, title: title, game_ids: ["quiz"] }
  Dir.mktmpdir("game-room-locale-writer-") do |directory|
    path = File.join(directory, "pack.rb")
    questions = [{ id: "test", question: "Test?", answer: "Yes" }]
    pack = QuizPackWriter.write(path, metadata, questions, translated: true)
    plain = QuizPackWriter.write(File.join(directory, "plain.rb"), metadata, questions, translated: false)
    source = File.read(path, encoding: "UTF-8")
    raise "generated pack titles still use the host translator" unless source.include?("title: GameRoomLocalization.translate(#{JSON.generate(title)})")
    raise "generated packs do not load their translator" unless source.include?('require_relative "../lib/game_room_localization"')
    raise "generated packs moved the encoding header" unless source.start_with?("# encoding: UTF-8\n")
    raise "generated pack syntax is invalid" unless Ripper.sexp(source)
    raise "translated titles changed the content checksum" unless source.include?(pack.checksum) && pack.checksum == plain.checksum
    raise "translated titles changed question data" unless pack.data == plain.data
    raise "translated titles changed language or identity" unless pack.language_id == plain.language_id && pack.id == plain.id
  end
end
puts "Generated translated pack titles use the independent interface catalog"
