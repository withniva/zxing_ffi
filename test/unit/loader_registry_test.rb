# frozen_string_literal: true

require "test_helper"

# Loader registry: order, explicit loader, LoaderUnavailable messages.
class LoaderRegistryTest < Minitest::Test
  REGISTRY = ZXingFFI::Loaders::Registry

  # A loader with fixed capabilities.
  def fake_loader(name, kinds:, available: true, reason: nil, hint: "install #{name}")
    Class.new(ZXingFFI::Loaders::Base) do
      define_singleton_method(:loader_name) { name }
      define_singleton_method(:kinds) { kinds }
      define_singleton_method(:install_hint) { hint }
      define_singleton_method(:probe) do
        @unavailable_reason = reason
        available
      end
      singleton_class.send(:private, :probe)
    end
  end

  # Routes Loaders.fetch to fakes for the duration of the block.
  def with_fakes(fakes)
    original = ZXingFFI::Loaders.method(:fetch)
    ZXingFFI::Loaders.define_singleton_method(:fetch) do |name|
      fakes.fetch(name.to_sym) { raise ArgumentError, "unknown loader #{name.inspect}" }
    end
    yield
  ensure
    ZXingFFI::Loaders.define_singleton_method(:fetch, original)
  end

  def test_fetch
    assert_equal ZXingFFI::Loaders::PnmLoader, ZXingFFI::Loaders.fetch(:pnm)
    assert_equal ZXingFFI::Loaders::PnmLoader, ZXingFFI::Loaders.fetch("pnm")
    assert_equal %i[poppler vips image_magick pnm], ZXingFFI::Loaders::NAMES.keys
    error = assert_raises(ArgumentError) { ZXingFFI::Loaders.fetch(:gimp) }
    assert_includes error.message, "poppler"
  end

  def test_pnm_loader_is_always_available
    assert ZXingFFI::Loaders::PnmLoader.available?
    assert ZXingFFI::Loaders::PnmLoader.supports?(:pnm)
    refute ZXingFFI::Loaders::PnmLoader.supports?(:png)
    assert_equal ZXingFFI::Loaders::PnmLoader, REGISTRY.loader_for(:pnm, config: ZXingFFI::Config.new.with(image_loaders: [:pnm]))
  end

  def test_first_supporting_available_loader_in_config_order_wins
    vips = fake_loader(:vips, kinds: %i[png jpeg])
    magick = fake_loader(:image_magick, kinds: %i[png bmp])
    pnm = fake_loader(:pnm, kinds: %i[pnm])
    with_fakes(vips: vips, image_magick: magick, pnm: pnm) do
      config = ZXingFFI::Config.new
      assert_equal vips, REGISTRY.loader_for(:png, config: config)
      assert_equal magick, REGISTRY.loader_for(:bmp, config: config)
      assert_equal pnm, REGISTRY.loader_for(:pnm, config: config)
      assert_equal magick, REGISTRY.loader_for(:png, config: config.with(image_loaders: %i[image_magick vips]))
    end
  end

  def test_unavailable_loaders_are_skipped
    vips = fake_loader(:vips, kinds: %i[png], available: false, reason: "libvips not found")
    magick = fake_loader(:image_magick, kinds: %i[png])
    with_fakes(vips: vips, image_magick: magick, pnm: fake_loader(:pnm, kinds: %i[pnm])) do
      assert_equal magick, REGISTRY.loader_for(:png, config: ZXingFFI::Config.new)
    end
  end

  def test_pdf_uses_the_pdf_loader_order
    poppler = fake_loader(:poppler, kinds: %i[pdf], available: false, reason: "pdftoppm not found")
    vips = fake_loader(:vips, kinds: %i[pdf png])
    with_fakes(poppler: poppler, vips: vips) do
      assert_equal vips, REGISTRY.loader_for(:pdf, config: ZXingFFI::Config.new)
    end
    assert_equal %i[poppler vips], REGISTRY.default_order(:pdf, ZXingFFI::Config.new)
    assert_equal %i[vips image_magick pnm], REGISTRY.default_order(:png, ZXingFFI::Config.new)
  end

  def test_explicit_loader_overrides_order
    vips = fake_loader(:vips, kinds: %i[png])
    magick = fake_loader(:image_magick, kinds: %i[png])
    with_fakes(vips: vips, image_magick: magick) do
      assert_equal magick, REGISTRY.loader_for(:png, loader: :image_magick)
      assert_equal magick, REGISTRY.loader_for(:png, loader: %i[image_magick vips])
    end
  end

  def test_explicit_unavailable_loader_raises_without_fallback
    vips = fake_loader(:vips, kinds: %i[png], available: false, reason: "ruby-vips is not installed")
    magick = fake_loader(:image_magick, kinds: %i[png])
    with_fakes(vips: vips, image_magick: magick) do
      error = assert_raises(ZXingFFI::LoaderUnavailable) { REGISTRY.loader_for(:png, loader: :vips) }
      assert_includes error.message, "vips: ruby-vips is not installed"
      assert_includes error.message, "install vips"
    end
  end

  def test_unknown_loader_name_raises_argument_error
    assert_raises(ArgumentError) { REGISTRY.loader_for(:png, loader: :photoshop) }
  end

  def test_loader_unavailable_lists_attempts_and_install_hints
    fakes = {
      vips: fake_loader(:vips, kinds: %i[png], available: false, reason: "libvips not found", hint: "brew install vips"),
      image_magick: fake_loader(:image_magick, kinds: %i[png], available: false, reason: "magick not found", hint: "brew install imagemagick"),
      pnm: fake_loader(:pnm, kinds: %i[pnm])
    }
    with_fakes(fakes) do
      error = assert_raises(ZXingFFI::LoaderUnavailable) { REGISTRY.loader_for(:png, config: ZXingFFI::Config.new) }

      assert_includes error.message, "No loader available for png input"
      assert_includes error.message, "vips: libvips not found"
      assert_includes error.message, "image_magick: magick not found"
      assert_includes error.message, "pnm: does not read png"
      assert_includes error.message, "brew install vips; or brew install imagemagick"
    end
  end

  def test_kind_supported_in_principle_but_not_in_this_build
    vips = fake_loader(:vips, kinds: %i[png heif])
    vips.define_singleton_method(:supports?) { |kind| kind == :png }
    with_fakes(vips: vips, image_magick: fake_loader(:image_magick, kinds: %i[png]), pnm: fake_loader(:pnm, kinds: %i[pnm])) do
      error = assert_raises(ZXingFFI::LoaderUnavailable) { REGISTRY.loader_for(:heif, config: ZXingFFI::Config.new) }
      assert_includes error.message, "vips: no heif support in this build"
      assert_includes error.message, "image_magick: does not read heif"
    end
  end

  # A present loader that refuses a kind by configuration explains why, and no install hint is offered for it.
  def test_refusal_by_configuration_is_reported_without_install_hints
    vips = fake_loader(:vips, kinds: %i[pdf png], hint: "brew install vips")
    vips.define_singleton_method(:supports?) { |kind| kind == :png }
    vips.define_singleton_method(:unsupported_reason) { |kind| (kind == :pdf) ? "pdfload refused by configuration" : nil }
    with_fakes(vips: vips) do
      error = assert_raises(ZXingFFI::LoaderUnavailable) { REGISTRY.loader_for(:pdf, loader: :vips) }
      assert_includes error.message, "vips: pdfload refused by configuration"
      refute_includes error.message, "brew install vips"
      assert_includes error.message, "see the reasons above"
    end
  end

  def test_availability_is_memoized_until_reset
    calls = 0
    loader = fake_loader(:x, kinds: [:png])
    loader.define_singleton_method(:probe) do
      calls += 1
      true
    end
    3.times { loader.available? }
    assert_equal 1, calls
    loader.reset!
    loader.available?
    assert_equal 2, calls
  end
end
