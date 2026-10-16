require_relative "../support/host_source"
host_source = EltenTestHost.root

require_relative "../support/game_room_language_runtime"
GameRoomLanguageRuntime.load_host(File.expand_path(host_source))

$language_assertions = 0
$language_results = []

def assert(condition, message)
  $language_assertions += 1
  raise message unless condition
end

def assert_equal(expected, actual, message)
  assert(expected == actual, "#{message}: expected #{expected.inspect}, got #{actual.inspect}")
end

def test(name)
  GameRoomLanguageRuntime::WAITED_FORMS.clear
  yield
  $language_results << [name, true]
  puts "PASS #{name}"
rescue StandardError, ScriptError => error
  $language_results << [name, false]
  warn "FAIL #{name}: #{error.class}: #{error.message}\n#{error.backtrace.first(5).join("\n")}"
end

def install_host(root, language)
  Configuration.language = language
  host = Object.new
  if language == "pl-PL"
    host.send(:loadmo, File.binread(File.join(root, "locale/pl-PL/LC_MESSAGES/elten.mo")))
    host.send(:loadmo, File.binread(File.join(GameRoomLanguageRuntime::ROOT, "locale/PL.mo")), false)
  else
    host.send(:loadmo, "")
  end
  assert_equal(EltenAPI::Dictionary, host.method(:_).owner, "The host translation is not the real dictionary")
  assert_equal(language == "pl-PL" ? "Anuluj" : "Cancel", host.send(:_, "Cancel"), "The host locale was not established")
  host
end

def start_app(primary, known: [primary], catalogs: {})
  settings = primary ? { "interface_language" => primary, "known_languages" => known } : {}
  GameRoomLanguageRuntime::Runtime.new(settings: settings, catalogs: catalogs).start
end

test("host protection still detects direct native dictionary changes") do
  install_host(host_source, "pl-PL")
  dictionary = EltenAPI::Dictionary
  current_catalogs = dictionary.const_defined?(:Catalogs, false)
  entries = dictionary.const_get(current_catalogs ? :Catalogs : :Translations)
  mutex = current_catalogs ? dictionary.const_get(:CatalogMutex) : Mutex.new
  saved = mutex.synchronize { entries.dup }
  before = GameRoomLanguageRuntime.host_snapshot
  detected = nil
  begin
    begin
      GameRoomLanguageRuntime.protect_host { mutex.synchronize { entries.clear } }
    rescue RuntimeError => error
      detected = error.message
    end
    assert_equal("Game Room modified the host dictionary, language or translation methods", detected,
      "Host protection ignored a direct dictionary mutation")
  ensure
    mutex.synchronize { entries.replace(saved) }
  end
  assert_equal(before, GameRoomLanguageRuntime.host_snapshot, "Guard regression did not restore the host dictionary")
end

