# frozen_string_literal: true

module ZXingFFI
  # A pure-Ruby transformer for strategy tests (small images only). Follows the {Transformers::Base} contract
  # exactly: rotations inverse-map every output pixel through {Geometry.rotation_canvas}, resizes are the centered
  # Catmull-Rom bicubic (computed separably, edges clamped).
  class FakeTransformer < Transformers::Base
    attr_reader :calls

    def self.transformer_name = :fake

    def self.probe = true
    private_class_method :probe

    def initialize(config = ZXingFFI.config)
      super
      @calls = []
    end

    def resize(image, scale)
      @calls << [:resize, scale]
      src = image.to_bytes
      w = (image.width * scale).round
      h = (image.height * scale).round
      across = taps(image.width, w)
      down = taps(image.height, h)
      rows = Array.new(image.height) do |y|
        across.map { |pairs| pairs.sum { |x, weight| weight * src.getbyte(y * image.width + x) } }
      end
      out = down.flat_map do |pairs|
        Array.new(w) { |x| pairs.sum { |y, weight| weight * rows[y][x] }.round.clamp(0, 255) }
      end
      Image.new(out.pack("C*"), width: w, height: h)
    end

    def rotate(image, degrees, background: 255)
      @calls << [:rotate, degrees]
      src = image.to_bytes
      to_canvas, w, h = Geometry.rotation_canvas(image.width, image.height, degrees)
      back = to_canvas.invert
      out = Array.new(h) do |y|
        Array.new(w) do |x|
          p = back.apply([x + 0.5, y + 0.5])
          sx = p.x.floor
          sy = p.y.floor
          (sx.between?(0, image.width - 1) && sy.between?(0, image.height - 1)) ? src.getbyte(sy * image.width + sx) : background
        end
      end
      Image.new(out.flatten.pack("C*"), width: w, height: h)
    end

    private

    # For each of +count+ output pixels along an axis of +size+ input pixels: the four [input index, weight] pairs
    # of the Catmull-Rom kernel around (o + 0.5) / f - 0.5, indices clamped to the edge.
    def taps(size, count)
      factor = count.to_f / size
      Array.new(count) do |o|
        position = (o + 0.5) / factor - 0.5
        first = position.floor
        t = position - first
        weights = [(-t**3 + 2 * t**2 - t) / 2, (3 * t**3 - 5 * t**2 + 2) / 2, (-3 * t**3 + 4 * t**2 + t) / 2, (t**3 - t**2) / 2]
        weights.each_with_index.map { |weight, k| [(first - 1 + k).clamp(0, size - 1), weight] }
      end
    end
  end
end
