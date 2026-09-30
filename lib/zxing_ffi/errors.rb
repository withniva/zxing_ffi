# frozen_string_literal: true

module ZXingFFI
  # Base class for every error raised by this gem.
  class Error < StandardError; end

  # No usable libZXing could be found. The message lists every path that was tried.
  class LibraryNotFound < Error; end

  # A libZXing was found but its version or symbols are not supported.
  class IncompatibleLibrary < Error
    # @return [String, nil] the version reported by the library, if any
    attr_reader :version

    def initialize(message = nil, version: nil)
      @version = version
      super(message)
    end
  end

  # An optional native feature is missing (e.g. +try_denoise+ without ZXING_EXPERIMENTAL_API).
  class NotSupported < Error; end

  # No loader (or transformer) able to handle the input is installed.
  class LoaderUnavailable < Error; end

  # The input is not a recognised image or PDF.
  class UnsupportedInput < Error; end

  # The PDF is encrypted and no password was given.
  class PasswordRequired < Error; end

  # The PDF is encrypted and the given password was rejected.
  class IncorrectPassword < PasswordRequired; end

  # An external renderer or in-process loader failed.
  class RenderError < Error
    # @return [String, nil] (truncated) stderr of the failed subprocess
    attr_reader :stderr
    # @return [Integer, nil] exit status of the failed subprocess
    attr_reader :exit_status

    def initialize(message = nil, stderr: nil, exit_status: nil)
      @stderr = stderr
      @exit_status = exit_status
      super(message)
    end
  end

  # A subprocess or page exceeded its time budget.
  class TimeoutError < Error; end

  # A resource limit (pixels, pages, output size, ...) was exceeded.
  class LimitExceeded < Error
    # @return [Symbol, nil] name of the limit, e.g. +:max_pixels+
    attr_reader :limit
    # @return [Numeric, nil] the offending value
    attr_reader :value

    def initialize(message = nil, limit: nil, value: nil)
      @limit = limit
      @value = value
      super(message)
    end
  end

  # ZXing_ReadBarcodes returned NULL.
  class DecodeError < Error; end
end