def verify_real_ui(runtime, language)
  ns = runtime.namespace
  app = ns.const_get(:EltenGameRoom, false)
  assert_equal(nil, Programs.current_runtime, "Runtime leaked beyond source evaluation")
  assert_equal(false, Object.const_defined?(:EltenGameRoom, false), "Production classes escaped their runtime namespace")
  assert_equal([Encoding::ASCII_8BIT], runtime.source_encodings.uniq, "Sources bypassed the binary runtime boundary")
  assert_equal(["settings.json"], runtime.settings_reads, "Saved language was not read once before constants were built")
  expected_menu = if language == "pl"
    ["Utwórz nowy stół", "Dołącz do stołu", "Zapisane gry", "Turnieje", "Tworzenie własnych zestawów pytań do quizu", "Rankingi", "Statystyki", "Ustawienia", "Zasady gry", "README", "Co nowego"]
  else
    ["Create a new table", "Join a table", "Saved games", "Tournaments", "Create your own quiz question sets", "Leaderboards", "Statistics", "Settings", "Game rules", "README", "What's new"]
  end
  assert_equal(expected_menu, app::MAIN_OPTIONS, "Host locale overrode the actual MAIN_OPTIONS constant")
  chess = app::GAME_REGISTRY.build("chess")
  assert_equal(language == "pl" ? "Szachy" : "Chess", chess.name, "Host locale overrode the real Chess name")
  source_rules = JSON.parse(File.read(File.join(GameRoomLanguageRuntime::ROOT, "tools/data/rulebooks/#{language.upcase}/chess.json"), encoding: "UTF-8")).fetch("sections")
  sections = chess.rule_book.sections
  source_rules.each do |section|
    actual = sections.find { |item| item.id.to_s == section.fetch("id") }
    assert(actual, "Chess lost the #{section.fetch('id')} section")
    assert_equal(section.fetch("title").fetch(language), actual.title, "Chess rule heading used the wrong locale")
    assert_equal(section.fetch("paragraphs").map { |paragraph| paragraph.fetch(language) }, actual.paragraphs, "Chess rules used the wrong locale")
  end
  documents = chess.rule_book(options: chess.default_options).documents
  assert_equal(language == "pl" ? "Zasady" : "Rules", documents.first.title, "The shared rules document ignored the app locale")

  cat = app::GAME_REGISTRY.build("cat_head_tail")
  replay = cat.replay({ "__players" => %w[Alice Bob], "options" => JSON.generate(cat.default_options) }, [], ns::GameRoomSavedGameArchive::ReplayRepository.new)
  cards = cat.surface_spec(replay, "Alice").zones.first.cards
  assert_equal(language == "pl" ? "Rzuć kością" : "Roll", cards.find { |card| card.id == "roll" }.label, "CatHeadTail's context wrapper bypassed app localization")
  assert_equal(language == "pl" ? "Zapisz 0 punktów" : "Bank 0 points", cards.find { |card| card.id == "bank" }.label, "CatHeadTail lost its uncontexted framework fallback")

  quiz = app::GAME_REGISTRY.build("quiz")
  expected_counts = language == "pl" ? ["1 pytanie", "2 pytania", "5 pytań", "22 pytania"] : ["1 question", "2 questions", "5 questions", "22 questions"]
  assert_equal(expected_counts, [1, 2, 5, 22].map { |count| quiz.send(:question_count_text, count) }, "Real Quiz Party plural labels ignored the app language")
  content = ns::GameRoomContent.registry
  assert_equal(language == "pl" ? "Angielski" : "English", content.language("en").label, "Load-time English content-language label used the host locale")
  assert_equal(language == "pl" ? "Polski" : "Polish", content.language("pl-PL").label, "Load-time Polish content-language label used the host locale")
  pack = content.pack("quiz.general.en")
  assert_equal(language == "pl" ? "Wiedza ogólna" : "General knowledge", pack.title, "Load-time content-pack title used the host locale")
  assert_equal("en", pack.language_id, "Interface locale changed the shared content language")
  assert_equal(false, pack.verified?, "Locale startup eagerly loaded game content")

  worker = Object.new
  def worker.closed?; false; end
  widget = ns::GameRoomWidget::TableList.new(loader: -> { [] }, opener: ->(_) {}, labeler: ->(_) { "" }, id_for: ->(_) { 0 }, worker: worker)
  assert_equal(language == "pl" ? "Stoły Power Games" : "Power Games tables", widget.header, "Widget label required a current runtime")
  assert_equal(language == "pl" ? "Wczytywanie stołów Power Games" : "Loading Power Games tables", widget.empty_label, "Widget loading label required a current runtime")

  form = ns::GameRoomUI::Form.new([ListBox.new(["a"], header: "field")], quiet: true)
  callback = form.game_room_hotkey_action(1)
  assert_equal(nil, Programs.current_runtime, "The callback was tested with a current runtime")
  callback.call
  help = GameRoomLanguageRuntime::WAITED_FORMS.last
  assert(help, "The real F1 callback never constructed a help form")
  assert_equal(language == "pl" ? "Skróty klawiszowe" : "Keyboard shortcuts", help.fields.first.header, "Deferred F1 help used the host locale")
  texts = app::MAIN_OPTIONS + sections.flat_map { |section| [section.title] + section.paragraphs } + cards.map(&:label) + [help.fields.first.header, help.fields.first.text, widget.header, widget.empty_label]
  assert(texts.all? { |text| text.encoding == Encoding::UTF_8 && text.valid_encoding? }, "Binary loading produced invalid or non-UTF-8 UI text")
  assert_equal(["settings.json"], runtime.settings_reads, "Runtime callbacks reread language settings")
end

[["pl-PL", "en"], ["en-GB", "pl"]].each do |host_language, app_language|
  test("host #{host_language} / app #{app_language}: real constants, Chess rules, Cat context, plurals, content and deferred F1") do
    host = install_host(host_source, host_language)
    GameRoomLanguageRuntime.protect_host do
      runtime = start_app(app_language, known: %w[en pl])
      verify_real_ui(runtime, app_language)
      assert_equal(host_language == "pl-PL" ? "Anuluj" : "Cancel", host.send(:_, "Cancel"), "App changed native host labels")
    end
  end
end

[["pl-PL", "pl"], ["en-GB", "en"]].each do |host_language, app_language|
  test("missing preference follows #{host_language} at startup") do
    install_host(host_source, host_language)
    GameRoomLanguageRuntime.protect_host do
      verify_real_ui(start_app(nil), app_language)
    end
  end
end

