# frozen_string_literal: true

module ZXingFFI
  module Loaders
    # PDF loader running Poppler's command-line tools in subprocesses: +pdfinfo+ for page count,
    # sizes, rotation and encryption, +pdftoppm -gray+ to render one page to PGM on stdout, and (optionally)
    # +pdfimages -list+ to find the native resolution of scanned pages for +dpi: :auto+.
    #
    # Every call uses an argument array (never a shell), an absolute input path, a timeout, an address-space limit
    # (Linux) and a cap on stdout. Passwords are only ever passed as the argument after +-upw+.
    # Renders of different pages may run concurrently.
    class PopplerLoader < Base
      # A page is treated as scanned when one embedded image covers at least this fraction of it.
      SCAN_COVERAGE = 0.5

      # Slack allowed on top of the expected PGM size (header + rounding of the page size).
      OUTPUT_SLACK = 1024

      # Poppler's command-line tools keep at most this many bytes of a password.
      MAX_PASSWORD_BYTES = 32

      class << self
        # (see Base.loader_name)
        def loader_name = :poppler

        # (see Base.kinds)
        def kinds = [:pdf]

        # (see Base.install_hint)
        def install_hint
          "install Poppler's command-line tools (brew install poppler / apt install poppler-utils)"
        end

        # (see Base.diagnostics)
        def diagnostics
          info = super
          return info unless available?

          info.merge(
            tools: %i[pdfinfo pdftoppm pdfimages].to_h { |tool| [tool, Subprocess.which(ZXingFFI.config.tool_path(tool).to_s)] },
            version: version
          )
        end

        # @return [String, nil] e.g. "26.07.0"
        def version
          _, out, err = Subprocess.run([ZXingFFI.config.tool_path(:pdftoppm).to_s, "-v"], timeout: 10)
          (out + err)[/version\s+([\d.]+)/, 1]
        rescue Error
          nil
        end

        private

        def probe
          missing = %i[pdfinfo pdftoppm].reject { |tool| Subprocess.which(ZXingFFI.config.tool_path(tool).to_s) }
          return true if missing.empty?

          @unavailable_reason = "#{missing.join(" and ")} not found (config.tool_paths)"
          false
        end
      end

      # @return [PopplerDocument]
      def open(source, password: nil)
        PopplerDocument.new(source, config, password)
      end

      # Parsers for Poppler's text output (kept separate for unit tests against recorded samples).
      module Parser
        module_function

        # "Pages:" and "Encrypted:" from +pdfinfo+.
        # @return [Hash] +{pages: Integer, encrypted: Boolean}+
        def info(text)
          pages = text[/^Pages:\s+(\d+)/, 1] or raise RenderError, "pdfinfo output has no page count"
          {pages: Integer(pages), encrypted: text.match?(/^Encrypted:\s+yes/)}
        end

        # Per-page sizes and rotations from +pdfinfo -f 1 -l N+.
        # @return [Hash{Integer => Hash}] page => +{width:, height:, rotation:}+ (unrotated CropBox, points)
        def page_boxes(text)
          pages = Hash.new { |h, k| h[k] = {rotation: 0} }
          text.each_line do |line|
            if (m = line.match(/^Page\s+(\d+)\s+size:\s+(\S+)\s+x\s+(\S+)\s+pts/))
              width, height = m[2, 2].map { |value| Float(value, exception: false) }
              unless [width, height].all? { |value| value&.finite? && value.positive? }
                raise RenderError, "pdfinfo reports an unusable size for page #{m[1]}: #{m[2]} x #{m[3]} pts"
              end

              pages[Integer(m[1])].merge!(width: width, height: height)
            elsif (m = line.match(/^Page\s+(\d+)\s+rot:\s+(-?\d+)/))
              pages[Integer(m[1])][:rotation] = Integer(m[2]) % 360
            end
          end
          pages.select { |_, box| box.key?(:width) }
        end

        # Rows of +pdfimages -list+ (masks excluded). The resolution columns are read from the end of the row:
        # the "object ID" column is two tokens ("23 0") for normal images but one ("[inline]") for inline images.
        # Rows that do not parse are skipped.
        # @return [Array<Hash>] +{page:, type:, width:, height:, x_ppi:, y_ppi:}+
        def images(text)
          text.each_line.filter_map do |line|
            fields = line.split
            next unless fields.size >= 13 && fields[0].match?(/\A\d+\z/) && fields[2] == "image"

            page, width, height = fields.values_at(0, 3, 4).map { |f| Integer(f, exception: false) }
            x_ppi, y_ppi = fields[-4, 2].map { |f| Float(f, exception: false) }
            next unless page && width && height && x_ppi && y_ppi

            {page: page, type: "image", width: width, height: height, x_ppi: x_ppi, y_ppi: y_ppi}
          end
        end

        # Native resolution of a scanned page: the ppi of an image covering most of it, else nil.
        # @return [Float, nil]
        def native_ppi(images, width_pt, height_pt, coverage: SCAN_COVERAGE)
          page_area = (width_pt / 72.0) * (height_pt / 72.0)
          return nil unless page_area.positive?

          scans = images.select do |image|
            next false unless image[:x_ppi].positive? && image[:y_ppi].positive?

            (image[:width] / image[:x_ppi]) * (image[:height] / image[:y_ppi]) >= coverage * page_area
          end
          scans.map { |image| [image[:x_ppi], image[:y_ppi]].max }.max
        end
      end

      # An opened PDF. Page metadata comes from one +pdfinfo+ run; each render is one +pdftoppm+ run.
      class PopplerDocument < Document
        def initialize(source, config, password)
          super(source)
          if password && password.to_s.bytesize > MAX_PASSWORD_BYTES
            raise NotSupported, "Poppler's command-line tools accept passwords of at most #{MAX_PASSWORD_BYTES} bytes; " \
              "this one has #{password.to_s.bytesize}. Use loader: :vips with config.vips_block_untrusted = false."
          end
          @config = config
          @password = password
          @mutex = Mutex.new
          info = Parser.info(pdfinfo)
          @page_count = info[:pages]
          @encrypted = info[:encrypted]
        end

        # @return [Integer]
        attr_reader :page_count

        # @return [Boolean] whether the file is encrypted (it opened, so no or the right password was needed)
        def encrypted? = @encrypted

        # Size in points of the page as displayed (after /Rotate).
        def page_info(number)
          check_page!(number)
          box = boxes.fetch(number) { raise RenderError, "pdfinfo reported no size for page #{number}" }
          width, height = displayed_size(box)
          PageInfo.new(number: number, width: width, height: height, unit: :pt, rotation: box[:rotation],
            native_ppi: native_ppi(number, width, height))
        end

        # Renders one page to 8-bit gray at +dpi+ (default: config.default_dpi).
        def render(number, dpi: nil, timeout: nil)
          check_page!(number)
          dpi ||= @config.default_dpi
          raise ArgumentError, "dpi must be a positive number" unless dpi.is_a?(Numeric) && dpi.positive?

          info = page_info(number)
          width, height = Dpi.dimensions(info.width, info.height, dpi)
          check_pixels!(width, height)
          argv = [tool(:pdftoppm), "-gray", "-cropbox", "-r", format_dpi(dpi), "-f", number.to_s, "-l", number.to_s, *password_args, source.path]
          stdout = run(argv, max_stdout: (width + 2) * (height + 2) + OUTPUT_SLACK, timeout: timeout)
          decoded =
            begin
              ZXingFFI::Pnm.decode(stdout, max_pixels: @config.max_pixels)
            rescue UnsupportedInput => e
              raise RenderError.new("pdftoppm produced invalid PGM for page #{number}: #{e.message}")
            end
          image = Image.new(decoded.pixels, width: decoded.width, height: decoded.height)
          Page.new(number: number, image: image, dpi: dpi, scale_to_base: 1.0,
            metadata: {loader: :poppler, rotation: info.rotation, native_ppi: info.native_ppi})
        end

        private

        # Per-page output ("Page N size: …" and "Page N rot: …") is ~80 bytes per page, so the cap grows with the
        # page count once it is known.
        def pdfinfo(*range)
          cap = 1024 * 1024 + (@page_count || 0) * 256
          run([tool(:pdfinfo), *range, *password_args, source.path], max_stdout: cap)
        end

        def boxes
          @mutex.synchronize do
            @boxes ||= Parser.page_boxes(pdfinfo("-f", "1", "-l", @page_count.to_s))
          end
        end

        def displayed_size(box)
          [90, 270].include?(box[:rotation]) ? [box[:height], box[:width]] : [box[:width], box[:height]]
        end

        def native_ppi(number, width, height)
          images = @mutex.synchronize { @images ||= list_images }
          Parser.native_ppi(images.select { |image| image[:page] == number }, width, height)
        end

        # All pages' embedded images, or [] when pdfimages is missing or fails (auto DPI then uses default_dpi).
        def list_images
          command = tool(:pdfimages)
          return [] unless Subprocess.which(command)

          Parser.images(run([command, "-list", *password_args, source.path], max_stdout: 16 * 1024 * 1024))
        rescue RenderError, TimeoutError, LimitExceeded
          []
        end

        # Integer DPIs as-is; fractional ones (huge declared pages, see Dpi.max_dpi_for) with 3 decimals.
        def format_dpi(dpi)
          dpi.is_a?(Integer) ? dpi.to_s : format("%.3f", dpi)
        end

        def password_args
          @password ? ["-upw", @password.to_s] : []
        end

        def tool(name)
          @config.tool_path(name).to_s
        end

        def check_pixels!(width, height)
          pixels = width * height
          return unless @config.max_pixels && pixels > @config.max_pixels

          raise LimitExceeded.new("rendering #{width}x#{height} (#{pixels} pixels) exceeds max_pixels #{@config.max_pixels}",
            limit: :max_pixels, value: pixels)
        end

        def run(argv, max_stdout:, timeout: nil)
          status, stdout, stderr = Subprocess.run(argv, timeout: [timeout, @config.render_timeout].compact.min, max_stdout: max_stdout,
            memory_limit: @config.subprocess_memory_limit)
          return stdout if status.success?

          raise password_error if stderr.match?(/incorrect password/i)

          raise RenderError.new("#{File.basename(argv.first)} failed on #{source.name} (exit #{status.exitstatus}): #{stderr.lines.first&.strip}",
            stderr: stderr, exit_status: status.exitstatus)
        end

        def password_error
          if @password
            IncorrectPassword.new("the password for #{source.name} was rejected")
          else
            PasswordRequired.new("#{source.name} is encrypted; pass password:")
          end
        end
      end
    end
  end
end
