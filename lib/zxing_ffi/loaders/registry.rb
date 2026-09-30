# frozen_string_literal: true

module ZXingFFI
  module Loaders
    # Chooses a loader for an input kind.
    #
    # Order comes from +config.pdf_loaders+ (PDF) or +config.image_loaders+ (everything else); an explicit
    # +loader:+ overrides it. The first loader that supports the kind and is available wins.
    module Registry
      class << self
        # @param kind [Symbol] sniffed input kind
        # @param config [Config]
        # @param loader [Symbol, Array<Symbol>, nil] explicit loader name(s)
        # @return [Class<Base>]
        # @raise [LoaderUnavailable] naming what to install
        # @raise [ArgumentError] for unknown loader names
        def loader_for(kind, config: ZXingFFI.config, loader: nil)
          order = loader ? Array(loader) : default_order(kind, config)
          tried = order.map do |name|
            klass = Loaders.fetch(name)
            return klass if klass.supports?(kind)

            reason =
              if klass.kinds.include?(kind)
                klass.unavailable_reason || klass.unsupported_reason(kind) || "no #{kind} support in this build"
              else
                "does not read #{kind}"
              end
            [name, reason, klass]
          end
          raise LoaderUnavailable, unavailable_message(kind, tried)
        end

        # @return [Array<Symbol>] configured loader order for +kind+
        def default_order(kind, config)
          (kind == :pdf) ? config.pdf_loaders : config.image_loaders
        end

        private

        def unavailable_message(kind, tried)
          lines = tried.map { |name, reason, _| "  - #{name}: #{reason}" }
          # install hints only for loaders that are missing; a present loader that refuses explains why in its reason
          hints = tried.filter_map { |_, _, klass| klass.install_hint if klass.kinds.include?(kind) && !klass.available? }
          hints = hints.reject(&:empty?).uniq
          if hints.empty?
            hints << ((tried.any? { |_, _, klass| klass.kinds.include?(kind) }) ? "see the reasons above" : "no configured loader reads #{kind} input")
          end
          "No loader available for #{kind} input.\nTried:\n#{lines.join("\n")}\nTo fix: #{hints.join("; or ")}"
        end
      end
    end
  end
end
