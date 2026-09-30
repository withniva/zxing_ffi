# frozen_string_literal: true

module ZXingFFI
  module Loaders
    # In-process loader built on libvips via the optional ruby-vips gem: rasters, and PDFs as a fallback.
    #
    # Every input is opened with the libvips loader matching its sniffed kind (e.g. +pngload+), so libvips never
    # re-detects a different format from the content. Operations libvips flags as *untrusted* (in libvips 8.18:
    # +pdfload+, +magickload+, +ppmload+) are refused while +config.vips_block_untrusted+ is true (the default); this
    # gives the protection of +vips_block_untrusted_set+ without changing libvips' process-global state.
    # Consequently vips renders PDFs only after opting in with +vips_block_untrusted = false+ — and a crash in
    # libvips or poppler-glib then takes down the Ruby process.
    #
    # Documents are safe to render concurrently (each render builds its own libvips pipeline).
    class VipsLoader < Base
      # Sniffed kind => libvips load operation.
      OPERATIONS = {
        png: "pngload", jpeg: "jpegload", tiff: "tiffload", gif: "gifload", webp: "webpload",
        heif: "heifload", avif: "heifload", pnm: "ppmload", bmp: "magickload", pdf: "pdfload"
      }.freeze

      # Loaders that take a +page:+ argument.
      PAGED = %w[tiffload gifload webpload heifload pdfload magickload].freeze

      # VIPS_OPERATION_UNTRUSTED in VipsOperationFlags.
      UNTRUSTED_FLAG = 16

      # Resolutions (pixels per inch) differing by more than this ratio are corrected.
      ASPECT_TOLERANCE = 0.05

      class << self
        # (see Base.loader_name)
        def loader_name = :vips

        # (see Base.kinds)
        def kinds = OPERATIONS.keys

        # (see Base.install_hint)
        def install_hint
          "install libvips (brew install vips / apt install libvips-tools) and the ruby-vips gem"
        end

        # Whether this libvips can load +kind+ right now (operation present and, unless opted in, trusted).
        def supports?(kind)
          operation = OPERATIONS[kind.to_sym]
          return false unless operation && available? && operation?(operation)

          !(ZXingFFI.config.vips_block_untrusted && untrusted?(operation))
        end

        # (see Base.unsupported_reason)
        def unsupported_reason(kind)
          operation = OPERATIONS[kind.to_sym]
          return nil unless operation && available?
          return "this libvips has no #{operation}" unless operation?(operation)
          return nil unless ZXingFFI.config.vips_block_untrusted && untrusted?(operation)

          "libvips flags #{operation} as untrusted; it is refused while config.vips_block_untrusted is true " \
            "(set it to false to allow it)"
        end

        # (see Base.diagnostics)
        def diagnostics
          return super unless available?

          super.merge(
            version: ::Vips.version_string,
            block_untrusted: ZXingFFI.config.vips_block_untrusted,
            untrusted_operations: OPERATIONS.values.uniq.select { |op| operation?(op) && untrusted?(op) }
          )
        end

        # @api private
        def operation?(name)
          @operations ||= {}
          return @operations[name] if @operations.key?(name)

          @operations[name] = ::Vips.type_find("VipsOperation", name) != 0
        end

        # @api private
        def untrusted?(name)
          @untrusted ||= {}
          return @untrusted[name] if @untrusted.key?(name)

          @untrusted[name] = (::Vips.vips_operation_get_flags(::Vips::Operation.new(name)) & UNTRUSTED_FLAG) != 0
        end

        # (see Base.reset!)
        def reset!
          super
          @operations = nil
          @untrusted = nil
        end

        private

        def probe
          require "vips"
          true
        rescue LoadError, StandardError => e
          @unavailable_reason = "ruby-vips/libvips not loadable (#{e.class}: #{e.message.lines.first&.strip})"
          false
        end
      end

      # (see Base#open)
      def open(source, password: nil)
        unless self.class.supports?(source.kind)
          raise LoaderUnavailable, "libvips cannot load #{source.kind} here (missing or untrusted #{OPERATIONS[source.kind]})"
        end

        if source.kind == :pdf
          PdfDocument.new(source, config, password)
        else
          RasterDocument.new(source, config, OPERATIONS.fetch(source.kind))
        end
      end

      # Shared helpers for libvips-backed documents.
      module Pipeline
        # Loads +path+ with +operation+ without libvips' operation cache handing back a stale image: libvips caches
        # loads by file name, so a file overwritten at the same path would otherwise decode as its old contents
        # (e.g. an upload handler reusing a temp path). libvips ≥ 8.15 has +revalidate+; older versions load from a
        # buffer, which is never served from the file-name cache.
        # @api private
        def self.load_fresh(operation, path, **options)
          ::Vips.vips_error_clear # see error_summary
          if ::Vips.at_least_libvips?(8, 15)
            ::Vips::Image.public_send(operation, path, revalidate: true, **options)
          else
            ::Vips::Image.public_send(:"#{operation}_buffer", File.binread(path), **options)
          end
        end

        # The cause of a libvips failure. A +Vips::Error+'s message is libvips' process-wide error buffer, oldest line
        # first, and successful calls can leave warnings there (e.g. heifload's "bad seek"); so the buffer is cleared
        # before our calls and the last lines are the ones that describe this failure.
        # @api private
        def self.error_summary(error, lines: 3)
          error.message.lines.map(&:strip).reject(&:empty?).last(lines).join(" ")
        end

        private

        def vips_call
          ::Vips.vips_error_clear
          yield
        rescue ::Vips::Error => e
          raise RenderError.new("libvips failed on #{source.name}: #{Pipeline.error_summary(e)}", stderr: e.message[0, 4096])
        end

        # Flattens alpha onto white, converts to 8-bit single-band luminance and copies it into an Image.
        def to_image(vimage)
          check_pixels!(vimage.width, vimage.height)
          if vimage.has_alpha?
            white = %i[ushort short].include?(vimage.format) ? 65_535 : 255
            vimage = vimage.flatten(background: [white])
          end
          vimage = vimage.colourspace(:b_w) unless vimage.interpretation == :"b-w" && vimage.format == :uchar
          vimage = vimage.extract_band(0) if vimage.bands > 1
          vimage = vimage.cast(:uchar) unless vimage.format == :uchar
          Image.new(vimage.write_to_memory, width: vimage.width, height: vimage.height)
        end

        def check_pixels!(width, height)
          pixels = width * height
          return unless @config.max_pixels && pixels > @config.max_pixels

          raise LimitExceeded.new("#{width}x#{height} (#{pixels} pixels) exceeds max_pixels #{@config.max_pixels}",
            limit: :max_pixels, value: pixels)
        end
      end

      # A raster file: one page per frame (multi-page TIFF, animated GIF/WebP, HEIF collections).
      class RasterDocument < Document
        include Pipeline

        def initialize(source, config, operation)
          super(source)
          @config = config
          @operation = operation
          header = load(0)
          @page_count = (header.get_typeof("n-pages") != 0) ? [header.get("n-pages"), 1].max : 1
          @infos = {}
          @mutex = Mutex.new
        end

        attr_reader :page_count

        # (see Document#page_info)
        def page_info(number)
          check_page!(number)
          @mutex.synchronize { @infos[number] ||= build_info(number) }
        end

        # Applies the normalization contract: aspect correction (on the stored axes, because libvips'
        # autorot does not swap xres/yres), EXIF orientation, alpha → white, 16-bit scaling, 8-bit gray.
        def render(number, dpi: nil, timeout: nil) # timeout: in-process, cannot be enforced
          check_page!(number)
          vips_call do
            vimage = load(number - 1)
            vimage, aspect = correct_aspect(vimage)
            orientation = orientation_of(vimage)
            orientation = nil if orientation == 1 # "normal": nothing to apply
            vimage = vimage.autorot if orientation
            image = to_image(vimage)
            Page.new(number: number, image: image, dpi: nil, scale_to_base: 1.0, metadata: {
              loader: :vips, orientation_applied: orientation, aspect_corrected: aspect
            })
          end
        end

        private

        def load(index)
          vips_call do
            options = PAGED.include?(@operation) ? {page: index} : {}
            Pipeline.load_fresh(@operation, source.path, **options)
          end
        end

        def build_info(number)
          vimage = load(number - 1)
          width, height = corrected_size(vimage)
          orientation = orientation_of(vimage)
          width, height = height, width if [5, 6, 7, 8].include?(orientation)
          PageInfo.new(number: number, width: width, height: height, unit: :px,
            rotation: {3 => 180, 6 => 90, 8 => 270}.fetch(orientation, 0), native_ppi: ppi(vimage))
        end

        def orientation_of(vimage)
          (vimage.get_typeof("orientation") != 0) ? vimage.get("orientation") : nil
        end

        # libvips resolutions are pixels per millimetre; 1.0 px/mm is its "unknown" default.
        def resolutions(vimage)
          x = vimage.xres * 25.4
          y = vimage.yres * 25.4
          (x > 25.5 || y > 25.5) ? [x, y] : nil
        end

        def ppi(vimage)
          res = resolutions(vimage)
          res&.max&.round(2)
        end

        def aspect_scale(vimage)
          x, y = resolutions(vimage)
          return nil unless x && y && x.positive? && y.positive?
          return nil if (x - y).abs / [x, y].max <= ASPECT_TOLERANCE

          (x < y) ? [y / x, 1.0] : [1.0, x / y]
        end

        def corrected_size(vimage)
          hscale, vscale = aspect_scale(vimage) || [1.0, 1.0]
          [(vimage.width * hscale).round, (vimage.height * vscale).round]
        end

        # Resamples the lower-resolution axis up (standard fax: 204×98 DPI is stored squashed 2:1).
        def correct_aspect(vimage)
          hscale, vscale = aspect_scale(vimage)
          return [vimage, nil] unless hscale

          width, height = corrected_size(vimage)
          check_pixels!(width, height)
          resized = vimage.resize(hscale, vscale: vscale, kernel: :linear)
          [resized, resolutions(vimage).map { |r| r.round(1) }]
        end
      end

      # PDF pages rendered in-process by libvips' pdfload (opt-in, see the class comment).
      class PdfDocument < Document
        include Pipeline

        def initialize(source, config, password)
          super(source)
          @config = config
          @password = password
          header = load(0, 72)
          @page_count = (header.get_typeof("n-pages") != 0) ? header.get("n-pages") : 1
          @infos = {}
          @mutex = Mutex.new
        end

        attr_reader :page_count

        # Sizes in points of the page as displayed (pdfload applies /Rotate).
        def page_info(number)
          check_page!(number)
          @mutex.synchronize do
            @infos[number] ||= begin
              vimage = load(number - 1, 72)
              PageInfo.new(number: number, width: vimage.width, height: vimage.height, unit: :pt, rotation: 0, native_ppi: nil)
            end
          end
        end

        # (see Document#render)
        def render(number, dpi: nil, timeout: nil) # timeout: in-process, cannot be enforced
          check_page!(number)
          dpi ||= @config.default_dpi
          vips_call do
            image = to_image(load(number - 1, dpi))
            Page.new(number: number, image: image, dpi: dpi, scale_to_base: 1.0, metadata: {loader: :vips})
          end
        end

        private

        def load(index, dpi)
          options = {page: index, dpi: dpi, background: [255]}
          options[:password] = @password if @password
          Pipeline.load_fresh("pdfload", source.path, **options)
        rescue ::Vips::Error => e
          raise password_error(e) if e.message.match?(/encrypted|password/i)

          raise RenderError.new("libvips pdfload failed on #{source.name}: #{Pipeline.error_summary(e, lines: 1)}", stderr: e.message[0, 4096])
        end

        def password_error(error)
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
