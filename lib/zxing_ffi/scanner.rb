# frozen_string_literal: true

module ZXingFFI
  # Results for one page or frame.
  #
  # @!attribute page [Integer] 1-based
  # @!attribute barcodes [Array<Barcode>] ordered top-to-bottom, left-to-right
  # @!attribute dpi [Integer, nil] base render DPI (PDF) or nil
  # @!attribute width [Integer, nil] base image width in pixels (the original's for a raster decoded downscaled)
  # @!attribute height [Integer, nil] base image height in pixels (the original's for a raster decoded downscaled)
  # @!attribute passes_run [Array<Symbol>]
  # @!attribute skipped_passes [Hash{Symbol => String}] passes that could not run, with the reason
  # @!attribute duration [Float] seconds spent on the page
  # @!attribute error [Exception, nil] set only with +on_page_error: :skip+
  # @!attribute metadata [Hash] what the loader applied (orientation, aspect correction, DPI capping, …)
  PageResult = Data.define(:page, :barcodes, :dpi, :width, :height, :passes_run, :skipped_passes, :duration, :error, :metadata)

  # Orchestrates a scan: input → loader → pages → pass ladder → ordered results, optionally on several
  # threads.
  class Scanner
    # Options that only the scanner understands.
    SCAN_OPTIONS = %i[
      effort passes stop dpi max_dpi max_pixels max_source_pixels oversize max_pages pages password threads
      on_page_error loader min_length timeout instrument
    ].freeze

    # Every option +scan+/+scan_pages+ accept: the scanner's plus every {ZXingFFI.read} option.
    OPTIONS = (SCAN_OPTIONS + Reader::OPTION_KEYS).freeze

    # Accepted values of +on_page_error:+.
    ON_PAGE_ERROR = %i[raise skip].freeze

    # Accepted values of +oversize:+.
    OVERSIZE = %i[raise downscale].freeze

    # @param options [Hash] see {ZXingFFI.scan}
    # @raise [ArgumentError] for unknown or invalid options (before any input is opened)
    def initialize(**options)
      unknown = options.keys - OPTIONS
      raise ArgumentError, "unknown option(s) #{unknown.map(&:inspect).join(", ")}; valid: #{OPTIONS.join(", ")}" if unknown.any?

      @passes = Strategy.passes_for(effort: options.fetch(:effort, :normal), passes: options[:passes])
      @stop = Strategy.validate_stop(options.fetch(:stop, :found))
      @dpi = validate_dpi(options.fetch(:dpi, :auto))
      @pages = validate_pages(options[:pages])
      @password = options[:password]&.to_s
      @threads = validate_positive_integer(:threads, options.fetch(:threads, 1))
      @on_page_error = options.fetch(:on_page_error, :raise)
      raise ArgumentError, "on_page_error must be :raise or :skip, got #{@on_page_error.inspect}" unless ON_PAGE_ERROR.include?(@on_page_error)

      @loader = options[:loader]
      @timeout = options[:timeout] && validate_positive_number(:timeout, options[:timeout])
      @instrument = options[:instrument]
      raise ArgumentError, "instrument must respond to #call" if @instrument && !@instrument.respond_to?(:call)

      @config = effective_config(options)
      raise ArgumentError, "oversize must be :raise or :downscale, got #{@config.oversize.inspect}" unless OVERSIZE.include?(@config.oversize)
      source_pixels = @config.max_source_pixels
      if source_pixels && !(source_pixels.is_a?(Integer) && source_pixels.positive?)
        raise ArgumentError, "max_source_pixels must be a positive Integer or nil, got #{source_pixels.inspect}"
      end

      @reader_options = Reader::Options.new(options.slice(*Reader::OPTION_KEYS))
      @min_length = validate_min_length(options.fetch(:min_length, {}))
      @notify_mutex = Mutex.new
    end

    # @return [Array<Barcode>] every page's barcodes, ordered by page then position
    def scan(input)
      results = []
      scan_pages(input) { |page_result| results.concat(page_result.barcodes) }
      results
    end

    # Yields a {PageResult} per selected page, in page order.
    # @yieldparam page_result [PageResult]
    # @return [nil]
    def scan_pages(input, &block)
      raise ArgumentError, "a block is required" unless block

      if input.is_a?(Image)
        yield process(nil, 1, pdf: false, image: input)
      else
        Source.open(input) { |source| scan_source(source, &block) }
      end
      nil
    end

    # Orders barcodes top-to-bottom, then left-to-right (by quad center). Centers within half the smaller
    # code's height (at least 8 px) count as the same row.
    # @return [Array<Barcode>]
    def self.order(barcodes)
      rows = []
      barcodes.sort_by { |b| [b.center.y, b.center.x] }.each do |barcode|
        row = rows.last
        if row && (barcode.center.y - row.first.center.y).abs <= row_tolerance(row.first, barcode)
          row << barcode
        else
          rows << [barcode]
        end
      end
      rows.flat_map { |row| row.sort_by { |b| b.center.x } }
    end

    def self.row_tolerance(a, b)
      heights = [a, b].map { |barcode| barcode.position.bounding_box.then { |_, y0, _, y1| y1 - y0 } }
      [8, heights.min / 2.0].max
    end
    private_class_method :row_tolerance

    private

    def scan_source(source, &block)
      unless source.kind == :pdf
        pixels, limit = raster_limit(source.kind)
        HeaderProbe.check!(source.path, source.kind, pixels, limit: limit)
      end
      loader_class = Loaders::Registry.loader_for(source.kind, config: @config, loader: @loader)
      document = loader_class.new(@config).open(source, password: @password)
      begin
        numbers = select_pages(document.page_count)
        if @config.max_pages && numbers.size > @config.max_pages
          raise LimitExceeded.new("#{numbers.size} pages selected, max_pages is #{@config.max_pages}",
            limit: :max_pages, value: numbers.size)
        end

        pdf = source.kind == :pdf
        each_result(numbers, ->(number) { process(document, number, pdf: pdf) }, &block)
      ensure
        document.close
      end
    end

    # Runs +work+ for each page number, on @threads threads, yielding results in page order.
    def each_result(numbers, work)
      if @threads <= 1 || numbers.size <= 1
        numbers.each { |number| yield work.call(number) }
        return
      end

      queue = Queue.new
      numbers.each { |number| queue << number }
      queue.close
      results = Queue.new
      workers = Array.new([@threads, numbers.size].min) do
        Thread.new do
          while (number = queue.pop)
            outcome =
              begin
                work.call(number)
              rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised on the caller's thread
                e
              end
            results << [number, outcome]
          end
        end
      end

      buffered = {}
      numbers.each do |number|
        buffered.store(*results.pop) until buffered.key?(number)
        outcome = buffered.delete(number)
        raise outcome if outcome.is_a?(Exception)

        yield outcome
      end
      completed = true
    ensure
      if workers
        queue.clear # stop handing out pages
        # Leaving early (error, break, Ctrl-C, Timeout): don't wait for pages in progress. Killing is safe: native
        # decodes defer interrupts until their objects are freed, and Subprocess kills its child process group.
        workers.each(&:kill) unless completed
        workers.each(&:join)
      end
    end

    def process(document, number, pdf:, image: nil)
      started = monotonic
      deadline = @timeout && started + @timeout
      page = nil
      info = document&.page_info(number)
      choice = pdf ? choose_dpi(info) : nil
      page = image ? Loaders::Page.new(number: 1, image: image, dpi: nil, scale_to_base: 1.0, metadata: {loader: :image}) : document.render(number, dpi: choice&.dpi)
      notify(:page_loaded, page: number, width: page.image.width, height: page.image.height, dpi: page.dpi, duration: monotonic - started)

      # re-renders (high_res pass) get only what is left of the page budget
      rerender = pdf ? ->(dpi) { document.render(number, dpi: dpi, timeout: deadline && [deadline - monotonic, 0.05].max) } : nil
      result = strategy.run(page, rerender: rerender, page_info: info, deadline: deadline,
        notify: ->(event, payload) { notify(event, page: number, **payload) })
      barcodes = Scanner.order(result.barcodes.map { |barcode| finalize(barcode, number, page) })
      metadata = page.metadata.merge(choice ? {dpi_source: choice.source, dpi_capped: choice.capped} : {})
      width, height = page.metadata.dig(:downscaled, :from) || [page.image.width, page.image.height]
      page_result = PageResult.new(
        page: number, barcodes: barcodes, dpi: page.dpi, width: width, height: height,
        passes_run: result.passes_run, skipped_passes: result.skipped_passes, duration: monotonic - started,
        error: nil, metadata: metadata
      )
      notify(:page_completed, page: number, barcodes: barcodes.size, passes_run: result.passes_run, duration: page_result.duration)
      page_result
    rescue => e
      raise if @on_page_error == :raise

      PageResult.new(
        page: number, barcodes: [], dpi: page&.dpi, width: nil, height: nil, passes_run: [], skipped_passes: {},
        duration: monotonic - started, error: e, metadata: {}
      )
    ensure
      page.image.release! if page && !image
    end

    def strategy
      Strategy.new(passes: @passes, stop: @stop, options: @reader_options, config: @config, min_length: @min_length,
        transformer: -> { Transformers.first_available(@config.transformers, config: @config) })
    end

    def choose_dpi(info)
      Dpi.choose(requested: @dpi, width_pt: info.width, height_pt: info.height, native_ppi: info.native_ppi,
        default_dpi: @config.default_dpi, max_dpi: @config.max_dpi, max_pixels: @config.max_pixels)
    end

    # Adds page metadata and PDF page coordinates (points from the top-left of the displayed page); positions in a
    # raster decoded downscaled are scaled back to the original's pixels.
    def finalize(barcode, number, page)
      dpi = page.dpi
      position = barcode.position.transform(Geometry::Affine.scale(page.scale_to_base)).round
      page_position = dpi && position.map { |p| Geometry::Point.new((p.x * 72.0 / dpi).round(2), (p.y * 72.0 / dpi).round(2)) }
      barcode.with(position: position, page: number, dpi: dpi, page_position: page_position)
    end

    # The pixels a raster may declare, with the limit's name: max_source_pixels when +oversize: :downscale+ and its
    # loader can decode it smaller to fit, otherwise max_pixels.
    def raster_limit(kind)
      return [@config.max_pixels, :max_pixels] unless @config.oversize == :downscale

      downscales = begin
        Loaders::Registry.loader_for(kind, config: @config, loader: @loader).downscales?
      rescue LoaderUnavailable
        false
      end
      downscales ? [@config.max_source_pixels, :max_source_pixels] : [@config.max_pixels, :max_pixels]
    end

    def select_pages(count)
      numbers =
        case @pages
        when nil then (1..count).to_a
        when Integer then [@pages]
        when Range
          last = if @pages.end.nil?
            count
          else
            (@pages.exclude_end? ? @pages.end - 1 : @pages.end)
          end
          ((@pages.begin || 1)..[last, count].min).to_a
        else @pages.uniq.sort
        end
      numbers.select! { |n| n.between?(1, count) }
      raise ArgumentError, "no pages selected: #{@pages.inspect} is outside 1..#{count}" if numbers.empty?

      numbers
    end

    def notify(event, **payload)
      return unless @instrument

      @notify_mutex.synchronize { @instrument.call(event, payload) }
    end

    def effective_config(options)
      overrides = options.slice(:max_dpi, :max_pixels, :max_source_pixels, :oversize, :max_pages)
      if @timeout
        overrides[:render_timeout] = [ZXingFFI.config.render_timeout, @timeout].compact.min
      end
      ZXingFFI.config.with(**overrides)
    end

    def validate_dpi(dpi)
      return dpi if dpi == :auto || (dpi.is_a?(Integer) && dpi.positive?)

      raise ArgumentError, "dpi must be a positive Integer or :auto, got #{dpi.inspect}"
    end

    def validate_pages(pages)
      valid =
        case pages
        when nil then true
        when Integer then pages.positive?
        when Range then [pages.begin, pages.end].all? { |n| n.nil? || (n.is_a?(Integer) && n.positive?) }
        when Array then pages.any? && pages.all? { |n| n.is_a?(Integer) && n.positive? }
        else false
        end
      return pages if valid

      raise ArgumentError, "pages must be a positive Integer, a Range or an Array of 1-based page numbers, got #{pages.inspect}"
    end

    def validate_min_length(min_length)
      raise ArgumentError, "min_length must be a Hash of format => Integer" unless min_length.is_a?(Hash)

      min_length.each do |format, length|
        raise ArgumentError, "min_length: unknown format #{format.inspect}" unless Formats.all.include?(format)
        raise ArgumentError, "min_length for #{format.inspect} must be a non-negative Integer" unless length.is_a?(Integer) && length >= 0
      end
      min_length.dup.freeze
    end

    def validate_positive_integer(name, value)
      return value if value.is_a?(Integer) && value.positive?

      raise ArgumentError, "#{name} must be a positive Integer, got #{value.inspect}"
    end

    def validate_positive_number(name, value)
      return value if value.is_a?(Numeric) && value.positive?

      raise ArgumentError, "#{name} must be a positive number of seconds, got #{value.inspect}"
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
