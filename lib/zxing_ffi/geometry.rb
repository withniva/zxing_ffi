# frozen_string_literal: true

module ZXingFFI
  # Plane geometry for barcode positions: {Point}, {Quad}, {Affine}, the canvas transform of rotated
  # passes ({.rotation_canvas}) and the tile layout of the tiles pass ({.tile_grid}).
  #
  # Coordinates are image pixels: origin at the top-left corner, x to the right, y down. An image of width w
  # and height h covers the continuous region [0, w] × [0, h]. Angles are in degrees; positive angles turn
  # clockwise as displayed.
  module Geometry
    # [cos, sin] of 0°, 90°, 180° and 270°, exact so that quarter turns map Integer points to Integer points.
    QUARTER_TURNS = [[1, 0], [0, 1], [-1, 0], [0, -1]].freeze
    # Floating-point noise ignored before a rotated canvas extent is rounded up to whole pixels.
    CANVAS_TOLERANCE = 1e-6
    # Floating-point noise ignored when converting the overlap fraction to whole pixels.
    OVERLAP_TOLERANCE = 1e-9
    private_constant :QUARTER_TURNS, :CANVAS_TOLERANCE, :OVERLAP_TOLERANCE

    # A point in image coordinates. Coordinates keep their numeric type (usually Integer or Float).
    #
    # @!attribute [r] x
    #   @return [Numeric] horizontal coordinate, growing to the right
    # @!attribute [r] y
    #   @return [Numeric] vertical coordinate, growing downwards
    Point = Data.define(:x, :y) do
      # Converts +value+ to a Point.
      #
      # @param value [Point, Array(Numeric, Numeric)] a Point (returned as is) or an +[x, y]+ pair
      # @return [Point]
      # @raise [ArgumentError] if +value+ is neither
      def self.from(value)
        case value
        when Point then value
        when Array
          raise ArgumentError, "expected an [x, y] pair, got #{value.inspect}" unless value.size == 2

          new(*value)
        else
          raise ArgumentError, "expected a Point or an [x, y] pair, got #{value.inspect}"
        end
      end

      # @raise [ArgumentError] if a coordinate is not a finite real number
      def initialize(x:, y:)
        super(x: Geometry.number!(x, :x), y: Geometry.number!(y, :y))
      end

      # @param other [Point, Array(Numeric, Numeric)]
      # @return [Point] the component-wise sum
      def +(other)
        other = Point.from(other)
        with(x: x + other.x, y: y + other.y)
      end

      # @param other [Point, Array(Numeric, Numeric)]
      # @return [Point] the component-wise difference
      def -(other)
        other = Point.from(other)
        with(x: x - other.x, y: y - other.y)
      end

      # @param other [Point, Array(Numeric, Numeric)]
      # @return [Float] the Euclidean distance to +other+
      def distance_to(other)
        other = Point.from(other)
        Math.hypot(x - other.x, y - other.y)
      end

      # @return [Point] the point with both coordinates rounded to Integers (halves away from zero)
      def round
        with(x: x.round, y: y.round)
      end

      # @return [Array(Numeric, Numeric)] +[x, y]+
      def to_a
        [x, y]
      end
    end

    # The four corners of a barcode, named in the symbol's own orientation: +top_left+ is the corner that is
    # top-left when the symbol is upright, wherever it lies in the image. Corners may be given as {Point}s or
    # +[x, y]+ pairs.
    #
    # @!attribute [r] top_left
    #   @return [Point]
    # @!attribute [r] top_right
    #   @return [Point]
    # @!attribute [r] bottom_right
    #   @return [Point]
    # @!attribute [r] bottom_left
    #   @return [Point]
    Quad = Data.define(:top_left, :top_right, :bottom_right, :bottom_left) do
      # @param points [Array<Point, Array(Numeric, Numeric)>] exactly four corners, in the order top-left,
      #   top-right, bottom-right, bottom-left
      # @return [Quad]
      # @raise [ArgumentError] unless there are exactly four valid points
      def self.from_points(points)
        points = Array(points)
        raise ArgumentError, "expected 4 points, got #{points.size}" unless points.size == 4

        new(*points)
      end

      # @raise [ArgumentError] if a corner is not a Point or an +[x, y]+ pair
      def initialize(top_left:, top_right:, bottom_right:, bottom_left:)
        super(
          top_left: Point.from(top_left),
          top_right: Point.from(top_right),
          bottom_right: Point.from(bottom_right),
          bottom_left: Point.from(bottom_left)
        )
      end

      # @return [Array<Point>] +[top_left, top_right, bottom_right, bottom_left]+
      def points
        [top_left, top_right, bottom_right, bottom_left]
      end
      alias_method :to_a, :points

      # @return [Point] the mean of the four corners (Float coordinates)
      def center
        corners = points
        Point.new(corners.sum(&:x).fdiv(4), corners.sum(&:y).fdiv(4))
      end

      # @return [Array<Float>] lengths of the top, right, bottom and left sides
      def side_lengths
        corners = points
        corners.zip(corners.rotate).map { |from, to| from.distance_to(to) }
      end

      # @return [Float] length of the shortest side
      def shorter_side
        side_lengths.min
      end

      # @return [Float] length of the longest side
      def longer_side
        side_lengths.max
      end

      # Area enclosed by the corners (shoelace formula), whatever their winding order. Only meaningful for a
      # simple (not self-intersecting) quad.
      # @return [Float]
      def area
        corners = points
        corners.zip(corners.rotate).sum { |from, to| from.x * to.y - to.x * from.y }.abs.fdiv(2)
      end

      # @return [Array(Numeric, Numeric, Numeric, Numeric)] +[min_x, min_y, max_x, max_y]+
      def bounding_box
        xs = points.map(&:x)
        ys = points.map(&:y)
        [xs.min, ys.min, xs.max, ys.max]
      end

      # @param affine [Affine]
      # @return [Quad] the quad with every corner transformed (see {Affine#apply_quad})
      def transform(affine)
        raise ArgumentError, "expected an Affine, got #{affine.inspect}" unless affine.is_a?(Affine)

        affine.apply_quad(self)
      end

      # @return [Quad] the quad with every corner rounded to Integer coordinates
      def round
        map(&:round)
      end

      # Builds a new Quad from the block's result for each corner, keeping the corner roles.
      #
      # @yieldparam point [Point]
      # @yieldreturn [Point, Array(Numeric, Numeric)]
      # @return [Quad, Enumerator] an Enumerator without a block
      def map(&block)
        return enum_for(:map) unless block

        Quad.new(*points.map(&block))
      end

      # @return [Hash{Symbol => Hash{Symbol => Numeric}}] plain nested Hashes (JSON-friendly),
      #   e.g. +{top_left: {x: 0, y: 0}, top_right: {x: 10, y: 0}, ...}+
      def to_h(&block)
        hash = members.to_h { |corner| [corner, public_send(corner).to_h] }
        block ? hash.to_h(&block) : hash
      end
    end

    # An immutable 2-D affine transform: the top two rows of a 3×3 homogeneous matrix.
    #
    #   | a b c |    x' = a·x + b·y + c
    #   | d e f |    y' = d·x + e·y + f
    #
    # Coefficients keep their numeric type, so transforms built from Integers (translations, quarter turns)
    # map Integer points to Integer points exactly. Value semantics as for Arrays: +==+ compares coefficients
    # numerically, +eql?+ and +hash+ also compare their classes.
    #
    # Pass transforms are chained with {#compose} (mathematical order) or {#then} (pipeline order):
    #
    # @example Tile at (tx, ty) of a 2× upscaled image, back to base-image pixels
    #   to_base = Affine.scale(0.5).compose(Affine.translation(tx, ty))
    #   to_base = Affine.translation(tx, ty).then(Affine.scale(0.5)) # the same transform
    #
    # @!attribute [r] a
    #   @return [Numeric] x' coefficient of x
    # @!attribute [r] b
    #   @return [Numeric] x' coefficient of y
    # @!attribute [r] c
    #   @return [Numeric] x' translation
    # @!attribute [r] d
    #   @return [Numeric] y' coefficient of x
    # @!attribute [r] e
    #   @return [Numeric] y' coefficient of y
    # @!attribute [r] f
    #   @return [Numeric] y' translation
    Affine = Data.define(:a, :b, :c, :d, :e, :f) do
      class << self
        # @return [Affine] the transform that leaves every point in place
        def identity
          new(1, 0, 0, 0, 1, 0)
        end

        # @param dx [Numeric]
        # @param dy [Numeric]
        # @return [Affine] (x, y) → (x + dx, y + dy)
        def translation(dx, dy)
          new(1, 0, dx, 0, 1, dy)
        end

        # @param sx [Numeric]
        # @param sy [Numeric] defaults to +sx+ (uniform scale)
        # @return [Affine] (x, y) → (sx·x, sy·y)
        def scale(sx, sy = sx)
          new(sx, 0, 0, 0, sy, 0)
        end

        # Rotation by +degrees+ about (+cx+, +cy+), clockwise as displayed: the x axis (1, 0) turns towards
        # the y axis (0, 1), which points down. Multiples of 90° have exact Integer cos/sin coefficients.
        #
        # @param degrees [Numeric]
        # @param cx [Numeric]
        # @param cy [Numeric]
        # @return [Affine]
        def rotation(degrees, cx = 0, cy = 0)
          cos, sin = Geometry.cos_sin(degrees)
          Geometry.number!(cx, :cx)
          Geometry.number!(cy, :cy)
          new(cos, -sin, cx - cos * cx + sin * cy, sin, cos, cy - sin * cx - cos * cy)
        end
      end

      # @raise [ArgumentError] if a coefficient is not a finite real number
      def initialize(a:, b:, c:, d:, e:, f:)
        super(
          a: Geometry.number!(a, :a), b: Geometry.number!(b, :b), c: Geometry.number!(c, :c),
          d: Geometry.number!(d, :d), e: Geometry.number!(e, :e), f: Geometry.number!(f, :f)
        )
      end

      # Mathematical composition self ∘ other: the transform that applies +other+ first, then +self+
      # (the matrix product self × other), so +compose(other).apply(p) == apply(other.apply(p))+.
      #
      # @param other [Affine]
      # @return [Affine]
      def compose(other)
        raise ArgumentError, "expected an Affine, got #{other.inspect}" unless other.is_a?(Affine)

        Affine.new(
          a * other.a + b * other.d, a * other.b + b * other.e, a * other.c + b * other.f + c,
          d * other.a + e * other.d, d * other.b + e * other.e, d * other.c + e * other.f + f
        )
      end

      # Pipeline order: the transform that applies +self+ first, then +other+, i.e. +other.compose(self)+,
      # so +self.then(other).apply(p) == other.apply(apply(p))+. With a block and no argument this is
      # +Kernel#then+.
      #
      # @param other [Affine]
      # @return [Affine]
      def then(other = nil, &block)
        return super(&block) if other.nil? && block
        raise ArgumentError, "expected an Affine, got #{other.inspect}" unless other.is_a?(Affine)

        other.compose(self)
      end

      # @param point [Point, Array(Numeric, Numeric)]
      # @return [Point] the transformed point
      def apply(point)
        point = Point.from(point)
        Point.new(a * point.x + b * point.y + c, d * point.x + e * point.y + f)
      end

      # @param quad [Quad]
      # @return [Quad] the quad with every corner transformed; each corner keeps its role (+top_left+ stays
      #   +top_left+), so the result is still named in the symbol's own orientation
      def apply_quad(quad)
        raise ArgumentError, "expected a Quad, got #{quad.inspect}" unless quad.is_a?(Quad)

        quad.map { |point| apply(point) }
      end

      # @return [Numeric] determinant of the linear part (a·e − b·d): the area scale factor, negative when
      #   the transform mirrors
      def determinant
        a * e - b * d
      end

      # Coefficients stay Integers where the division is exact (e.g. translations and quarter turns).
      #
      # @return [Affine] the inverse transform
      # @raise [ArgumentError] if the transform is singular or its inverse is not finite
      def invert
        det = determinant
        raise ArgumentError, "cannot invert a singular transform (determinant 0): #{inspect}" if det.zero?

        inverse = [e, -b, b * f - c * e, -d, a, c * d - a * f].map { |value| Geometry.quotient(value, det) }
        raise ArgumentError, "cannot invert a nearly singular transform: #{inspect}" unless inverse.all?(&:finite?)

        Affine.new(*inverse)
      end

      # Rotation component in degrees, clockwise as displayed, normalized to 0...360. The scanner adds it to a
      # barcode's reported rotation when mapping results back to the base image.
      #
      # This is the rotation of the polar decomposition, atan2(d − b, a + e): exact for any composition of
      # rotations, translations and uniform scales, otherwise the rotation of the closest similarity. The
      # result is rounded to 1e-9° so that quarter turns come out exact.
      #
      # @return [Float]
      # @raise [ArgumentError] if the transform mirrors or collapses the plane (determinant ≤ 0)
      def rotation_degrees
        unless determinant.positive?
          raise ArgumentError, "rotation is undefined for a mirroring or singular transform: #{inspect}"
        end

        degrees = (Math.atan2(d - b, a + e) * 180 / Math::PI).round(9) % 360
        degrees + 0.0 # -0.0 → 0.0
      end

      # @param other [Affine]
      # @param eps [Numeric] absolute tolerance per coefficient
      # @return [Boolean] whether +other+ is an Affine whose coefficients all differ by at most +eps+
      def approx_equal?(other, eps = 1e-9)
        return false unless other.is_a?(Affine)

        to_a.flatten.zip(other.to_a.flatten).all? { |mine, theirs| (mine - theirs).abs <= eps }
      end

      # @return [Array(Array(Numeric, Numeric, Numeric), Array(Numeric, Numeric, Numeric))] the rows
      #   +[[a, b, c], [d, e, f]]+
      def to_a
        [[a, b, c], [d, e, f]]
      end
    end

    class << self
      # Transform from original image coordinates into the canvas of the image rotated about its center by
      # +degrees+ (clockwise), with the canvas expanded to fit the whole rotated image and starting at (0, 0):
      # the geometry of +Transformers::Base#rotate+. Map results found on the rotated canvas back to the
      # original image with +to_canvas.invert+.
      #
      # Quarter turns are exact: 90° gives an h×w canvas and (x, y) → (h − y, x). Other angles give the
      # rotated bounding box rounded up to whole pixels, with the image centered on the canvas.
      #
      # @param width [Integer] original image width
      # @param height [Integer] original image height
      # @param degrees [Numeric] clockwise rotation
      # @return [Array(Affine, Integer, Integer)] +[to_canvas, canvas_width, canvas_height]+
      # @raise [ArgumentError] on a non-positive or non-Integer size, or a non-finite angle
      def rotation_canvas(width, height, degrees)
        dimension!(width, :width)
        dimension!(height, :height)
        cos, sin = cos_sin(degrees)
        canvas_width, canvas_height = rotation_canvas_size(width, height, cos, sin)
        offset_x, offset_y = rotation_canvas_offset(width, height, canvas_width, canvas_height, cos, sin)
        [Affine.new(cos, -sin, offset_x, sin, cos, offset_y), canvas_width, canvas_height]
      end

      # Overlapping tiles covering a width × height image, for the tiles pass.
      #
      # Each axis is split independently. A side of at most +max_tile+ pixels is a single tile spanning it.
      # A longer side gets the fewest tiles of one size within +min_tile+..+max_tile+ such that adjacent
      # tiles overlap by at least +overlap+ × the tile size (rounded up to whole pixels), using the smallest
      # size that achieves that count. The first tile starts at 0, the last one ends at the far edge, and the
      # ones in between are spaced evenly (rounded to whole pixels). The result is deterministic.
      #
      # @param width [Integer]
      # @param height [Integer]
      # @param min_tile [Integer] smallest tile side (unless the image side itself is smaller)
      # @param max_tile [Integer] largest tile side
      # @param overlap [Numeric] minimum overlap of adjacent tiles as a fraction of the tile side, 0...1
      # @return [Array<Array(Integer, Integer, Integer, Integer)>] +[x, y, width, height]+ per tile, row-major
      #   (top row first, each row left to right)
      # @raise [ArgumentError] on invalid sizes or parameters
      def tile_grid(width, height, min_tile: 1024, max_tile: 1536, overlap: 0.2)
        dimension!(width, :width)
        dimension!(height, :height)
        validate_tiling!(min_tile, max_tile, overlap)
        columns = tile_spans(width, min_tile, max_tile, overlap)
        rows = tile_spans(height, min_tile, max_tile, overlap)
        rows.flat_map { |y, tile_height| columns.map { |x, tile_width| [x, y, tile_width, tile_height] } }
      end

      # @api private
      # @return [Numeric] +value+ when it is a finite real number
      # @raise [ArgumentError] otherwise
      def number!(value, name)
        return value if value.is_a?(Numeric) && value.real? && value.finite?

        raise ArgumentError, "#{name} must be a finite real number, got #{value.inspect}"
      end

      # @api private
      # @return [Array(Numeric, Numeric)] +[cos, sin]+ of +degrees+; exact Integers for multiples of 90°
      def cos_sin(degrees)
        turn = number!(degrees, :degrees) % 360
        return QUARTER_TURNS.fetch((turn / 90).to_i) if (turn % 90).zero?

        turn -= 360 if turn > 180 # symmetric range: rotation(-θ) is the exact mirror of rotation(θ)
        radians = turn * Math::PI / 180
        [Math.cos(radians), Math.sin(radians)]
      end

      # @api private
      # @return [Numeric] numerator / denominator: an Integer when both are Integers and the division is
      #   exact, a Float otherwise
      def quotient(numerator, denominator)
        if numerator.is_a?(Integer) && denominator.is_a?(Integer) && (numerator % denominator).zero?
          numerator / denominator
        else
          numerator.fdiv(denominator)
        end
      end

      private

      # Canvas size for a width × height image rotated by (cos, sin): the rotated bounding box, rounded up
      # to whole pixels (quarter turns are exact).
      def rotation_canvas_size(width, height, cos, sin)
        [width * cos.abs + height * sin.abs, width * sin.abs + height * cos.abs].map do |extent|
          extent.is_a?(Integer) ? extent : [(extent - CANVAS_TOLERANCE).ceil, 1].max
        end
      end

      # Translation (c, f) that places the rotated image on its canvas. The single place that decides where
      # the image lands: the image center (w/2, h/2) maps to the canvas center, so the slack from rounding the
      # canvas size up is split evenly between opposite edges. Adjust here if a transformer (libvips +rotate+,
      # ImageMagick +-rotate+) positions the image differently.
      def rotation_canvas_offset(width, height, canvas_width, canvas_height, cos, sin)
        [
          quotient(canvas_width - cos * width + sin * height, 2),
          quotient(canvas_height - sin * width - cos * height, 2)
        ]
      end

      # [[offset, size], ...] of the tiles along one axis of +length+ pixels.
      def tile_spans(length, min_tile, max_tile, overlap)
        return [[0, length]] if length <= max_tile

        count = 1 + ceil_div(length - max_tile, max_tile - min_overlap(max_tile, overlap))
        # tiles_fit? is monotonic in the size and holds for max_tile, so this finds the smallest fitting size.
        size = (min_tile..max_tile).bsearch { |candidate| tiles_fit?(length, count, candidate, overlap) }
        travel = length - size
        # i × travel / (count − 1), rounded half up in Integer arithmetic
        Array.new(count) { |i| [(2 * i * travel + count - 1) / (2 * (count - 1)), size] }
      end

      # Whether +count+ evenly spaced tiles of +size+ (count ≥ 2) span +length+ with the minimum overlap.
      # Rounded offsets advance by at most ceil(travel / (count - 1)) pixels.
      def tiles_fit?(length, count, size, overlap)
        size - ceil_div(length - size, count - 1) >= min_overlap(size, overlap)
      end

      # Minimum overlap in whole pixels between adjacent tiles of +size+.
      def min_overlap(size, overlap)
        (overlap * size - OVERLAP_TOLERANCE).ceil
      end

      def ceil_div(numerator, denominator)
        (numerator + denominator - 1) / denominator
      end

      def dimension!(value, name)
        return if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "#{name} must be a positive Integer, got #{value.inspect}"
      end

      def validate_tiling!(min_tile, max_tile, overlap)
        dimension!(min_tile, :min_tile)
        dimension!(max_tile, :max_tile)
        raise ArgumentError, "min_tile (#{min_tile}) must not exceed max_tile (#{max_tile})" if min_tile > max_tile
        unless overlap.is_a?(Numeric) && overlap.real? && overlap.finite? && overlap >= 0 && overlap < 1
          raise ArgumentError, "overlap must be a number in 0...1, got #{overlap.inspect}"
        end
        return if min_overlap(max_tile, overlap) < max_tile

        raise ArgumentError, "overlap #{overlap} leaves no room to advance between tiles of #{max_tile} px"
      end
    end
  end

  # Shorthand for {Geometry::Point}.
  Point = Geometry::Point
  # Shorthand for {Geometry::Quad}.
  Quad = Geometry::Quad
end
