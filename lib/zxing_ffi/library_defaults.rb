# frozen_string_literal: true

module ZXingFFI
  # The loaded library's ReaderOptions defaults, read through the get* functions when first referenced.
  # Never assume them: e.g. zxing-cpp 3.1.1 enables try_invert and uses the HRI text mode by default.
  LIBRARY_DEFAULTS = Reader.library_defaults.freeze
end
