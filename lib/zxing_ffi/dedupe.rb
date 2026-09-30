# frozen_string_literal: true

module ZXingFFI
  # Removes barcodes reported more than once for the same page, e.g. by several passes.
  #
  # Two barcodes are duplicates when they have the same +format+, the same +bytes+, and either
  # - quad centers (in base-image coordinates) at most +max(10 px, 0.25 × s)+ apart, where +s+ is the size of the
  #   smaller quad — a quad's size is its shorter side, except for degenerate quads whose shorter side is under 10%
  #   of the longer one (linear codes located on a single scan line): their size is the longer side; or
  # - the center of one lies inside the other's quad. This catches partial reads of wide symbols: a PDF417
  #   cut by a tile boundary in the tiles pass can still decode, but its quad covers only part of the symbol.
  # Identical content at different, non-overlapping positions is not a duplicate: repeated labels are legitimate.
  #
  # Barcodes are duck-typed: anything with +#format+, +#bytes+ and a {Geometry::Quad} +#position+ works.
  module Dedupe
    # Center distance in pixels within which equal barcodes are always duplicates.
    MIN_DISTANCE = 10
    # Center distance, as a fraction of the smaller quad's size, within which equal barcodes are duplicates.
    RELATIVE_DISTANCE = 0.25
    # A quad whose shorter side is below this fraction of its longer side is degenerate.
    DEGENERATE_RATIO = 0.1

    class << self
      # Drops duplicates, keeping the first occurrence of each barcode and the order of the input.
      #
      # Each barcode is compared only with the barcodes kept so far that have the same format and bytes.
      #
      # @param barcodes [Enumerable<Barcode>] in pass order (earliest pass first)
      # @return [Array<Barcode>] a new Array
      def call(barcodes)
        kept = Hash.new { |groups, key| groups[key] = [] }
        barcodes.select do |barcode|
          group = kept[key(barcode)]
          next false if group.any? { |other| near?(other.position, barcode.position) }

          group << barcode
          true
        end
      end

      # @param a [Barcode]
      # @param b [Barcode]
      # @return [Boolean] whether +a+ and +b+ are the same symbol reported twice (symmetric)
      def duplicate?(a, b)
        key(a) == key(b) && near?(a.position, b.position)
      end

      private

      def key(barcode)
        bytes = barcode.bytes
        [barcode.format, bytes.is_a?(String) ? bytes.b : bytes]
      end

      def near?(quad, other)
        quad.center.distance_to(other.center) <= [MIN_DISTANCE, RELATIVE_DISTANCE * [size(quad), size(other)].min].max ||
          inside?(quad.center, other) || inside?(other.center, quad)
      end

      # Whether +point+ lies inside +quad+ (edges included). Symbol quads are convex, so the point must be on the
      # same side of all four edges. Degenerate quads (linear codes found on a single scan line) contain nothing.
      def inside?(point, quad)
        return false if quad.area < 1

        corners = quad.points
        sides = corners.each_with_index.map do |corner, i|
          following = corners[(i + 1) % corners.size]
          (following.x - corner.x) * (point.y - corner.y) - (following.y - corner.y) * (point.x - corner.x)
        end
        sides.all? { |side| side >= 0 } || sides.all? { |side| side <= 0 }
      end

      def size(quad)
        shorter, longer = quad.side_lengths.minmax
        (shorter < DEGENERATE_RATIO * longer) ? longer : shorter
      end
    end
  end
end
