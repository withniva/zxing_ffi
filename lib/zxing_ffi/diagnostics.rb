# frozen_string_literal: true

module ZXingFFI
  # Builds the environment report behind {ZXingFFI.diagnostics}. Never raises for a missing
  # library or tool: problems are reported in the Hash instead.
  module Diagnostics
    class << self
      # @return [Hash]
      def collect
        {
          gem_version: VERSION,
          ruby: {engine: RUBY_ENGINE, version: RUBY_VERSION, platform: RUBY_PLATFORM},
          library: library,
          defaults: defaults,
          loaders: loaders,
          transformers: transformers,
          config: ZXingFFI.config.to_h
        }
      end

      # @return [Hash] +{loaded:, path:, source:, version:, optional_symbols:, formats:}+ or +{loaded: false, error:}+;
      #   +source+ is where discovery found the library (see {LibraryLoader::Found#source}), e.g. +:bundled+
      def library
        found = Native.load!
        {
          loaded: true,
          path: found.path,
          source: found.source,
          version: found.version,
          optional_symbols: Native.optional_features,
          formats: Formats.readable
        }
      rescue Error => e
        {loaded: false, error: "#{e.class.name.split("::").last}: #{e.message}"}
      end

      # @return [Hash] +{library:, gem:}+ reader defaults
      def defaults
        library_defaults =
          begin
            LIBRARY_DEFAULTS
          rescue Error => e
            {error: e.message.lines.first.strip}
          end
        {library: library_defaults, gem: Reader::GEM_DEFAULTS}
      end

      # Availability, version and supported kinds of each loader.
      # @return [Hash{Symbol => Hash}]
      def loaders
        Loaders::NAMES.keys.to_h { |name| [name, component(Loaders, name)] }
      end

      # Availability and version of each transformer.
      # @return [Hash{Symbol => Hash}]
      def transformers
        Transformers::NAMES.keys.to_h { |name| [name, component(Transformers, name)] }
      end

      private

      def component(namespace, name)
        namespace.fetch(name).diagnostics
      rescue StandardError, ScriptError => e
        {available: false, reason: "#{e.class}: #{e.message}"}
      end
    end
  end
end
