# frozen_string_literal: true

require "test_helper"
require_relative "../support/fake_transformer"

# VipsTransformer: sizes, exact quarter turns, and agreement with Geometry.rotation_canvas.
class VipsTransformerTest < Minitest::Test
  IMAGES = ZXingFFI::SyntheticImages

  def setup
    require_tool!(:vips) { ZXingFFI::Transformers::VipsTransformer.available? }
    @transformer = ZXingFFI::Transformers::VipsTransformer.new
    @reference = ZXingFFI::FakeTransformer.new # pure-Ruby implementation of the same contract
  end

  # A small image with a few distinctive dark blocks (side × side pixels).
  def dots(width = 60, height = 40, blocks = [[5, 5], [40, 8], [20, 30]], side: 3)
    pixels = ("\xFF".b * (width * height))
    blocks.each { |x, y| side.times { |dy| pixels[(y + dy) * width + x, side] = ("\x00" * side).b } }
    ZXingFFI::Image.new(pixels, width: width, height: height)
  end

  def test_availability_and_diagnostics
    assert ZXingFFI::Transformers::VipsTransformer.available?
    assert_match(/\A8\./, ZXingFFI::Transformers::VipsTransformer.diagnostics[:version])
    assert_kind_of ZXingFFI::Transformers::VipsTransformer, ZXingFFI::Transformers.first_available(%i[vips])
  end

  def test_integer_upscale_replicates_pixels
    image = dots
    out = @transformer.resize(image, 2)

    assert_equal [120, 80], [out.width, out.height]
    assert_equal :lum, out.format
    assert_equal @reference.resize(image, 2).to_bytes, out.to_bytes, "2x zoom must equal nearest-neighbour replication"
  end

  def test_fractional_resize_sizes
    out = @transformer.resize(dots(61, 41), 1.5)
    assert_equal [92, 62], [out.width, out.height]
    down = @transformer.resize(dots, 0.5)
    assert_equal [30, 20], [down.width, down.height]
    assert_raises(ArgumentError) { @transformer.resize(dots, 0) }
  end

  def test_resized_qr_still_decodes
    require_native!
    small = IMAGES.qr_image(scale: 1, quiet: 2)
    assert_equal [IMAGES::QR_TEXT], ZXingFFI.read(@transformer.resize(small, 3)).map(&:text)
  end

  def test_quarter_turns_are_exact
    image = dots
    [90, 180, 270, -90, 450].each do |degrees|
      out = @transformer.rotate(image, degrees)
      expected = @reference.rotate(image, degrees)
      assert_equal [expected.width, expected.height], [out.width, out.height], "#{degrees}°"
      assert_equal expected.to_bytes, out.to_bytes, "#{degrees}° must be pixel-exact"
    end
    assert_equal image.to_bytes, @transformer.rotate(image, 0).to_bytes
    assert_equal image.to_bytes, @transformer.rotate(image, 360).to_bytes
  end

  def test_arbitrary_angles_match_rotation_canvas
    image = dots(100, 60, [[10, 10], [70, 12], [35, 40]], side: 5)
    originals = dark_blocks(image)
    [30, 45, -30, 135, 10].each do |degrees|
      out = @transformer.rotate(image, degrees)
      to_canvas, width, height = ZXingFFI::Geometry.rotation_canvas(image.width, image.height, degrees)
      assert_in_delta width, out.width, 1, "#{degrees}° canvas width"
      assert_in_delta height, out.height, 1, "#{degrees}° canvas height"

      shift = ZXingFFI::Geometry::Affine.translation((out.width - width) / 2.0, (out.height - height) / 2.0)
      predicted = originals.map { |x, y| shift.compose(to_canvas).apply([x, y]) }
      actual = dark_blocks(out)
      predicted.each do |point|
        nearest = actual.min_by { |x, y| (x - point.x)**2 + (y - point.y)**2 }
        assert_in_delta point.x, nearest[0], 1.5, "#{degrees}° x of #{point.to_a}"
        assert_in_delta point.y, nearest[1], 1.5, "#{degrees}° y of #{point.to_a}"
      end
    end
  end

  def test_background_fill
    out = @transformer.rotate(ZXingFFI::Image.new("\x00".b * 400, width: 20, height: 20), 45, background: 200)
    assert_equal 200, out.to_bytes.getbyte(0), "the uncovered corner is filled with the background"
  end

  def test_rotated_qr_decodes_with_rotation
    require_native!
    out = @transformer.rotate(IMAGES.qr_image(scale: 5), 30)
    barcode = ZXingFFI.read(out).first
    refute_nil barcode
    assert_in_delta 30, barcode.rotation, 3
  end

  def test_row_stride_is_honored
    pixels, width, height = IMAGES.render(scale: 2)
    padded = pixels.bytes.each_slice(width).map { |row| row.pack("C*") + "\xFF\xFF\xFF".b }.join
    image = ZXingFFI::Image.new(padded, width: width, height: height, row_stride: width + 3)
    out = @transformer.resize(image, 1.0)
    assert_equal [width, height], [out.width, out.height]
    assert_equal pixels, out.to_bytes
  end

  def test_rejects_non_lum_images
    rgb = ZXingFFI::Image.new("\x00".b * 12, width: 2, height: 2, format: :rgb)
    assert_raises(ArgumentError) { @transformer.resize(rgb, 2) }
  end

  private

  # Centroids of connected dark blobs (4-connectivity), for images with a few isolated blocks.
  def dark_blocks(image)
    data = image.to_bytes
    seen = {}
    blobs = []
    image.height.times do |y|
      image.width.times do |x|
        next if seen[[x, y]] || data.getbyte(y * image.width + x) >= 128

        stack = [[x, y]]
        pixels = []
        seen[[x, y]] = true
        until stack.empty?
          px, py = stack.pop
          pixels << [px + 0.5, py + 0.5]
          [[1, 0], [-1, 0], [0, 1], [0, -1]].each do |dx, dy|
            nx = px + dx
            ny = py + dy
            next if nx.negative? || ny.negative? || nx >= image.width || ny >= image.height || seen[[nx, ny]]
            next if data.getbyte(ny * image.width + nx) >= 128

            seen[[nx, ny]] = true
            stack << [nx, ny]
          end
        end
        blobs << weighted_centroid(image, data, pixels)
      end
    end
    blobs
  end

  # Darkness-weighted centroid over a blob and its anti-aliased rim (2 px around its bounding box).
  def weighted_centroid(image, data, pixels)
    xs = pixels.map(&:first)
    ys = pixels.map(&:last)
    sum_x = sum_y = total = 0.0
    ((xs.min - 2).floor..(xs.max + 2).ceil).each do |x|
      ((ys.min - 2).floor..(ys.max + 2).ceil).each do |y|
        next if x.negative? || y.negative? || x >= image.width || y >= image.height

        weight = (255 - data.getbyte(y * image.width + x)) / 255.0
        sum_x += (x + 0.5) * weight
        sum_y += (y + 0.5) * weight
        total += weight
      end
    end
    [sum_x / total, sum_y / total]
  end
end
