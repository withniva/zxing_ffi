# frozen_string_literal: true

module ZXingFFI
  # A pure-Ruby transformer for strategy tests (small images only). Follows the {Transformers::Base} geometry
  # contract exactly by inverse-mapping every output pixel through {Geometry.rotation_canvas}.
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
      out = Array.new(h) do |y|
        sy = [(y / scale).floor, image.height - 1].min
        Array.new(w) { |x| src.getbyte(sy * image.width + [(x / scale).floor, image.width - 1].min) }
      end
      Image.new(out.flatten.pack("C*"), width: w, height: h)
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
  end
end
