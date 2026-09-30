# frozen_string_literal: true

require "ffi"

module ZXingFFI
  # Finds a compatible libZXing and checks its version and required symbols.
  #
  # Candidates, in order (the first one that loads and passes the checks wins):
  # 1. +ZXingFFI.config.library_path+ / +ENV["ZXING_LIB"]+ — authoritative: when set, nothing else is tried.
  # 2. The library bundled in a platform gem (+vendor/lib/+; the plain ruby-platform gem has none).
  # 3. System library names resolved by the dynamic loader.
  # 4. Common prefixes (+/opt/homebrew/lib+, +/usr/local/lib+).
  # {Found#source} records which of these the library came from.
  module LibraryLoader
    # zxing-cpp versions whose C API this gem binds.
    SUPPORTED_VERSIONS = Gem::Requirement.new(">= 3.1.0", "< 4.0")

    # Symbols that must resolve for the library to be usable.
    REQUIRED_SYMBOLS = %w[ZXing_Version ZXing_ReadBarcodes ZXing_BarcodeFormatsFromString].freeze

    # Names handed to the dynamic loader. zxing-cpp 3.1's SONAME is 4.
    SYSTEM_NAMES = [
      FFI.map_library_name("ZXing"),
      "libZXing.so.4", "libZXing.so.3", "libZXing.so",
      "libZXing.4.dylib", "libZXing.dylib"
    ].uniq.freeze

    # Directories searched after the loader's own search path.
    PREFIXES = %w[/opt/homebrew/lib /usr/local/lib].freeze

    # Directory holding a library bundled with a platform gem.
    BUNDLED_DIR = File.expand_path("../../vendor/lib", __dir__)

    # A library that passed every check.
    # @!attribute name [String] what was handed to dlopen
    # @!attribute path [String] resolved file path (best effort, falls back to +name+)
    # @!attribute version [String] value of ZXing_Version()
    # @!attribute source [Symbol, nil] which candidate group it came from: +:explicit+ (library_path / ZXING_LIB),
    #   +:bundled+ (a platform gem's vendor/lib), +:system+ (the dynamic loader's search path) or +:prefix+
    #   ({PREFIXES}); nil when {LibraryLoader.probe} was called directly
    Found = Data.define(:name, :path, :version, :source) do
      def initialize(name:, path:, version:, source: nil) = super
    end

    # Outcome of probing one candidate.
    Attempt = Data.define(:name, :status, :detail)

    # Flags for probing candidates: resolve lazily, keep symbols local.
    DLOPEN_FLAGS = FFI::DynamicLibrary::RTLD_LAZY | FFI::DynamicLibrary::RTLD_LOCAL

    # Resolves the absolute path of a loaded library via dladdr(3).
    module Dl
      extend FFI::Library

      ffi_lib FFI::Library::LIBC

      # Dl_info from <dlfcn.h>.
      class Info < FFI::Struct
        layout :dli_fname, :pointer, :dli_fbase, :pointer, :dli_sname, :pointer, :dli_saddr, :pointer
      end

      begin
        attach_function :dladdr, [:pointer, Info.by_ref], :int
      rescue FFI::NotFoundError
        # not available on this platform; paths are reported as given
      end
    end

    class << self
      # Finds the first compatible library.
      #
      # @param explicit [String, nil] explicit path (defaults to the configured library_path)
      # @param bundled_dir [String] directory searched for a bundled library (defaults to {BUNDLED_DIR})
      # @return [Found]
      # @raise [LibraryNotFound] when no candidate loads
      # @raise [IncompatibleLibrary] when libraries load but none is compatible
      def find(explicit: ZXingFFI.config.library_path, bundled_dir: BUNDLED_DIR)
        attempts = []
        sourced_candidates(explicit, bundled_dir).each do |name, source|
          result = probe(name, source: source)
          return result if result.is_a?(Found)

          attempts << result
        end
        raise failure(attempts, explicit)
      end

      # Candidate names/paths in search order.
      # @param (see .find)
      # @return [Array<String>]
      def candidates(explicit: ZXingFFI.config.library_path, bundled_dir: BUNDLED_DIR)
        sourced_candidates(explicit, bundled_dir).map(&:first)
      end

      # Loads one candidate and checks its version and required symbols.
      # @param source [Symbol, nil] recorded in the {Found} result
      # @return [Found, Attempt]
      def probe(name, source: nil)
        library = FFI::DynamicLibrary.open(name.to_s, DLOPEN_FLAGS)
        version_symbol = library.find_function("ZXing_Version")
        return Attempt.new(name, :incompatible, "ZXing_Version not exported (zxing-cpp < 2.2 or built without the C API)") unless version_symbol

        version = FFI::Function.new(:string, [], version_symbol).call.to_s
        return Attempt.new(name, :incompatible, "version #{version} is not #{SUPPORTED_VERSIONS}") unless supported_version?(version)

        missing = REQUIRED_SYMBOLS.reject { |sym| library.find_function(sym) }
        return Attempt.new(name, :incompatible, "version #{version} lacks #{missing.join(", ")}") if missing.any?

        Found.new(name: name.to_s, path: resolve_path(version_symbol) || name.to_s, version: version, source: source)
      rescue LoadError => e
        Attempt.new(name, :not_found, e.message.lines.first.to_s.strip)
      end

      # @param version [String] e.g. "3.1.1"
      def supported_version?(version)
        numeric = version.to_s[/\A\d+(?:\.\d+)*/]
        return false unless numeric

        SUPPORTED_VERSIONS.satisfied_by?(Gem::Version.new(numeric))
      end

      private

      # [name, source] pairs in search order (see {Found#source}).
      def sourced_candidates(explicit, bundled_dir)
        return [[explicit, :explicit]] if explicit && !explicit.to_s.empty?

        bundled = Dir[File.join(bundled_dir, "libZXing*.{dylib,so}*")].sort.map { |path| [path, :bundled] }
        system = SYSTEM_NAMES.map { |name| [name, :system] }
        prefixed = PREFIXES.flat_map { |dir| SYSTEM_NAMES.map { |name| File.join(dir, name) } }
          .select { |path| File.exist?(path) }.map { |path| [path, :prefix] }
        (bundled + system + prefixed).uniq(&:first)
      end

      def resolve_path(symbol_pointer)
        return nil unless Dl.respond_to?(:dladdr)

        info = Dl::Info.new
        return nil if Dl.dladdr(symbol_pointer, info).zero? || info[:dli_fname].null?

        path = info[:dli_fname].read_string
        File.exist?(path) ? File.realpath(path) : path
      rescue
        nil
      end

      def failure(attempts, explicit)
        incompatible = attempts.select { |a| a.status == :incompatible }
        tried = attempts.map { |a| "  - #{a.name}: #{a.detail}" }.join("\n")
        if incompatible.any?
          version = incompatible.first.detail[/version (\S+)/, 1]
          IncompatibleLibrary.new(<<~MSG.chomp, version: version)
            Found libZXing, but no compatible version (need zxing-cpp #{SUPPORTED_VERSIONS} built with the C API).
            Tried:
            #{tried}
            #{HELP}
          MSG
        else
          LibraryNotFound.new(<<~MSG.chomp)
            Could not load libZXing#{" from #{explicit.inspect}" if explicit && !explicit.to_s.empty?}.
            Tried:
            #{tried}
            #{HELP}
          MSG
        end
      end
    end

    # Advice appended to LibraryNotFound / IncompatibleLibrary messages.
    HELP = <<~HELP.chomp
      To fix: install zxing-cpp 3.x with its C API (e.g. `brew install zxing-cpp`), or build it from source
      (`rake zxing:build` in this gem's repository, or cmake with -DZXING_C_API=ON), then point ZXING_LIB
      (or ZXingFFI.config.library_path) at the resulting libZXing shared library.
    HELP
  end
end
