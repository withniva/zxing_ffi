# frozen_string_literal: true

module ZXingFFI
  # The escalating pass ladder run on one page.
  #
  # Every pass decodes the page's base image or a derivative of it (a re-render, an upscale, tiles, a rotation)
  # and maps its results back to base-image coordinates with an {Geometry::Affine}. Results are filtered,
  # deduplicated against earlier passes (the earliest pass wins) and the ladder stops according to +stop+.
  class Strategy
    # Pass names in ladder order.
    PASSES = %i[base inverted global_binarizer high_res tiles rotated_45 denoise].freeze

    # Passes per effort level.
    EFFORTS = {
      fast: %i[base],
      normal: %i[base inverted global_binarizer high_res],
      thorough: PASSES
    }.freeze

    # Raster images whose longest side is below this get a 2× upscale in the high_res pass.
    UPSCALE_BELOW = 2000

    # Tile geometry for the tiles pass.
    TILES = {min_tile: 1024, max_tile: 1536, overlap: 0.2}.freeze

    # Rotation of the rotated pass (with try_rotate it also covers 135°, 225° and 315°).
    ROTATED_DEGREES = 45

    # @!attribute barcodes [Array<Barcode>] positions in base-image pixels, +pass+ set
    # @!attribute passes_run [Array<Symbol>]
    # @!attribute skipped_passes [Hash{Symbol => String}] passes that could not run, with the reason
    Result = Data.define(:barcodes, :passes_run, :skipped_passes)

    # An image (or a crop of it) to decode plus the transform from its pixels to the base image.
    # +negative+ marks a pixel-inverted copy: its results are reported as inverted.
    View = Data.define(:image, :to_base, :crop, :negative) do
      def initialize(image:, to_base:, crop: nil, negative: false)
        super
      end
    end

    class << self
      # @param effort [Symbol] +:fast+, +:normal+, +:thorough+
      # @param passes [Array<Symbol>, nil] explicit ladder, overrides +effort+
      # @return [Array<Symbol>]
      # @raise [ArgumentError]
      def passes_for(effort: :normal, passes: nil)
        if passes
          list = Array(passes).map(&:to_sym)
          unknown = list - PASSES
          raise ArgumentError, "unknown pass(es) #{unknown.map(&:inspect).join(", ")}; valid: #{PASSES.join(", ")}" if unknown.any?
          raise ArgumentError, "passes must not be empty" if list.empty?

          return list.uniq
        end
        EFFORTS.fetch(effort) { raise ArgumentError, "effort must be one of #{EFFORTS.keys.join(", ")}, got #{effort.inspect}" }
      end

      # @param stop [Symbol, Integer] +:found+, +:exhaustive+ or a positive Integer
      # @return [Symbol, Integer]
      # @raise [ArgumentError]
      def validate_stop(stop)
        return stop if stop == :found || stop == :exhaustive || (stop.is_a?(Integer) && stop.positive?)

        raise ArgumentError, "stop must be :found, :exhaustive or a positive Integer, got #{stop.inspect}"
      end
    end

    # @param passes [Array<Symbol>]
    # @param stop [Symbol, Integer]
    # @param options [Reader::Options] options of the base pass (library defaults + gem defaults + user options)
    # @param config [Config] effective configuration
    # @param min_length [Hash{Symbol => Integer}] minimum text length per format or symbology
    # @param transformer [#call, nil] returns a {Transformers::Base} or nil, called only when a pass needs one
    def initialize(passes:, stop:, options:, config:, min_length: {}, transformer: nil)
      @passes = passes
      @stop = stop
      @options = options
      @config = config
      @min_length = min_length
      @transformer_factory = transformer
      @pass_options = {}
    end

    # Runs the ladder on one page.
    #
    # @param page [Loaders::Page] the base page (not released here)
    # @param rerender [#call, nil] +->(dpi) { Loaders::Page }+ for PDF pages; nil for rasters
    # @param page_info [Loaders::PageInfo, nil] page size in points, for the PDF high_res pixel cap
    # @param deadline [Float, nil] monotonic clock time after which no further pass starts (the first pass always runs)
    # @param notify [#call, nil] +->(event, payload)+, receives +:pass_completed+
    # @return [Result]
    def run(page, rerender: nil, page_info: nil, deadline: nil, notify: nil)
      base = View.new(page.image, Geometry::Affine.identity, nil)
      found = []
      passes_run = []
      skipped = {}
      best = base # highest-resolution image so far (tiles pass)
      owned = [] # derived images to release

      @passes.each do |name|
        break if stop?(found, passes_run)
        if deadline && passes_run.any? && monotonic > deadline # the first pass always runs
          skipped[name] = "page timeout"
          next
        end

        started = monotonic
        begin
          views, options, reason = prepare(name, page, base, best, rerender, page_info, owned)
          if reason
            skipped[name] = reason
            next
          end
          results = views.flat_map { |view| decode(name, view, options) }
        rescue Error => e
          raise if passes_run.empty? # the first pass failing is the page failing
          # an escalation pass failing (re-render timeout, transformer error, …) must not lose earlier results
          skipped[name] = "failed: #{e.class.name.split("::").last}: #{e.message.lines.first&.strip}"
          next
        end
        best = views.first if name == :high_res
        added = merge!(found, filter(results))
        passes_run << name
        release!(owned.pop) if %i[inverted rotated_45].include?(name) # single-use derived images
        notify&.call(:pass_completed, {pass: name, found: results.size, added: added, duration: monotonic - started})
      end
      Result.new(barcodes: found, passes_run: passes_run, skipped_passes: skipped)
    ensure
      owned&.each { |image| release!(image) }
    end

    private

    def stop?(found, passes_run)
      return false if passes_run.empty?

      case @stop
      when :found then found.any?
      when :exhaustive then false
      else found.size >= @stop
      end
    end

    # @return [Array(Array<View>, Reader::Options, nil), Array(nil, nil, String)] views + options, or a skip reason
    def prepare(name, page, base, best, rerender, page_info, owned)
      case name
      when :base
        [[base], @options]
      when :inverted
        prepare_inverted(base, owned)
      when :global_binarizer
        return [nil, nil, "binarizer is already :global_histogram"] if @options[:binarizer] == :global_histogram

        [[base], options_for(name) { @options.merge(binarizer: :global_histogram) }]
      when :high_res
        prepare_high_res(page, base, rerender, page_info, owned)
      when :tiles
        grid = Geometry.tile_grid(best.image.width, best.image.height, **TILES)
        views = grid.map do |x, y, w, h|
          View.new(best.image, best.to_base.compose(Geometry::Affine.translation(x, y)), [x, y, w, h])
        end
        [views, options_for(name) { @options.merge(try_downscale: false) }]
      when :rotated_45
        prepare_rotated(base, owned)
      when :denoise
        return [nil, nil, "try_denoise is not supported by this libZXing (needs ZXING_EXPERIMENTAL_API)"] unless Native.supports?(:try_denoise)

        [[base], options_for(name) { @options.merge(try_denoise: true) }]
      end
    end

    def prepare_high_res(page, base, rerender, page_info, owned)
      image, reason = (rerender && page.dpi) ? rerender_high_res(page, rerender, page_info) : upscale(base)
      return [nil, nil, reason] unless image

      owned << image
      scale = Geometry::Affine.scale(base.image.width.to_f / image.width, base.image.height.to_f / image.height)
      [[View.new(image, scale, nil)], @options]
    end

    # PDF pages: re-render at 2x the base DPI, within max_dpi and the pixel cap.
    def rerender_high_res(page, rerender, page_info)
      return [nil, "no page size to compute the high-res DPI"] unless page_info

      dpi = Dpi.high_res(page.dpi, width_pt: page_info.width, height_pt: page_info.height,
        max_dpi: @config.max_dpi, max_pixels: @config.max_pixels)
      return [nil, "already at max_dpi or the pixel cap (#{page.dpi} DPI)"] unless dpi

      [rerender.call(dpi).image, nil]
    end

    # Rasters: 2x upscale when the longest side is below UPSCALE_BELOW.
    def upscale(base)
      return [nil, "the upscale needs a :lum image"] unless base.image.format == :lum

      longest = [base.image.width, base.image.height].max
      return [nil, "image is already #{longest} px (>= #{UPSCALE_BELOW})"] if longest >= UPSCALE_BELOW
      return [nil, "upscaled image would exceed max_pixels"] if @config.max_pixels && base.image.width * base.image.height * 4 > @config.max_pixels

      transformer = self.transformer or return [nil, "no transformer available"]
      [transformer.resize(base.image, 2), nil]
    end

    # White-on-black codes. zxing-cpp's try_invert only helps its 2D readers (linear readers scan raw rows), so this
    # pass decodes a pixel-inverted copy: restricted to linear formats when try_invert already covers 2D, all
    # selected formats otherwise.
    def prepare_inverted(base, owned)
      return [nil, nil, "the inverted pass needs a :lum image"] unless base.image.format == :lum

      linear_only = effective(:try_invert)
      formats = linear_only ? Formats.linear_subset(@options[:formats]) : nil
      return [nil, nil, "try_invert already covers the selected formats (no linear format selected)"] if linear_only && formats.empty?

      image = base.image.inverted
      owned << image
      options = options_for(:inverted) do
        linear_only ? @options.merge(formats: formats, try_invert: false) : @options.merge(try_invert: false)
      end
      [[View.new(image, Geometry::Affine.identity, nil, true)], options]
    end

    def prepare_rotated(base, owned)
      return [nil, nil, "the rotated pass needs a :lum image"] unless base.image.format == :lum

      formats = Formats.linear_subset(@options[:formats])
      return [nil, nil, "no linear formats selected"] if formats.empty?

      to_canvas, width, height = Geometry.rotation_canvas(base.image.width, base.image.height, ROTATED_DEGREES)
      if @config.max_pixels && width * height > @config.max_pixels
        return [nil, nil, "rotated canvas #{width}x#{height} would exceed max_pixels"]
      end

      transformer = self.transformer or return [nil, nil, "no transformer available"]
      image = transformer.rotate(base.image, ROTATED_DEGREES, background: 255)
      owned << image
      # transformers may round the expanded canvas differently (±1 px): keep the image centered on the actual canvas
      to_canvas = Geometry::Affine.translation((image.width - width) / 2.0, (image.height - height) / 2.0).compose(to_canvas)
      [[View.new(image, to_canvas.invert, nil)], options_for(:rotated_45) { @options.merge(formats: formats) }]
    end

    def transformer
      return @transformer if defined?(@transformer)

      @transformer = @transformer_factory&.call
    end

    def options_for(name)
      @pass_options[name] ||= yield
    end

    # Effective value of a reader option: the caller's, else the library default.
    def effective(key)
      @options[key].nil? ? LIBRARY_DEFAULTS[key] : @options[key]
    end

    def decode(pass, view, options)
      rotation = view.to_base.rotation_degrees
      Reader.read(view.image, options, crop: view.crop).map do |barcode|
        barcode.with(
          position: view.to_base.apply_quad(barcode.position).round,
          rotation: (barcode.rotation + rotation).round % 360,
          inverted: barcode.inverted ^ view.negative,
          pass: pass
        )
      end
    end

    def filter(barcodes)
      barcodes.select do |barcode|
        next false unless barcode.valid? || @options[:return_errors]

        minimum = @min_length[barcode.format] || @min_length[barcode.symbology]
        minimum.nil? || barcode.text.length >= minimum
      end
    end

    # Adds results that are not duplicates of earlier ones; returns how many were added.
    def merge!(found, results)
      before = found.size
      results.each { |barcode| found << barcode unless found.any? { |kept| Dedupe.duplicate?(kept, barcode) } }
      found.size - before
    end

    def release!(image)
      image&.release!
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
