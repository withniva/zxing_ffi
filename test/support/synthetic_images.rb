# frozen_string_literal: true

module ZXingFFI
  # Small in-memory test images that need neither fixtures nor external tools.
  module SyntheticImages
    # QR code (version 1, EC level M) for "zxing_ffi test", encoded once with rqrcode (an encoder independent
    # of zxing-cpp). "#" = dark module.
    QR_TEXT = "zxing_ffi test"
    QR_MODULES = [
      "#######..#.#..#######",
      "#.....#.##....#.....#",
      "#.###.#.###...#.###.#",
      "#.###.#.##.#..#.###.#",
      "#.###.#..#..#.#.###.#",
      "#.....#...#.#.#.....#",
      "#######.#.#.#.#######",
      "........###.#........",
      "#.....#.#######..###.",
      "###.#..#.#.#.##....#.",
      "##..#.#.##.##.#...##.",
      "##..##.#..##.#..###.#",
      ".######....###..##.#.",
      "........#..#..#.#..##",
      "#######....###...###.",
      "#.....#....##.##.##..",
      "#.###.#..#.##.#.#..##",
      "#.###.#..#.....#.#...",
      "#.###.#..#..###.##.##",
      "#.....#..##.##.####..",
      "#######.##.####....#."
    ].freeze

    module_function

    # Renders a module matrix into 8-bit luminance pixels, optionally placed on a larger canvas.
    # rotate: quarter turns clockwise (0..3) applied to the matrix before rendering.
    # @return [Array(String, Integer, Integer)] pixels, width, height
    def render(modules = QR_MODULES, scale: 4, quiet: 4, invert: false, canvas: nil, offset: nil, rotate: 0)
      modules = rotate_matrix(modules, rotate)
      rows = modules.size
      cols = modules.first.size
      symbol_w = (cols + 2 * quiet) * scale
      symbol_h = (rows + 2 * quiet) * scale
      width, height = canvas || [symbol_w, symbol_h]
      ox, oy = offset || [0, 0]
      raise ArgumentError, "symbol does not fit the canvas" if ox + symbol_w > width || oy + symbol_h > height

      dark, light = invert ? [0xFF, 0x00] : [0x00, 0xFF]
      pixels = ("\xFF".b * (width * height))
      if invert # the symbol area (incl. quiet zone) is inverted, the rest of the canvas stays white
        symbol_h.times { |y| pixels[(oy + y) * width + ox, symbol_w] = light.chr * symbol_w }
      end
      run = dark.chr * scale
      modules.each_with_index do |row, my|
        row.each_char.with_index do |cell, mx|
          next unless cell == "#"

          x0 = ox + (mx + quiet) * scale
          y0 = oy + (my + quiet) * scale
          scale.times { |dy| pixels[(y0 + dy) * width + x0, scale] = run }
        end
      end
      [pixels, width, height]
    end

    # Quarter-turn clockwise rotations of a module matrix.
    def rotate_matrix(modules, quarter_turns)
      grid = modules.map(&:chars)
      (quarter_turns % 4).times { grid = grid.transpose.map(&:reverse) }
      grid.map(&:join)
    end

    # @return [Image] the QR as a :lum image
    def qr_image(**options)
      pixels, width, height = render(**options)
      Image.new(pixels, width: width, height: height)
    end

    # The same pixels in another pixel format (each gray value replicated; alpha 255).
    def convert(pixels, format)
      order = {rgb: "ggg", bgr: "ggg", rgba: "ggga", argb: "aggg", bgra: "ggga", abgr: "aggg", lum_a: "ga"}.fetch(format)
      out = pixels.each_byte.map { |g| order.each_char.map { |c| (c == "a") ? 255 : g }.pack("C*") }
      out.join
    end

    # A blank white image.
    def blank(width: 64, height: 64, value: 255)
      Image.new((value.chr * (width * height)).b, width: width, height: height)
    end
  end
end