czech_fixture = GameRoomLanguageRuntime.synthetic_catalog({
  "Create a new table" => "Vytvořit stůl",
  "Settings" => "Nastavení",
  "%{count} question\0%{count} questions" => "%{count} otázka\0%{count} otázky\0%{count} otázek",
  "runtime-fixture\u0004Token" => "Žeton",
  "runtime-fixture\u0004token\0tokens" => "žeton\0žetony\0žetonů",
  "Only in the synthetic Czech fixture — ž" => "Pouze v české testovací sadě — ž"
})
unknown_fixture = GameRoomLanguageRuntime.synthetic_catalog({ "Game rules" => "UNKNOWN LANGUAGE MUST NOT BE USED" }, name: "Synthetic unknown language")

test("future Czech MO is independent of host resources and falls back only to known languages") do
  install_host(host_source, "en-GB")
  GameRoomLanguageRuntime.protect_host do
    runtime = start_app("cs", known: %w[cs en pl], catalogs: { "cs" => czech_fixture, "zz" => unknown_fixture })
    ns = runtime.namespace
    app = ns::EltenGameRoom
    assert(EltenAPI::Dictionary::Languages.none? { |language| language.realcode.downcase.start_with?("cs") }, "Czech fixture leaked into the host languages")
    assert(ns::GameRoomLocalization.available_languages.include?({ id: "cs", label: "Čeština" }), "New catalog needs a host language registration")
    assert_equal("Vytvořit stůl", app::MAIN_OPTIONS.first, "Primary Czech catalog was not used for a real constant")
    assert_equal("Nastavení", app::MAIN_OPTIONS[7], "Primary translation was replaced by fallback")
    assert_equal("Zasady gry", app::MAIN_OPTIONS[8], "Missing primary label ignored known Polish or used an unknown language")
    assert_equal("Szachy", app::GAME_REGISTRY.build("chess").name, "Missing primary game name did not use known Polish")
    quiz = app::GAME_REGISTRY.build("quiz")
    assert_equal(["1 otázka", "2 otázky", "5 otázek", "22 otázek"], [1, 2, 5, 22].map { |count| quiz.send(:question_count_text, count) }, "Actual game used host rather than Czech plurals")
    assert_equal("Pouze v české testovací sadě — ž", ns::GameRoomRules.translate("Only in the synthetic Czech fixture — ž".b), "Binary non-ASCII translation key was missed")
    missing = "Missing from every catalog — żółw"
    assert_equal(missing, ns::GameRoomRules.translate(missing.b), "Missing translation did not preserve the English source")
    assert_equal(Encoding::UTF_8, ns::GameRoomRules.translate(missing.b).encoding, "Missing non-ASCII source fallback was left binary")

    runtime.backend.evaluate(<<~RUBY.b, "<test-only-context-api-probe>", 1)
      module ContextApiProbe
        using GameRoomLocalization::Translations
        def self.singular; p_("runtime-fixture", "Token"); end
        def self.plural(count); np_("runtime-fixture", "token", "tokens", count); end
        def self.missing(count); np_("other-context", "token", "tokens", count); end
      end
    RUBY
    assert_equal("Žeton", ns::ContextApiProbe.singular, "Real p_ refinement ignored context")
    assert_equal(["žeton", "žetony", "žetonů"], [1, 2, 5].map { |count| ns::ContextApiProbe.plural(count) }, "Real np_ refinement lost catalog plural rules")
    assert_equal("tokens", ns::ContextApiProbe.missing(2), "Context leaked into unrelated plural fallback")
    assert_equal(nil, Programs.current_runtime, "Context API probe relied on a current runtime")
  end
end

test("missing Czech labels stay English when Polish is not known") do
  install_host(host_source, "pl-PL")
  GameRoomLanguageRuntime.protect_host do
    runtime = start_app("cs", known: ["cs"], catalogs: { "cs" => czech_fixture, "zz" => unknown_fixture })
    app = runtime.namespace::EltenGameRoom
    assert_equal("Vytvořit stůl", app::MAIN_OPTIONS.first, "Czech catalog did not load")
    assert_equal("Game rules", app::MAIN_OPTIONS[8], "Fallback used an unknown catalog or host Polish")
    assert_equal("Chess", app::GAME_REGISTRY.build("chess").name, "Fallback inherited host Polish")
  end
end

test("full reload changes locale without changing an already loaded runtime") do
  install_host(host_source, "pl-PL")
  GameRoomLanguageRuntime.protect_host do
    english = start_app("en")
    polish = start_app("pl")
    verify_real_ui(english, "en")
    verify_real_ui(polish, "pl")
    Programs.with_runtime(polish) do
      assert_equal("Chess", english.namespace::EltenGameRoom::GAME_REGISTRY.build("chess").name, "Another active runtime overrode an older runtime's lexical locale")
    end
  end
end

passed = $language_results.count { |_name, success| success }
puts "Game Room language runtime: #{passed}/#{$language_results.length} scenarios passed; #{$language_assertions} assertions; offline actual host backend/dictionary and binary Game Room sources"
exit(passed == $language_results.length ? 0 : 1)
