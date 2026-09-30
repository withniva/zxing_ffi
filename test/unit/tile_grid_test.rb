# frozen_string_literal: true

require "test_helper"

module ZXingFFI
  class TileGridTest < Minitest::Test
    DEFAULTS = {min_tile: 1024, max_tile: 1536, overlap: 0.2}.freeze

    def grid(width, height, **options)
      Geometry.tile_grid(width, height, **options)
    end

    # Minimum overlap in whole pixels, computed exactly from the decimal fraction.
    def required_overlap(size, overlap)
      (Rational(overlap.to_s) * size).ceil
    end

    # Farthest extent of +count+ tiles of +size+ that overlap by the required minimum.
    def reach(count, size, overlap)
      size + (count - 1) * (size - required_overlap(size, overlap))
    end

    # Column and row spans ([offset, size] pairs) of a grid, asserting that it is their row-major product.
    def axes(tiles)
      columns = tiles.map { |x, _, w, _| [x, w] }.uniq
      rows = tiles.map { |_, y, _, h| [y, h] }.uniq

      assert_equal rows.product(columns).map { |(y, h), (x, w)| [x, y, w, h] }, tiles, "row-major grid"
      [columns, rows]
    end

    # Union of the spans as disjoint [start, end) intervals.
    def union(spans)
      spans.map { |offset, size| [offset, offset + size] }.sort.each_with_object([]) do |(start, stop), merged|
        if merged.any? && start <= merged.last[1]
          merged.last[1] = [merged.last[1], stop].max
        else
          merged << [start, stop]
        end
      end
    end

    # Every documented property of the tiles along one axis of +length+ pixels.
    def assert_axis(spans, length, min_tile:, max_tile:, overlap:)
      label = "length #{length}, tiles #{min_tile}..#{max_tile}, overlap #{overlap}"
      offsets = spans.map(&:first)
      sizes = spans.map(&:last).uniq
      size = sizes.first

      assert_equal [[0, length]], union(spans), "#{label}: covers every pixel"
      assert(spans.all? { |offset, span| offset >= 0 && offset + span <= length }, "#{label}: inside the image")
      assert_equal offsets.sort.uniq, offsets, "#{label}: strictly increasing offsets"
      assert_equal 1, sizes.size, "#{label}: one tile size per axis"
      assert_equal length, offsets.last + size, "#{label}: last tile aligned to the far edge"

      if length <= max_tile
        assert_equal [[0, length]], spans, "#{label}: one tile spans the side"
        return
      end

      assert_operator size, :>=, min_tile, label
      assert_operator size, :<=, max_tile, label
      offsets.each_cons(2) do |left, right|
        assert_operator left + size - right, :>=, required_overlap(size, overlap), "#{label}: overlap at #{right}"
      end
      # Minimal count: one tile fewer cannot cover the side, even at max_tile.
      assert_operator reach(spans.size - 1, max_tile, overlap), :<, length, "#{label}: fewer tiles would do"
      # Smallest size for that count: one pixel less breaks min_tile or the overlap.
      if size > min_tile
        assert_operator reach(spans.size, size - 1, overlap), :<, length, "#{label}: smaller tiles would do"
      end
    end

    def assert_valid_grid(width, height, **options)
      options = DEFAULTS.merge(options)
      tiles = grid(width, height, **options)
      columns, rows = axes(tiles)

      assert(tiles.flatten.all?(Integer), "Integer tiles")
      assert_axis(columns, width, **options)
      assert_axis(rows, height, **options)
      tiles
    end

    # Fewest tiles, then the smallest tile size, by trying every count and size in turn.
    def brute_force(length, min_tile, max_tile, overlap)
      return [1, length] if length <= max_tile

      (2..length).each do |count|
        (min_tile..max_tile).each do |size|
          return [count, size] if reach(count, size, overlap) >= length
        end
      end
    end

    def test_letter_page_at_300_dpi
      expected = [
        [0, 0, 1417, 1270], [1133, 0, 1417, 1270],
        [0, 1015, 1417, 1270], [1133, 1015, 1417, 1270],
        [0, 2030, 1417, 1270], [1133, 2030, 1417, 1270]
      ]

      assert_equal expected, assert_valid_grid(2550, 3300)
    end

    def test_letter_page_at_600_dpi
      tiles = assert_valid_grid(5100, 6600)
      columns, rows = axes(tiles)

      assert_equal [0, 1200, 2400, 3600].map { |x| [x, 1500] }, columns
      assert_equal [0, 1056, 2112, 3168, 4224, 5280].map { |y| [y, 1320] }, rows
      assert_equal 24, tiles.size
    end

    def test_image_that_fits_in_one_tile
      assert_equal [[0, 0, 1024, 1024]], assert_valid_grid(1024, 1024)
      assert_equal [[0, 0, 1536, 1536]], assert_valid_grid(1536, 1536)
      assert_equal [[0, 0, 500, 1536]], assert_valid_grid(500, 1536)
      assert_equal [[0, 0, 100, 50]], assert_valid_grid(100, 50) # smaller than min_tile
    end

    def test_one_pixel_over_the_maximum
      assert_equal [[0, 0, 1024, 10], [513, 0, 1024, 10]], assert_valid_grid(1537, 10)
      assert_equal [[0, 0, 10, 1024], [0, 513, 10, 1024]], assert_valid_grid(10, 1537)
    end

    def test_single_pixel_image
      assert_equal [[0, 0, 1, 1]], assert_valid_grid(1, 1)
    end

    def test_exact_multiples_of_the_tile_sizes
      [[3072, 3072], [1536, 4608], [2048, 2048], [4096, 1024], [15_360, 1536]].each do |w, h|
        assert_valid_grid(w, h)
      end
    end

    def test_lengths_at_the_tile_count_boundaries
      (2..6).each do |count|
        boundary = 1536 + (count - 1) * (1536 - 308) # count tiles of 1536 px overlapping by ceil(307.2) px
        tiles = assert_valid_grid(boundary, 1)

        assert_equal [1536] * count, tiles.map { |_, _, w, _| w }
        assert_equal count + 1, assert_valid_grid(boundary + 1, 1).size
      end
    end

    def test_extreme_aspect_ratios
      tall = assert_valid_grid(100, 20_000)
      wide = assert_valid_grid(20_000, 100)

      assert_equal 17, tall.size
      assert(tall.all? { |x, _, w, h| x.zero? && w == 100 && h == 1450 })
      assert_equal tall.map { |x, y, w, h| [y, x, h, w] }, wide
      assert_valid_grid(1, 100_000)
    end

    def test_huge_image
      assert_equal 82 * 82, assert_valid_grid(100_000, 100_000).size
    end

    def test_custom_parameters
      assert_valid_grid(1000, 700, min_tile: 256, max_tile: 512, overlap: 0.25)
      assert_valid_grid(5000, 5000, min_tile: 1536, max_tile: 1536, overlap: 0.2)
      assert_valid_grid(3000, 3000, min_tile: 1, max_tile: 1536, overlap: 0.5)
      assert_equal grid(5000, 5000, overlap: 0.25), grid(5000, 5000, overlap: Rational(1, 4))
    end

    def test_zero_overlap_tiles_touch_without_gaps
      tiles = assert_valid_grid(4000, 10, min_tile: 1000, max_tile: 1000, overlap: 0)

      assert_equal [0, 1000, 2000, 3000], tiles.map(&:first)
    end

    def test_fixed_tile_size_spreads_the_slack_evenly
      columns, = axes(assert_valid_grid(2500, 1, min_tile: 1000, max_tile: 1000, overlap: 0))

      assert_equal [[0, 1000], [750, 1000], [1500, 1000]], columns
    end

    def test_offsets_are_rounded_to_the_nearest_pixel
      columns, = axes(assert_valid_grid(3503, 1, min_tile: 1000, max_tile: 1000, overlap: 0))

      assert_equal [0, 834, 1669, 2503], columns.map(&:first) # 2503 / 3 = 834.33, 2 × 2503 / 3 = 1668.67
    end

    def test_row_major_order
      tiles = grid(4000, 3000)

      assert_equal tiles.sort_by { |x, y, _, _| [y, x] }, tiles
      assert_equal [0, 0], tiles.first.first(2)
    end

    def test_deterministic
      first = grid(2550, 3300)
      grid(777, 20_000)

      assert_equal first, grid(2550, 3300)
      assert_equal grid(5100, 6600), grid(5100, 6600)
    end

    def test_matches_an_exhaustive_search_on_small_parameters
      [[10, 30, 0.2], [5, 16, 0.5], [30, 30, 0], [1, 7, 0.3], [8, 9, 0.1], [12, 20, 0.25]].each do |min_tile, max_tile, overlap|
        (1..300).each do |length|
          spans = grid(length, 1, min_tile:, max_tile:, overlap:).map { |x, _, w, _| [x, w] }

          assert_axis(spans, length, min_tile:, max_tile:, overlap:)
          assert_equal brute_force(length, min_tile, max_tile, overlap), [spans.size, spans.first.last],
            "length #{length}, tiles #{min_tile}..#{max_tile}, overlap #{overlap}"
        end
      end
    end

    def test_random_sizes_and_parameters
      random = Random.new(1_024_1536)
      200.times do
        min_tile = random.rand(16..2000)
        max_tile = random.rand(min_tile..(min_tile * 2))
        overlap = [0, 0.1, 0.15, 0.2, 0.25, 0.3, 0.5, 0.6].sample(random: random)

        assert_valid_grid(random.rand(1..30_000), random.rand(1..30_000), min_tile:, max_tile:, overlap:)
      end
    end

    def test_rejects_invalid_sizes
      [0, -1, 1.5, 10.0, nil, "10", Float::NAN].each do |bad|
        assert_raises(ArgumentError, "width #{bad.inspect}") { grid(bad, 10) }
        assert_raises(ArgumentError, "height #{bad.inspect}") { grid(10, bad) }
        assert_raises(ArgumentError, "min_tile #{bad.inspect}") { grid(10, 10, min_tile: bad) }
        assert_raises(ArgumentError, "max_tile #{bad.inspect}") { grid(10, 10, max_tile: bad) }
      end
      assert_raises(ArgumentError) { grid(10, 10, min_tile: 2000, max_tile: 1000) }
    end

    def test_rejects_invalid_overlaps
      [-0.1, 1, 1.0, 1.5, Float::NAN, Float::INFINITY, nil, "0.2", Complex(0.2, 0)].each do |bad|
        assert_raises(ArgumentError, "overlap #{bad.inspect}") { grid(10, 10, overlap: bad) }
      end
      error = assert_raises(ArgumentError) { grid(10, 10, min_tile: 1, max_tile: 3, overlap: 0.9) }
      assert_match(/no room/, error.message)
    end
  end
end
