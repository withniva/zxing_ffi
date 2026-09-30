# frozen_string_literal: true

require "test_helper"
require "json"

module ZXingFFI
  module GeometryTestSupport
    Point = Geometry::Point
    Quad = Geometry::Quad
    Affine = Geometry::Affine

    def assert_point_in_delta(expected, actual, delta = 1e-9)
      expected = Point.from(expected)
      assert_in_delta expected.x, actual.x, delta, "x of #{actual.inspect}"
      assert_in_delta expected.y, actual.y, delta, "y of #{actual.inspect}"
    end

    def assert_affine_in_delta(expected, actual, eps = 1e-9)
      assert expected.approx_equal?(actual, eps), "expected #{actual.inspect}\nto be within #{eps} of #{expected.inspect}"
    end

    # Signed difference of two angles in degrees, in -180...180.
    def angle_difference(a, b)
      ((a - b + 180) % 360) - 180
    end
  end

  class GeometryPointTest < Minitest::Test
    include GeometryTestSupport

    def test_builds_from_positional_or_keyword_arguments
      point = Point.new(3, 4)

      assert_equal Point.new(x: 3, y: 4), point
      assert_equal 3, point.x
      assert_equal 4, point.y
    end

    def test_keeps_the_numeric_type_of_coordinates
      assert_kind_of Integer, Point.new(1, 2).x
      assert_kind_of Float, Point.new(1.5, 2).x
      assert_equal Rational(1, 3), Point.new(Rational(1, 3), 0).x
    end

    def test_rejects_coordinates_that_are_not_finite_real_numbers
      [nil, "1", :one, Float::NAN, Float::INFINITY, -Float::INFINITY, Complex(1, 1), Complex(1, 0)].each do |bad|
        assert_raises(ArgumentError, "x = #{bad.inspect}") { Point.new(bad, 0) }
        assert_raises(ArgumentError, "y = #{bad.inspect}") { Point.new(0, bad) }
      end
    end

    def test_requires_exactly_two_coordinates
      assert_raises(ArgumentError) { Point.new(1) }
      assert_raises(ArgumentError) { Point.new(1, 2, 3) }
    end

    def test_with_validates_the_new_coordinates
      assert_equal Point.new(1, 5), Point.new(1, 2).with(y: 5)
      assert_raises(ArgumentError) { Point.new(1, 2).with(x: Float::NAN) }
    end

    def test_from_accepts_points_and_pairs
      point = Point.new(1, 2)

      assert_same point, Point.from(point)
      assert_equal point, Point.from([1, 2])
    end

    def test_from_rejects_anything_else
      [nil, [], [1], [1, 2, 3], "1,2", {x: 1, y: 2}, 5, ["1", 2]].each do |bad|
        assert_raises(ArgumentError, bad.inspect) { Point.from(bad) }
      end
    end

    def test_addition_and_subtraction
      assert_equal Point.new(4, 6), Point.new(1, 2) + Point.new(3, 4)
      assert_equal Point.new(4, 6), Point.new(1, 2) + [3, 4]
      assert_equal Point.new(-2, -2), Point.new(1, 2) - [3, 4]
      assert_equal Point.new(0.5, 2), Point.new(1, 2) - Point.new(0.5, 0)
      assert_kind_of Integer, (Point.new(1, 2) + [3, 4]).x
      assert_raises(ArgumentError) { Point.new(1, 2) + 1 }
      assert_raises(ArgumentError) { Point.new(1, 2) - nil }
    end

    def test_distance_to
      assert_in_delta 5.0, Point.new(0, 0).distance_to(Point.new(3, 4)), 1e-12
      assert_in_delta 5.0, Point.new(3, 4).distance_to([0, 0]), 1e-12
      assert_in_delta 0.0, Point.new(7, 7).distance_to([7, 7]), 0
      assert_kind_of Float, Point.new(0, 0).distance_to([3, 4])
      assert_raises(ArgumentError) { Point.new(0, 0).distance_to(3) }
    end

    def test_round_returns_integer_coordinates
      rounded = Point.new(1.4, -1.5).round

      assert_equal Point.new(1, -2), rounded
      assert_kind_of Integer, rounded.x
      assert_kind_of Integer, rounded.y
      assert_equal Point.new(3, 0), Point.new(2.5, 0.49).round
      assert_equal Point.new(7, 8), Point.new(7, 8).round
    end

    def test_to_a_and_to_h
      assert_equal [1, 2.5], Point.new(1, 2.5).to_a
      assert_equal({x: 1, y: 2.5}, Point.new(1, 2.5).to_h)
    end

    def test_value_semantics
      point = Point.new(1, 2)

      assert_predicate point, :frozen?
      assert_equal point, Point.new(1, 2)
      assert point.eql?(Point.new(1, 2))
      assert_equal point.hash, Point.new(1, 2).hash
      assert_equal :found, {point => :found}[Point.new(1, 2)]
      assert_equal point, Point.new(1.0, 2.0) # == compares coordinates numerically
      refute point.eql?(Point.new(1.0, 2.0)) # eql? also compares their classes
    end

    def test_top_level_aliases
      assert_same Geometry::Point, ZXingFFI::Point
      assert_same Geometry::Quad, ZXingFFI::Quad
    end
  end

  class GeometryQuadTest < Minitest::Test
    include GeometryTestSupport

    def rectangle(x, y, width, height)
      Quad.from_points([[x, y], [x + width, y], [x + width, y + height], [x, y + height]])
    end

    def test_from_points_accepts_points_pairs_and_quads
      from_points = Quad.from_points([Point.new(0, 0), Point.new(10, 0), Point.new(10, 5), Point.new(0, 5)])

      assert_equal from_points, Quad.from_points([[0, 0], [10, 0], [10, 5], [0, 5]])
      assert_equal from_points, Quad.from_points([[0, 0], Point.new(10, 0), [10, 5], Point.new(0, 5)])
      assert_equal from_points, Quad.from_points(from_points)
      assert_equal Point.new(10, 5), from_points.bottom_right
    end

    def test_from_points_requires_exactly_four_valid_points
      [nil, [], [[0, 0]] * 3, [[0, 0]] * 5, Point.new(1, 2)].each do |bad|
        assert_raises(ArgumentError, bad.inspect) { Quad.from_points(bad) }
      end
      assert_raises(ArgumentError) { Quad.from_points([[0, 0], [1, 0], [1, 1], "0,1"]) }
      assert_raises(ArgumentError) { Quad.from_points([[0, 0], [1, 0], [1, 1], [0, Float::NAN]]) }
    end

    def test_new_coerces_corners
      quad = Quad.new([0, 0], [4, 0], [4, 3], [0, 3])

      assert_equal Point.new(4, 3), quad.bottom_right
      assert_equal quad, Quad.new(top_left: [0, 0], top_right: [4, 0], bottom_right: [4, 3], bottom_left: [0, 3])
      assert_raises(ArgumentError) { Quad.new([0, 0], [4, 0], [4, 3], nil) }
      assert_raises(ArgumentError) { Quad.new([0, 0], [4, 0], [4, 3]) }
    end

    def test_points_are_in_corner_order
      quad = Quad.from_points([[1, 2], [3, 4], [5, 6], [7, 8]])
      expected = [Point.new(1, 2), Point.new(3, 4), Point.new(5, 6), Point.new(7, 8)]

      assert_equal expected, quad.points
      assert_equal expected, quad.to_a
      assert_equal [quad.top_left, quad.top_right, quad.bottom_right, quad.bottom_left], expected
    end

    def test_center_is_the_mean_of_the_corners
      center = Quad.from_points([[0, 0], [8, 0], [9, 4], [1, 7]]).center

      assert_equal Point.new(5.0, 2.5), rectangle(0, 0, 10, 5).center
      assert_equal Point.new(4.5, 2.75), center
      assert_kind_of Float, center.x
    end

    def test_side_lengths
      quad = rectangle(10, 20, 30, 10)
      trapezoid = Quad.from_points([[0, 0], [6, 0], [6, 8], [0, 4]])

      assert_equal [30.0, 10.0, 30.0, 10.0], quad.side_lengths # top, right, bottom, left
      assert_in_delta 10.0, quad.shorter_side, 0
      assert_in_delta 30.0, quad.longer_side, 0
      assert_equal [6.0, 8.0, Math.sqrt(52), 4.0], trapezoid.side_lengths
      assert_in_delta 4.0, trapezoid.shorter_side, 0
      assert_in_delta 8.0, trapezoid.longer_side, 0
    end

    def test_area
      diamond = Quad.from_points([[5, 0], [10, 5], [5, 10], [0, 5]]) # square with side sqrt(50)

      assert_in_delta 300.0, rectangle(5, 5, 30, 10).area, 0
      assert_in_delta 300.0, Quad.from_points([[5, 5], [5, 15], [35, 15], [35, 5]]).area, 0 # other winding
      assert_in_delta 50.0, diamond.area, 1e-12
      assert_in_delta 36.0, Quad.from_points([[0, 0], [6, 0], [6, 8], [0, 4]]).area, 0
      assert_in_delta 0.0, Quad.from_points([[0, 0], [10, 0], [20, 0], [5, 0]]).area, 0 # collinear
      assert_kind_of Float, rectangle(0, 0, 1, 1).area
    end

    def test_bounding_box
      diamond = Quad.from_points([[5, -2], [12, 5], [5, 12], [-2, 5]])

      assert_equal [-2, -2, 12, 12], diamond.bounding_box
      assert_equal [10, 20, 40, 30], rectangle(10, 20, 30, 10).bounding_box
    end

    def test_corner_names_follow_the_symbol_not_the_image
      # A symbol turned 90° clockwise: its top-left corner lies at the image's top-right.
      quad = Quad.from_points([[10, 0], [10, 10], [0, 10], [0, 0]])

      assert_equal [0, 0, 10, 10], quad.bounding_box
      assert_equal Point.new(5.0, 5.0), quad.center
      assert_in_delta 100.0, quad.area, 0
      assert_equal [10.0] * 4, quad.side_lengths
    end

    def test_transform_applies_the_affine
      quad = rectangle(0, 0, 10, 5)
      affine = Affine.translation(3, 4).then(Affine.scale(2))

      assert_equal affine.apply_quad(quad), quad.transform(affine)
      assert_equal rectangle(6, 8, 20, 10), quad.transform(affine)
      assert_raises(ArgumentError) { quad.transform(nil) }
    end

    def test_round
      quad = Quad.from_points([[0.4, 0.5], [9.6, -0.5], [10.49, 5.5], [-0.51, 4.2]])

      assert_equal Quad.from_points([[0, 1], [10, -1], [10, 6], [-1, 4]]), quad.round
      assert(quad.round.points.flat_map(&:to_a).all?(Integer))
    end

    def test_map_builds_a_quad_keeping_corner_roles
      quad = rectangle(0, 0, 10, 5)
      shifted = quad.map { |point| point + [1, 1] }

      assert_instance_of Quad, shifted
      assert_equal Point.new(1, 1), shifted.top_left
      assert_equal Point.new(11, 6), shifted.bottom_right
      assert_equal rectangle(0, 0, 20, 10), quad.map { |point| [point.x * 2, point.y * 2] }
      assert_raises(ArgumentError) { quad.map { nil } }
    end

    def test_map_without_a_block_returns_an_enumerator
      quad = rectangle(0, 0, 10, 5)
      enum = quad.map

      assert_kind_of Enumerator, enum
      assert_equal Quad.from_points([[0, 0], [11, 0], [12, 5], [3, 5]]), enum.with_index { |point, i| point + [i, 0] }
    end

    def test_to_h_returns_plain_nested_hashes
      quad = Quad.from_points([[0, 0], [10, 0], [10, 5.5], [0, 5.5]])
      expected = {
        top_left: {x: 0, y: 0}, top_right: {x: 10, y: 0},
        bottom_right: {x: 10, y: 5.5}, bottom_left: {x: 0, y: 5.5}
      }

      assert_equal expected, quad.to_h
      assert_equal expected, JSON.parse(JSON.generate(quad.to_h), symbolize_names: true)
      assert_equal(%w[top_left top_right bottom_right bottom_left], quad.to_h { |corner, xy| [corner.to_s, xy] }.keys)
    end

    def test_value_semantics
      assert_equal rectangle(0, 0, 3, 4), rectangle(0, 0, 3, 4)
      assert_equal rectangle(0, 0, 3, 4).hash, rectangle(0, 0, 3, 4).hash
      refute_equal rectangle(0, 0, 3, 4), rectangle(0, 0, 4, 3)
      assert_predicate rectangle(0, 0, 3, 4), :frozen?
    end
  end

  class GeometryAffineTest < Minitest::Test
    include GeometryTestSupport

    def test_identity
      assert_equal Affine.new(1, 0, 0, 0, 1, 0), Affine.identity
      assert_equal Point.new(3, -4), Affine.identity.apply([3, -4])
    end

    def test_translation
      assert_equal Point.new(13, 18), Affine.translation(10, 20).apply([3, -2])
      assert_equal [[1, 0, 10], [0, 1, 20]], Affine.translation(10, 20).to_a
    end

    def test_scale
      assert_equal Point.new(6, -8), Affine.scale(2).apply([3, -4])
      assert_equal Point.new(1.5, -12), Affine.scale(0.5, 3).apply([3, -4])
    end

    def test_rotation_is_clockwise_as_displayed
      quarter = Affine.rotation(90)

      assert_equal Point.new(0, 1), quarter.apply([1, 0]) # right turns to down
      assert_equal Point.new(-1, 0), quarter.apply([0, 1]) # down turns to left
      assert_point_in_delta [Math.sqrt(0.5), Math.sqrt(0.5)], Affine.rotation(45).apply([1, 0])
      assert_point_in_delta [Math.sqrt(3) / 2, 0.5], Affine.rotation(30).apply([1, 0])
    end

    def test_rotation_by_quarter_turns_is_exact
      quarter = [[0, -1, 0], [1, 0, 0]]
      half = [[-1, 0, 0], [0, -1, 0]]
      three_quarters = [[0, 1, 0], [-1, 0, 0]]
      identity = [[1, 0, 0], [0, 1, 0]]
      {
        0 => identity, 90 => quarter, 180 => half, 270 => three_quarters, 360 => identity, -90 => three_quarters,
        -180 => half, 450 => quarter, -720 => identity, 90.0 => quarter, Rational(540) => half
      }.each do |degrees, rows|
        affine = Affine.rotation(degrees)

        assert_equal rows, affine.to_a, "#{degrees}°"
        assert(affine.to_a.flatten.all?(Integer), "#{degrees}° has Integer coefficients")
      end
    end

    def test_rotation_about_a_center
      affine = Affine.rotation(90, 5, 5)

      assert_equal Point.new(5, 5), affine.apply([5, 5])
      assert_equal Point.new(5, 10), affine.apply([10, 5])
      assert_equal Point.new(10, 0), affine.apply([0, 0])
      assert_point_in_delta [7, 3], Affine.rotation(30, 7, 3).apply([7, 3])
    end

    def test_negative_angles
      assert_affine_in_delta Affine.rotation(330), Affine.rotation(-30)
      assert_equal Affine.rotation(270), Affine.rotation(-90)
      assert_point_in_delta [Math.sqrt(3) / 2, -0.5], Affine.rotation(-30).apply([1, 0])
    end

    def test_constructors_validate_their_arguments
      assert_raises(ArgumentError) { Affine.new(1, 0, 0, 0, 1) }
      assert_raises(ArgumentError) { Affine.new(1, 0, Float::NAN, 0, 1, 0) }
      assert_raises(ArgumentError) { Affine.new(1, 0, "0", 0, 1, 0) }
      assert_raises(ArgumentError) { Affine.identity.with(e: nil) }
      assert_raises(ArgumentError) { Affine.translation(nil, 0) }
      assert_raises(ArgumentError) { Affine.scale(Float::INFINITY) }
      assert_raises(ArgumentError) { Affine.rotation(Float::NAN) }
      assert_raises(ArgumentError) { Affine.rotation("90") }
      assert_raises(ArgumentError) { Affine.rotation(90, nil, 0) }
      assert_raises(ArgumentError) { Affine.rotation(30, 0, Float::NAN) }
    end

    def test_compose_applies_the_argument_first
      scale = Affine.scale(2)
      shift = Affine.translation(10, 0)

      assert_equal Point.new(22, 2), scale.compose(shift).apply([1, 1]) # shift, then scale
      assert_equal Point.new(12, 2), shift.compose(scale).apply([1, 1]) # scale, then shift
      refute_equal scale.compose(shift), shift.compose(scale)
    end

    def test_compose_with_a_rotation_does_not_commute
      turn = Affine.rotation(90)
      shift = Affine.translation(5, 0)

      assert_equal Point.new(0, 5), turn.compose(shift).apply([0, 0])
      assert_equal Point.new(5, 0), shift.compose(turn).apply([0, 0])
    end

    def test_then_applies_self_first
      scale = Affine.scale(2)
      shift = Affine.translation(10, 0)

      assert_equal Point.new(12, 2), scale.then(shift).apply([1, 1]) # scale, then shift
      assert_equal Point.new(22, 2), shift.then(scale).apply([1, 1]) # shift, then scale
      assert_equal shift.compose(scale), scale.then(shift)
    end

    def test_then_with_a_block_is_kernel_then
      assert_equal [[1, 0, 0], [0, 1, 0]], Affine.identity.then(&:to_a)
    end

    def test_compose_and_then_reject_other_objects
      [nil, 2, [1, 0, 0, 0, 1, 0], Point.new(1, 2)].each do |bad|
        assert_raises(ArgumentError, bad.inspect) { Affine.identity.compose(bad) }
        assert_raises(ArgumentError, bad.inspect) { Affine.identity.then(bad) }
      end
      assert_raises(ArgumentError) { Affine.identity.then }
    end

    def test_apply_accepts_points_or_pairs
      affine = Affine.new(1, 2, 3, 4, 5, 6)

      assert_equal Point.new(1 + 4 + 3, 4 + 10 + 6), affine.apply([1, 2])
      assert_equal affine.apply([1, 2]), affine.apply(Point.new(1, 2))
      assert_raises(ArgumentError) { affine.apply(nil) }
      assert_raises(ArgumentError) { affine.apply([1, 2, 3]) }
    end

    def test_apply_quad_keeps_corner_roles
      quad = Quad.from_points([[0, 0], [10, 0], [10, 5], [0, 5]])
      turned = Affine.rotation(90).apply_quad(quad)

      assert_equal Quad.from_points([[0, 0], [0, 10], [-5, 10], [-5, 0]]), turned
      assert_equal Point.new(-5, 10), turned.bottom_right
      assert_raises(ArgumentError) { Affine.identity.apply_quad([[0, 0]] * 4) }
    end

    def test_determinant
      assert_equal 1, Affine.rotation(90).determinant
      assert_in_delta 1.0, Affine.rotation(33).determinant, 1e-12
      assert_equal 6, Affine.scale(2, 3).determinant
      assert_equal(-1, Affine.scale(-1, 1).determinant)
    end

    def test_invert_known_transforms
      assert_equal Affine.translation(-3, -4), Affine.translation(3, 4).invert
      assert_equal Affine.scale(0.5, 0.25), Affine.scale(2, 4).invert
      assert_equal Affine.rotation(-90), Affine.rotation(90).invert
      assert_equal Affine.new(1, -1, -2, -1, 2, 1), Affine.new(2, 1, 3, 1, 1, 1).invert
      assert_affine_in_delta Affine.rotation(-30), Affine.rotation(30).invert
      assert_affine_in_delta Affine.rotation(-30, 7, 9), Affine.rotation(30, 7, 9).invert
    end

    def test_invert_keeps_integers_when_the_division_is_exact
      assert(Affine.new(2, 1, 3, 1, 1, 1).invert.to_a.flatten.all?(Integer))
      assert(Affine.rotation(270, 4, 6).invert.to_a.flatten.all?(Integer))
      assert_kind_of Float, Affine.scale(2).invert.a
      assert_kind_of Float, Affine.new(2, 0, 1, 0, 2, 0).invert.c # 1 / 2 is not an Integer
    end

    def test_invert_rejects_singular_transforms
      [
        Affine.scale(0), Affine.scale(1, 0), Affine.new(1, 2, 3, 2, 4, 5), Affine.new(1e-200, 0, 0, 0, 1e-200, 0)
      ].each do |singular|
        error = assert_raises(ArgumentError) { singular.invert }
        assert_match(/singular/, error.message)
      end
    end

    def test_invert_rejects_transforms_whose_inverse_overflows
      error = assert_raises(ArgumentError) { Affine.new(1e-310, 0, 0, 0, 1, 0).invert }
      assert_match(/nearly singular/, error.message)
    end

    def test_rotation_degrees
      assert_equal 0.0, Affine.identity.rotation_degrees
      assert_equal 90.0, Affine.rotation(90).rotation_degrees
      assert_equal 270.0, Affine.rotation(-90).rotation_degrees
      assert_equal 0.0, Affine.rotation(360).rotation_degrees
      assert_in_delta 30.0, Affine.rotation(30).rotation_degrees, 1e-9
      assert_in_delta 315.0, Affine.rotation(45).invert.rotation_degrees, 1e-9
      assert_in_delta 75.0, Affine.rotation(30).compose(Affine.rotation(45)).rotation_degrees, 1e-9
      assert_kind_of Float, Affine.rotation(90).rotation_degrees
    end

    def test_rotation_degrees_ignores_translations_and_scales
      similarity = Affine.translation(100, -7).compose(Affine.scale(3)).compose(Affine.rotation(200, 4, 5))

      assert_in_delta 200.0, similarity.rotation_degrees, 1e-9
      assert_in_delta 40.0, Affine.scale(2, 0.5).compose(Affine.rotation(40)).rotation_degrees, 1e-9
      assert_in_delta 40.0, Affine.rotation(40).compose(Affine.scale(2, 0.5)).rotation_degrees, 1e-9
    end

    def test_rotation_degrees_is_normalized_to_0_up_to_360
      tiny = Affine.rotation(-1e-12).rotation_degrees

      assert_equal 0.0, tiny
      assert_predicate 1 / tiny, :positive? # 0.0, not -0.0
      assert_in_delta 359.5, Affine.rotation(-0.5).rotation_degrees, 1e-9
      assert_in_delta 0.5, Affine.rotation(720.5).rotation_degrees, 1e-9
    end

    def test_rotation_degrees_rejects_mirroring_and_singular_transforms
      assert_raises(ArgumentError) { Affine.scale(-1, 1).rotation_degrees }
      assert_raises(ArgumentError) { Affine.rotation(30).compose(Affine.scale(1, -1)).rotation_degrees }
      assert_raises(ArgumentError) { Affine.scale(0).rotation_degrees }
    end

    def test_approx_equal
      assert Affine.identity.approx_equal?(Affine.new(1 + 1e-12, 0, 5e-10, 0, 1, -1e-10))
      refute Affine.identity.approx_equal?(Affine.new(1, 0, 1e-6, 0, 1, 0))
      assert Affine.identity.approx_equal?(Affine.new(1, 0, 1e-6, 0, 1, 0), 1e-5)
      refute Affine.identity.approx_equal?(nil)
      refute Affine.identity.approx_equal?([[1, 0, 0], [0, 1, 0]])
    end

    def test_value_semantics
      assert_equal Affine.identity, Affine.new(1, 0, 0, 0, 1, 0)
      assert Affine.identity.eql?(Affine.new(1, 0, 0, 0, 1, 0))
      assert_equal Affine.identity.hash, Affine.new(1, 0, 0, 0, 1, 0).hash
      assert_equal :hit, {Affine.scale(2) => :hit}[Affine.scale(2)]
      assert_equal Affine.identity, Affine.new(1.0, 0.0, 0.0, 0.0, 1.0, 0.0) # == compares numerically
      refute Affine.identity.eql?(Affine.new(1.0, 0.0, 0.0, 0.0, 1.0, 0.0)) # eql? also compares classes
      assert_predicate Affine.identity, :frozen?
    end

    def test_to_a_returns_rows
      affine = Affine.new(1, 2, 3, 4, 5, 6)

      assert_equal [[1, 2, 3], [4, 5, 6]], affine.to_a
      assert_equal affine, Affine.new(*affine.to_a.flatten)
    end
  end

  # Round-trip and algebraic properties on seeded random transforms.
  class GeometryAffinePropertyTest < Minitest::Test
    include GeometryTestSupport

    ITERATIONS = 300

    def setup
      @random = Random.new(20_260_925)
    end

    # A random invertible transform: shear, non-uniform scale (sometimes mirrored), rotation about a random
    # center, translation. Its determinant is at least 0.04 in magnitude.
    def random_affine
      shear = Affine.new(1, @random.rand(-1.0..1.0), 0, 0, 1, 0)
      sign = (@random.rand < 0.2) ? -1 : 1
      scale = Affine.scale(sign * @random.rand(0.2..5.0), @random.rand(0.2..5.0))
      turn = Affine.rotation(@random.rand(-360.0..360.0), @random.rand(-500.0..500.0), @random.rand(-500.0..500.0))
      shift = Affine.translation(@random.rand(-2000.0..2000.0), @random.rand(-2000.0..2000.0))
      shift.compose(turn).compose(scale).compose(shear)
    end

    def random_similarity(degrees)
      Affine.translation(@random.rand(-2000.0..2000.0), @random.rand(-2000.0..2000.0))
        .compose(Affine.scale(@random.rand(0.1..10.0)))
        .compose(Affine.rotation(degrees, @random.rand(-500.0..500.0), @random.rand(-500.0..500.0)))
    end

    def random_point
      Point.new(@random.rand(-5000.0..5000.0), @random.rand(-5000.0..5000.0))
    end

    def test_inverse_round_trips
      ITERATIONS.times do
        affine = random_affine
        inverse = affine.invert
        point = random_point

        assert_affine_in_delta Affine.identity, inverse.compose(affine)
        assert_affine_in_delta Affine.identity, affine.compose(inverse)
        assert_point_in_delta point, inverse.apply(affine.apply(point)), 1e-6
        assert_affine_in_delta affine, inverse.invert, 1e-6
      end
    end

    def test_compose_matches_applying_one_after_the_other
      ITERATIONS.times do
        first = random_affine
        second = random_affine
        point = random_point

        assert_point_in_delta second.apply(first.apply(point)), second.compose(first).apply(point), 1e-6
        assert_point_in_delta second.apply(first.apply(point)), first.then(second).apply(point), 1e-6
        assert_equal second.compose(first), first.then(second)
      end
    end

    def test_compose_is_associative
      ITERATIONS.times do
        a = random_affine
        b = random_affine
        c = random_affine

        assert_affine_in_delta a.compose(b).compose(c), a.compose(b.compose(c)), 1e-6
      end
    end

    def test_identity_is_neutral
      ITERATIONS.times do
        affine = random_affine

        assert_equal affine, Affine.identity.compose(affine)
        assert_equal affine, affine.compose(Affine.identity)
      end
    end

    def test_inverse_of_a_composition_reverses_the_order
      ITERATIONS.times do
        a = random_affine
        b = random_affine

        assert_affine_in_delta b.invert.compose(a.invert), a.compose(b).invert, 1e-6
      end
    end

    def test_apply_quad_matches_apply_on_every_corner
      ITERATIONS.times do
        affine = random_affine
        quad = Quad.from_points(Array.new(4) { random_point })

        assert_equal quad.points.map { |point| affine.apply(point) }, affine.apply_quad(quad).points
      end
    end

    def test_rotation_inverse_is_the_opposite_rotation
      ITERATIONS.times do
        degrees = @random.rand(-720.0..720.0)
        cx = @random.rand(-500.0..500.0)
        cy = @random.rand(-500.0..500.0)

        assert_affine_in_delta Affine.rotation(-degrees, cx, cy), Affine.rotation(degrees, cx, cy).invert
      end
    end

    def test_rotation_degrees_of_similarities_adds_up
      ITERATIONS.times do
        alpha = @random.rand(-360.0..360.0)
        beta = @random.rand(-360.0..360.0)
        combined = random_similarity(alpha).compose(random_similarity(beta))

        assert_in_delta 0, angle_difference(combined.rotation_degrees, alpha + beta), 1e-6
        assert_in_delta 0, angle_difference(combined.invert.rotation_degrees, -(alpha + beta)), 1e-6
        assert_operator combined.rotation_degrees, :>=, 0
        assert_operator combined.rotation_degrees, :<, 360
      end
    end
  end

  # Every pass carries a transform back to base-image pixels.
  class GeometryPipelineTest < Minitest::Test
    include GeometryTestSupport

    # A tile at (tx, ty) of the image upscaled 2×: tile pixel p is p + (tx, ty) upscaled, (p + (tx, ty)) / 2 in
    # the base image.
    def test_tile_of_an_upscaled_image_maps_back_to_base_pixels
      base_quad = Quad.from_points([[611, 402], [671, 405], [668, 465], [608, 462]])
      upscaled_quad = base_quad.transform(Affine.scale(2))
      tiles = Geometry.tile_grid(1600, 1200, min_tile: 512, max_tile: 768)
      tx, ty, = tiles.find do |x, y, w, h|
        upscaled_quad.points.all? { |point| point.x.between?(x, x + w) && point.y.between?(y, y + h) }
      end
      refute_nil tx, "a tile holds the whole code"
      reported = upscaled_quad.map { |point| point - [tx, ty] } # what the decoder sees in the crop
      to_base = Affine.scale(0.5).compose(Affine.translation(tx, ty))

      assert_operator [tx, ty].max, :>, 0, "the test should use a tile with an offset"
      assert_equal to_base, Affine.translation(tx, ty).then(Affine.scale(0.5))
      assert_equal base_quad, reported.transform(to_base)
      assert_equal 0.0, to_base.rotation_degrees
    end

    # The decoder reports integer corners on the rotated canvas and a rotation relative to the canvas; both
    # must be mapped back to the base image.
    def test_rotated_pass_maps_back_to_base_pixels_and_rotation
      base_quad = Quad.from_points([[100, 200], [160, 200], [160, 260], [100, 260]]) # upright code
      to_canvas, canvas_width, canvas_height = Geometry.rotation_canvas(800, 600, 45)
      reported = base_quad.transform(to_canvas).round
      reported_rotation = 45 # the upright code appears turned 45° clockwise on the canvas
      to_base = to_canvas.invert
      mapped = reported.transform(to_base)

      assert(reported.points.all? { |point| point.x.between?(0, canvas_width) && point.y.between?(0, canvas_height) })
      base_quad.points.zip(mapped.points).each do |expected, actual|
        assert_operator expected.distance_to(actual), :<=, Math.sqrt(0.5) + 1e-9 # rounding error only
      end
      assert_equal 0, (reported_rotation + to_base.rotation_degrees).round % 360
    end

    def test_chained_passes_compose
      point = Point.new(40, 150)
      upscale = Affine.scale(2)
      to_canvas, = Geometry.rotation_canvas(600, 400, 90) # the 2× image of a 300×200 page, turned 90°
      on_canvas = upscale.then(to_canvas).apply(point)
      to_base = to_canvas.invert.then(upscale.invert)

      assert_equal Point.new(400 - 300, 80), on_canvas # (h − y, x) on the 600×400 image
      assert_equal point, to_base.apply(on_canvas)
      assert_equal 270.0, to_base.rotation_degrees
    end
  end

  class GeometryRotationCanvasTest < Minitest::Test
    include GeometryTestSupport

    ANGLES = [0, 90, 180, 270, 360, -90, 30, 45, 135, -30, 200.5].freeze
    QUARTER_TURNS = [0, 90, 180, 270, 360, -90, -180, 450].freeze
    SIZES = [[640, 480], [480, 640], [1, 1], [1, 1000], [2550, 3300], [3, 7], [100, 100]].freeze

    def corners(width, height)
      [[0, 0], [width, 0], [width, height], [0, height]]
    end

    def each_case(angles = ANGLES)
      SIZES.product(angles).each do |(width, height), degrees|
        yield width, height, degrees, "#{width}×#{height} at #{degrees}°"
      end
    end

    def test_quarter_turns_are_exact
      w = 640
      h = 480
      {
        0 => [w, h, ->(x, y) { [x, y] }], 360 => [w, h, ->(x, y) { [x, y] }],
        90 => [h, w, ->(x, y) { [h - y, x] }], 450 => [h, w, ->(x, y) { [h - y, x] }],
        180 => [w, h, ->(x, y) { [w - x, h - y] }], -180 => [w, h, ->(x, y) { [w - x, h - y] }],
        270 => [h, w, ->(x, y) { [y, w - x] }], -90 => [h, w, ->(x, y) { [y, w - x] }]
      }.each do |degrees, (canvas_width, canvas_height, expected)|
        to_canvas, *size = Geometry.rotation_canvas(w, h, degrees)

        assert_equal [canvas_width, canvas_height], size, "#{degrees}°"
        assert(to_canvas.to_a.flatten.all?(Integer), "#{degrees}° has Integer coefficients")
        [[0, 0], [w, h], [17, 433], [639, 1], [320, 240]].each do |x, y|
          mapped = to_canvas.apply([x, y]).to_a

          assert_equal expected.call(x, y), mapped, "#{degrees}° maps (#{x}, #{y})"
          assert(mapped.all?(Integer))
        end
      end
    end

    def test_quarter_turns_of_odd_sizes_are_exact
      [[1, 1], [3, 7], [1, 1000]].each do |w, h|
        assert_equal [Affine.new(0, -1, h, 1, 0, 0), h, w], Geometry.rotation_canvas(w, h, 90)
        assert_equal [Affine.new(-1, 0, w, 0, -1, h), w, h], Geometry.rotation_canvas(w, h, 180)
        assert_equal [Affine.new(0, 1, 0, -1, 0, w), h, w], Geometry.rotation_canvas(w, h, 270)
      end
    end

    def test_other_angles_round_the_rotated_bounding_box_up
      {
        [100, 100, 45] => [142, 142], # 141.42 × 141.42
        [640, 480, 30] => [795, 736], # 794.26 × 735.69
        [640, 480, -30] => [795, 736],
        [640, 480, 45] => [792, 792], # 791.96 × 791.96
        [640, 480, 135] => [792, 792],
        [1, 1, 45] => [2, 2], # 1.41 × 1.41
        [3, 7, 30] => [7, 8], # 6.10 × 7.56
        [1, 1000, 30] => [501, 867] # 500.87 × 866.53
      }.each do |(w, h, degrees), size|
        assert_equal size, Geometry.rotation_canvas(w, h, degrees).drop(1), "#{w}×#{h} at #{degrees}°"
      end
    end

    def test_canvas_size_ignores_floating_point_noise
      # cos = 3/5 and sin = 4/5: a 1×3 image spans exactly 3 × 2.6 px, floating point says 3.0000000000000004.
      degrees = Math.atan2(4, 3) * 180 / Math::PI

      assert_equal [3, 3], Geometry.rotation_canvas(1, 3, degrees).drop(1)
    end

    def test_rotated_image_fits_the_canvas_and_touches_every_edge
      each_case do |w, h, degrees, label|
        to_canvas, canvas_width, canvas_height = Geometry.rotation_canvas(w, h, degrees)
        mapped = corners(w, h).map { |corner| to_canvas.apply(corner) }
        xs = mapped.map(&:x)
        ys = mapped.map(&:y)

        assert_operator xs.min, :>=, -1e-9, label
        assert_operator ys.min, :>=, -1e-9, label
        assert_operator xs.max, :<=, canvas_width + 1e-9, label
        assert_operator ys.max, :<=, canvas_height + 1e-9, label
        # Rounding the size up leaves less than a pixel of slack, split between opposite edges.
        assert_operator xs.min, :<, 0.5, label
        assert_operator ys.min, :<, 0.5, label
        assert_operator xs.max, :>, canvas_width - 0.5, label
        assert_operator ys.max, :>, canvas_height - 0.5, label
      end
    end

    def test_quarter_turns_map_image_corners_onto_canvas_corners_and_back
      each_case(QUARTER_TURNS) do |w, h, degrees, label|
        to_canvas, canvas_width, canvas_height = Geometry.rotation_canvas(w, h, degrees)
        to_image = to_canvas.invert

        assert_equal corners(canvas_width, canvas_height).sort, corners(w, h).map { |c| to_canvas.apply(c).to_a }.sort, label
        assert_equal corners(w, h).sort, corners(canvas_width, canvas_height).map { |c| to_image.apply(c).to_a }.sort, label
      end
    end

    def test_image_center_maps_to_canvas_center
      each_case do |w, h, degrees, label|
        to_canvas, canvas_width, canvas_height = Geometry.rotation_canvas(w, h, degrees)

        assert_point_in_delta [canvas_width / 2.0, canvas_height / 2.0], to_canvas.apply([w / 2.0, h / 2.0])
        assert_point_in_delta [w / 2.0, h / 2.0], to_canvas.invert.apply([canvas_width / 2.0, canvas_height / 2.0])
      rescue Minitest::Assertion => e
        raise e.exception("#{label}: #{e.message}")
      end
    end

    def test_inverse_maps_canvas_points_back
      random = Random.new(42)
      each_case do |w, h, degrees, label|
        to_canvas, = Geometry.rotation_canvas(w, h, degrees)
        to_image = to_canvas.invert
        points = corners(w, h) + Array.new(10) { [random.rand(0.0..w), random.rand(0.0..h)] }

        points.each do |point|
          assert_point_in_delta point, to_image.apply(to_canvas.apply(point)), 1e-6
        end
      rescue Minitest::Assertion => e
        raise e.exception("#{label}: #{e.message}")
      end
    end

    def test_transform_rotation_matches_the_angle
      each_case do |w, h, degrees, label|
        to_canvas, = Geometry.rotation_canvas(w, h, degrees)

        assert_in_delta degrees % 360, to_canvas.rotation_degrees, 1e-9, label
        assert_in_delta(-degrees % 360, to_canvas.invert.rotation_degrees, 1e-9, label)
      end
    end

    def test_rejects_invalid_arguments
      [
        [0, 10, 0], [10, 0, 0], [-1, 10, 0], [10.0, 10, 0], [nil, 10, 0], [10, "10", 0],
        [10, 10, Float::NAN], [10, 10, Float::INFINITY], [10, 10, nil], [10, 10, "90"]
      ].each do |args|
        assert_raises(ArgumentError, args.inspect) { Geometry.rotation_canvas(*args) }
      end
    end
  end
end
