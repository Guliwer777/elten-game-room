# encoding: UTF-8
# Pomocniki tylko do izolowanych testów: bez źródeł tłumaczeń w tmp,
# bez GUI, profilu, sieci, wyjścia dźwiękowego i globalnej normalizacji tekstu.
require 'json'
require 'open3'
require 'rbconfig'

module TournamentLocalTestLanguage
  ROOT = File.expand_path('../..', __dir__)
  ACTOR = 'Testowa Żaneta'.freeze
  module_function

  def check(value, message)
    raise message unless value
  end

  def equal(expected, actual, message)
    check(expected == actual, "#{message}: oczekiwano #{expected.inspect}, otrzymano #{actual.inspect}")
  end

  def messages
    require File.join(ROOT, 'tools/support/translation_extractor')
    warnings, records = [], {}
    paths = Dir.glob('lib/tournaments/**/*.rb', base: ROOT).sort
    check(!paths.empty?, 'Brak źródeł turniejów')
    paths.each do |path|
      GameRoomTranslationExtractor.extract_source(File.read(File.join(ROOT, path), encoding: 'UTF-8'),
        path: path, warnings: warnings).each do |message|
        GameRoomTranslationExtractor.merge_record(records, **message)
      end
    end
    check(warnings.empty?, "Niepełna ekstrakcja AST: #{warnings.inspect}")
    records.values
  end

  # Jak binarny loader istniejących testów, lecz bez importu lekkich kontrolek.
  # Obsługuje wyłącznie require_relative do produkcji tego checkoutu.
  module NativeSources
    @loaded = {}
    class << self
      attr_reader :loaded
      def load(path)
        return false if @loaded.key?(path) || $LOADED_FEATURES.include?(path)
        source = File.binread(path)
        @loaded[path] = source.encoding
        TOPLEVEL_BINDING.eval(source, path, 1)
        true
      end
    end
    module Requires
      def require_relative(name)
        origin = File.expand_path(caller_locations(1, 1).first.path)
        path = File.expand_path(name, File.dirname(origin))
        path += '.rb' unless path.end_with?('.rb')
        root = TournamentLocalTestLanguage::ROOT
        if origin.start_with?(root + '/') && path.start_with?(root + '/lib/', root + '/games/')
          return TournamentLocalTestLanguage::NativeSources.load(path)
        end
        require File.expand_path(name, File.dirname(origin))
      end
      private :require_relative
    end
  end

  def boot_native(language)
    require File.join(ROOT, 'test/support/tournament_native')
    require File.join(ROOT, 'test/support/localization')
    Object.send(:remove_method, :_)
    Object.send(:remove_method, :p_)
    require EltenTestHost.file('src/eapi/dictionary.rb')
    Object.include(EltenAPI)
    Configuration.language = language == 'pl' ? 'en-GB' : 'pl-PL'
    # Host normalnie inicjalizuje metadane języków przy starcie; bez zasobów/profilu.
    EltenAPI::Structs::Lists.langs = {'en' => {'nativeName' => 'English'}}
    host = Object.new
    host.send(:loadmo, language == 'pl' ? '' : File.binread(EltenTestHost.file('locale/pl-PL/LC_MESSAGES/elten.mo')))
    equal(EltenAPI::Dictionary, host.method(:_).owner, 'Zastąpiono natywny słownik')
    equal(language == 'pl' ? 'Cancel' : 'Anuluj', host.send(:_, 'Cancel'), 'Język hosta')
    before = host_snapshot
    fixture = GameRoomTestLocalization.runtime(language, files: {'pl' => File.join(ROOT, 'locale/PL.mo')})
    GameRoomLocalization.boot(runtime: fixture)
    equal(language, GameRoomLocalization.primary_language, 'Język aplikacji nie pochodzi z ustawień')
    Kernel.prepend(NativeSources::Requires)
    NativeSources.load(File.join(ROOT, 'lib/tournaments/hub.rb'))
    NativeSources.load(File.join(ROOT, 'lib/tournaments/local_test_hub.rb'))
    NativeSources.load(File.join(ROOT, 'games/catalog.rb'))
    equal(before, host_snapshot, 'Boot zmienił słownik hosta')
    [host, before, fixture]
  end

  def host_snapshot
    dictionary = EltenAPI::Dictionary
    names = dictionary.const_defined?(:Catalogs, false) ? [:Catalogs, :Docs, :Languages] :
      [:DictCache, :Docs, :Params, :Sources, :Translations, :Languages]
    [Configuration.language, Marshal.dump(names.map { |name| dictionary.const_get(name) }),
      [:_, :p_, :n_, :np_].map { |name| Object.instance_method(name) }]
  end

  def draft
    {'id' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'revision' => 7,
      'name' => 'Szkic — Łódź', 'game_id' => 'chess', 'game_options' => {'bot_delay' => 3},
      'format' => 'round_robin', 'rematch' => false, 'players_per_match' => 2,
      'pairing' => 'all_combinations', 'participants' => ['Lokalna A', 'Lokalna B'],
      'windows' => [{'date' => '2026-10-15', 'start' => '18:00', 'end_date' => '2026-10-15', 'end' => '21:00'}]}
  end

  def snapshot
    g = GameRoomTournaments
    row = g::Publication.from_draft(draft: draft, registry: GameRoomGames::CATALOG,
      publication_key: 'language-test', rules: 'Graj uczciwie. Żółć.',
      registration_opens_at: 100, registration_closes_at: 200, timezone: 'local_test:system').to_row.merge(
        '__id' => 11, '__insertion_user' => 'Organizator Łukasz', '__insertion_time' => 90)
    g::RegistrationProjection.build(announcements: [row], registrations: [],
      registry: GameRoomGames::CATALOG, complete: true).to_h
  end

  def field(form, header)
    form.fields.find { |control| control.respond_to?(:header) && control.header == header } || raise("Brak pola: #{header}")
  end

  def button(form, label)
    form.fields.find { |control| control.is_a?(Button) && control.label == label } || raise("Brak przycisku: #{label}")
  end

  def action(driver, header, label)
    driver.step(header, [13]) do |form|
      control = form.fields.find { |field| field.is_a?(Button) && field.label == label }
      unless control
        control = form.fields.grep(ListBox).find { |field| field.options.include?(label) }
        raise "Missing action: #{label}" unless control
        control.index = control.options.index(label)
      end
      form.index = form.fields.index(control)
    end
  end

  def read_form(form)
    form.fields.each_with_index do |control, index|
      next if control.nil?
      texts = []
      texts << control.header if control.respond_to?(:header)
      texts << control.label if control.is_a?(Button)
      texts.concat(control.options) if control.is_a?(ListBox)
      texts << control.text if control.is_a?(EditBox)
      texts.compact.each do |value|
        check(value.encoding == Encoding::UTF_8 && value.valid_encoding?, "Błędne kodowanie kontrolki: #{value.inspect}")
      end
      form.index = index
      speech, braille = SpeechOutput.calls.length, NVDA.calls.length
      form.focus
      check(SpeechOutput.calls.length > speech && NVDA.calls.length > braille, 'Brak natywnego odczytu mowy/brajla')
      [SpeechOutput.calls.last.first, NVDA.calls.last.first].each do |value|
        check(value.valid_encoding?, 'Błędne kodowanie odczytu')
      end
    end
    form.index = 0
    form.focus
  end

  def fill_dates(form, language)
    %w[closes].each do |kind|
      pl = 'Koniec zapisów'
      parts = language == 'pl' ? %w[rok miesiąc dzień godzina minuta] : %w[year month day hour minute]
      [2026, 10, 2, 12, 0].zip(parts).each_with_index do |(value, part), position|
        header = language == 'pl' ? "#{pl}: #{part}" : "Registration #{kind}: #{part}"
        control = field(form, header)
        check(control.is_a?(EltenAPI::Controls::ListBox), 'Data nie jest natywnym wybierakiem')
        control.index = control.options.index(format(position.zero? ? '%04d' : '%02d', value)) || raise('Brak daty')
        control.trigger(:move)
      end
    end
  end
end
