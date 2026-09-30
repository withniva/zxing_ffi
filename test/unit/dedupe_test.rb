# frozen_string_literal: true

require "test_helper"

module ZXingFFI
  class DedupeTest < Minitest::Test
    Quad = Geometry::Quad
    # Stand-in for Barcode: Dedupe only needs #format, #bytes and #position. +tag+ names the detection.
    FakeBarcode = Data.define(:tag, :format, :bytes, :position)

    # Wraps a quad and counts the geometric queries made on it.
    class CountingQuad
      attr_reader :calls

      def initialize(quad)
        @quad = quad
        @calls = 0
      end

      def center
        @calls += 1
        @quad.center
      end

      def side_lengths
        @calls += 1
        @quad.side_lengths
      end

      def area
        @calls += 1
        @quad.area
      end

      def points
        @calls += 1
        @quad.points
      end
    end

    def barcode(tag, position, format: :qr_code, bytes: "payload".b)
      FakeBarcode.new(tag:, format:, bytes:, position:)
    end

    # Axis-aligned rectangle centered on (cx, cy).
    def rectangle(cx, cy, width, height)
      half_w = width / 2.0
      half_h = height / 2.0
      Quad.from_points([[cx - half_w, cy - half_h], [cx + half_w, cy - half_h], [cx + half_w, cy + half_h], [cx - half_w, cy + half_h]])
    end

    def square(cx, cy, side = 100)
      rectangle(cx, cy, side, side)
    end

    def assert_duplicate(a, b)
      assert Dedupe.duplicate?(a, b), "#{a.tag} and #{b.tag} should be duplicates"
      assert Dedupe.duplicate?(b, a), "#{b.tag} and #{a.tag} should be duplicates"
    end

    def refute_duplicate(a, b)
      refute Dedupe.duplicate?(a, b), "#{a.tag} and #{b.tag} should not be duplicates"
      refute Dedupe.duplicate?(b, a), "#{b.tag} and #{a.tag} should not be duplicates"
    end

    # Tiles pass: a tile boundary cuts a wide PDF417 (751x150 px) and the left part still decodes. Its center is
    # ~110 px from the full symbol's (far beyond 0.25 x 150), but it lies inside the full symbol's box.
    def test_partial_read_of_a_wide_symbol_is_a_duplicate
      full = barcode(:full, rectangle(1792, 1583, 751, 150), format: :pdf417)
      partial = barcode(:partial, rectangle(1683, 1583, 531, 150), format: :pdf417)

      assert_duplicate full, partial
      assert_equal [:full], Dedupe.call([full, partial]).map(&:tag)
      assert_equal [:partial], Dedupe.call([partial, full]).map(&:tag), "the earliest pass wins"
    end

    def test_identical_labels_side_by_side_are_not_duplicates_even_when_close
      left = barcode(:left, rectangle(400, 500, 300, 60), format: :pdf417)
      right = barcode(:right, rectangle(720, 500, 300, 60), format: :pdf417) # 20 px gap between the boxes

      refute_duplicate left, right
    end

    def test_overlap_rule_needs_equal_content
      full = barcode(:full, rectangle(1792, 1583, 751, 150), format: :pdf417)
      other = barcode(:other, rectangle(1683, 1583, 531, 150), format: :pdf417, bytes: "different".b)

      refute_duplicate full, other
    end

    def test_degenerate_boxes_do_not_swallow_other_detections
      # two parallel scan lines of the same 1D content 80 px apart (e.g. two stacked identical labels)
      top = barcode(:top, Quad.from_points([[100, 100], [400, 100], [400, 100], [100, 100]]), format: :code_128)
      bottom = barcode(:bottom, Quad.from_points([[100, 180], [400, 180], [400, 180], [100, 180]]), format: :code_128)

      refute_duplicate top, bottom
    end

    def test_same_format_bytes_and_position_is_a_duplicate
      a = barcode(:a, square(500, 500))
      b = barcode(:b, square(500, 500))

      assert_duplicate a, b
      assert_equal [a], Dedupe.call([a, b])
    end

    def test_different_format_is_not_a_duplicate
      a = barcode(:a, square(500, 500), format: :qr_code)
      b = barcode(:b, square(500, 500), format: :micro_qr_code)

      refute_duplicate a, b
      assert_equal [a, b], Dedupe.call([a, b])
    end

    def test_different_bytes_is_not_a_duplicate
      a = barcode(:a, square(500, 500), bytes: "one".b)
      b = barcode(:b, square(500, 500), bytes: "two".b)

      refute_duplicate a, b
      assert_equal [a, b], Dedupe.call([a, b])
    end

    def test_bytes_are_compared_as_binary
      a = barcode(:a, square(500, 500), bytes: "caf\xC3\xA9".b)
      b = barcode(:b, square(500, 500), bytes: "café")

      refute_equal a.bytes, b.bytes # String#== also looks at the encoding
      assert_duplicate a, b
      assert_equal [a], Dedupe.call([a, b])
    end

    def test_near_centers_are_duplicates_and_far_ones_are_not
      a = barcode(:a, square(500, 500))

      assert_duplicate a, barcode(:near, square(512, 495))
      refute_duplicate a, barcode(:far, square(800, 500))
    end

    # For full-size quads the containment rule decides: centers within 0.25 × the shorter side always lie
    # inside each other's quad, so the boundary moves to the quad's edge.
    def test_overlapping_quads_are_duplicates_up_to_the_edge
      a = barcode(:a, square(500, 500, 100)) # spans 450..550

      assert_duplicate a, barcode(:right, square(550, 500, 100)) # center on a's edge: inclusive
      assert_duplicate a, barcode(:diagonal, square(540, 530, 100))
      refute_duplicate a, barcode(:right_out, square(550.01, 500, 100)) # neither center inside the other quad
      refute_duplicate a, barcode(:below_out, square(500, 550.01, 100))
    end

    # Tiny quads: 0.25 × side is below 10 px and the quads are too small to contain each other's centers, so only
    # the 10 px minimum distance makes them duplicates.
    def test_threshold_is_at_least_ten_pixels
      a = barcode(:a, square(500, 500, 8)) # half side 4
      point = barcode(:point, square(500, 500, 0)) # zero-size quad

      assert_duplicate a, barcode(:inside, square(506, 508, 8)) # exactly 10
      refute_duplicate a, barcode(:outside, square(506, 508.01, 8))
      assert_duplicate point, barcode(:point_inside, square(510, 500, 0))
      refute_duplicate point, barcode(:point_outside, square(510.01, 500, 0))
    end

    def test_a_small_quad_inside_a_big_one_is_a_duplicate_even_far_from_its_center
      big = barcode(:big, square(500, 500, 100)) # spans 450..550

      assert_duplicate big, barcode(:inside, square(545, 545, 20)) # 63.6 px from the big center, but inside it
      refute_duplicate big, barcode(:beside, square(560, 500, 20)) # neither center inside the other quad
    end

    def test_wide_symbols_overlapping_along_their_length_are_duplicates
      a = barcode(:a, rectangle(500, 500, 400, 80)) # spans 300..700

      assert_duplicate a, barcode(:overlapping, rectangle(700, 500, 400, 80)) # center on a's edge
      refute_duplicate a, barcode(:next_label, rectangle(900, 500, 400, 80)) # touching, not overlapping centers
    end

    def test_containment_uses_the_rotated_quad_not_its_bounding_box
      diamond = barcode(:diamond, Geometry::Affine.rotation(45, 500, 500).apply_quad(square(500, 500, 100)))

      assert_duplicate diamond, barcode(:inside, square(530, 530, 100)) # |dx| + |dy| = 60 < 70.7
      # inside the diamond's bounding box (429..571) but outside the diamond, and the diamond's center is outside it
      refute_duplicate diamond, barcode(:corner, square(560, 560, 100))
    end

    # Linear codes found on a single scan line have flat quads; their size is the longer side.
    def test_degenerate_linear_quads_use_their_longer_side
      ean = {format: :ean_13, bytes: "4006381333931".b}
      a = barcode(:line, rectangle(500, 500, 300, 0), **ean) # 0.25 × 300 = 75 px

      assert_duplicate a, barcode(:lower_line, rectangle(500, 575, 300, 0), **ean)
      assert_duplicate a, barcode(:thin_line, rectangle(530, 560, 300, 2), **ean)
      refute_duplicate a, barcode(:far_line, rectangle(500, 575.5, 300, 0), **ean)
    end

    # Moved 70 px vertically: the quads no longer contain each other's centers, so the distance rule decides.
    def test_degenerate_means_shorter_side_under_ten_percent
      at_ten_percent = barcode(:ten, rectangle(500, 500, 300, 30)) # not degenerate: size 30 → 10 px
      under_ten_percent = barcode(:under, rectangle(500, 500, 300, 29.9)) # degenerate: size 300 → 75 px

      refute_duplicate at_ten_percent, barcode(:ten_moved, rectangle(500, 570, 300, 30))
      assert_duplicate under_ten_percent, barcode(:under_moved, rectangle(500, 570, 300, 29.9))
    end

    def test_degenerate_and_full_quads_compare_with_the_smaller_size
      line = barcode(:line, rectangle(500, 500, 300, 0)) # size 300; a line contains nothing
      full = barcode(:full, rectangle(500, 520, 300, 80)) # size 80 → 20 px; spans y 480..560, contains the line's center

      assert_duplicate line, full
      refute_duplicate line, barcode(:full_lower, rectangle(500, 545, 300, 80)) # 45 px > 20 px and y 505..585
    end

    def test_repeated_labels_far_apart_are_kept
      labels = [square(300, 300), square(900, 300), square(300, 1200), square(420, 300)].each_with_index.map do |quad, i|
        barcode(i, quad)
      end

      assert_equal labels, Dedupe.call(labels)
    end

    def test_keeps_the_first_occurrence
      first = barcode(:base_pass, square(500, 500))
      later = barcode(:tiles_pass, square(503, 498))

      assert_equal [first], Dedupe.call([first, later])
      assert_same first, Dedupe.call([first, later]).first
      assert_same later, Dedupe.call([later, first]).first
    end

    def test_output_keeps_the_input_order
      a1 = barcode(:a1, square(100, 100), bytes: "a".b)
      b1 = barcode(:b1, square(900, 900), bytes: "b".b)
      a2 = barcode(:a2, square(104, 97), bytes: "a".b) # duplicate of a1
      c1 = barcode(:c1, square(100, 100), bytes: "c".b)
      b2 = barcode(:b2, square(2000, 2000), bytes: "b".b) # same content far away: a second label
      a3 = barcode(:a3, square(90, 110), bytes: "a".b, format: :data_matrix)
      b3 = barcode(:b3, square(1990, 2010), bytes: "b".b) # duplicate of b2

      assert_equal %i[a1 b1 c1 b2 a3], Dedupe.call([a1, b1, a2, c1, b2, a3, b3]).map(&:tag)
    end

    def test_compares_with_kept_barcodes_only
      a = barcode(:a, square(500, 500)) # spans 450..550
      b = barcode(:b, square(549, 500)) # center inside a: dropped
      c = barcode(:c, square(598, 500)) # center inside the dropped b, but not inside a (and a's not inside c): kept

      assert_equal %i[a c], Dedupe.call([a, b, c]).map(&:tag)
    end

    def test_empty_and_single_inputs
      one = barcode(:one, square(1, 1))

      assert_equal [], Dedupe.call([])
      assert_equal [one], Dedupe.call([one])
    end

    def test_returns_a_new_array_and_leaves_the_input_alone
      input = [barcode(:a, square(500, 500)), barcode(:b, square(500, 500))]
      original = input.dup
      result = Dedupe.call(input)

      refute_same input, result
      assert_equal original, input
    end

    def test_accepts_any_enumerable
      a = barcode(:a, square(500, 500))
      b = barcode(:b, square(501, 500))

      assert_equal [a], Dedupe.call([a, b].each)
    end

    def test_compares_positions_only_within_a_format_and_bytes_group
      quads = Array.new(2000) { CountingQuad.new(square(500, 500)) }
      detections = quads.each_with_index.map { |quad, i| barcode(i, quad, bytes: "label-#{i}".b) }

      assert_equal detections, Dedupe.call(detections)
      assert_equal 0, quads.sum(&:calls)
    end

    def test_many_detections
      first_pass = Array.new(1000) do |i|
        # 250 payloads, each printed on four labels in a 40 × 25 grid of labels 300 px apart
        barcode([i, :base], square(100 + (i % 40) * 300, 100 + (i / 40) * 300, 120), bytes: "label-#{i % 250}".b)
      end
      second_pass = first_pass.map do |found|
        center = found.position.center
        barcode([found.tag.first, :tiles], square(center.x + 3, center.y - 4, 118), bytes: found.bytes)
      end

      assert_equal first_pass, Dedupe.call(first_pass + second_pass)
      assert_equal first_pass, Dedupe.call(first_pass.zip(second_pass).flatten)
      assert_equal second_pass, Dedupe.call(second_pass + first_pass)
    end

    def test_random_detections_satisfy_the_dedupe_invariants
      random = Random.new(310)
      60.times do
        detections = Array.new(random.rand(0..60)) do |i|
          cx = [200, 260, 1000].sample(random: random) + random.rand(-30.0..30.0)
          cy = [200, 1000].sample(random: random) + random.rand(-30.0..30.0)
          quad =
            if random.rand < 0.3
              rectangle(cx, cy, random.rand(50.0..400.0), random.rand(0.0..3.0)) # linear, one scan line
            else
              square(cx, cy, random.rand(10.0..150.0))
            end
          barcode(i, quad, format: %i[qr_code ean_13].sample(random: random), bytes: %w[a b].sample(random: random).b)
        end
        result = Dedupe.call(detections)

        assert_equal result, detections.select { |found| result.include?(found) }, "an ordered subset of the input"
        result.combination(2).each do |x, y|
          refute Dedupe.duplicate?(x, y), "kept duplicates #{x.tag} and #{y.tag}"
        end
        (detections - result).each do |dropped|
          assert(result.any? { |kept| kept.tag < dropped.tag && Dedupe.duplicate?(kept, dropped) },
            "#{dropped.tag} was dropped without an earlier kept duplicate")
        end
        assert_equal result, Dedupe.call(result), "idempotent"
        detections.combination(2).each do |x, y|
          assert_equal Dedupe.duplicate?(x, y), Dedupe.duplicate?(y, x), "symmetric for #{x.tag} and #{y.tag}"
        end
      end
    end
  end
end
