# frozen_string_literal: true

require "test_helper"
require "project_types/extension/extension_test_helpers"

module Extension
  module Models
    module SpecificationHandlers
      class CheckoutUiExtensionTest < MiniTest::Test
        include ExtensionTestHelpers
        INVALID_L10N_FILENAMES = [
          "FR-CA.json", # uppercase language tag
          "french.json", # language tag > 3 characters
          "fren-CA.json", # language tag > 3 characters
          "fr.defalt.json", # typo in default
          "11-CA.json", # numbers in language tag
          "fr.CA.json", # dot instead of dash
          "fr_CA.json", # underscore instead of dash
        ]

        def setup
          super
          YAML.stubs(:load_file).returns({})
          ShopifyCLI::ProjectType.load_type(:extension)
          Features::Argo.any_instance.stubs(:config).returns({})
          Features::ArgoConfig.stubs(:parse_yaml).returns({})

          specifications = DummySpecifications.build(identifier: "checkout_ui_extension", surface: "checkout")

          @identifier = "CHECKOUT_UI_EXTENSION"
          @checkout_ui_extension = specifications[@identifier]
          @context.root = Dir.mktmpdir
        end

        def teardown
          FileUtils.remove_dir(@context.root)
        end

        def test_create_uses_standard_argo_create_implementation
          directory_name = "checkout_ui_extension"

          Features::Argo.any_instance
            .expects(:create)
            .with(directory_name, @identifier, @context)
            .once

          @checkout_ui_extension.create(directory_name, @context)
        end

        def test_config_uses_standard_argo_config_implementation
          Features::Argo.any_instance.expects(:config).with(@context, include_renderer_version: false).once.returns({})
          @checkout_ui_extension.config(@context)
        end

        def test_config_merges_with_standard_argo_config_implementation
          script_content = "alert(true)"
          metafields = [{ key: "a-key", namespace: "a-namespace" }]
          extension_points = ["Checkout::Feature::Render"]
          name = "Extension name"

          initial_config = { script_content: script_content }
          yaml_config = { "extension_points": extension_points, "metafields": metafields, "name": name }

          Features::Argo.any_instance.expects(:config).with(@context, include_renderer_version: false).once
            .returns(initial_config)
          Features::ArgoConfig.stubs(:parse_yaml).returns(yaml_config)

          config = @checkout_ui_extension.config(@context)
          assert_equal(metafields, config[:metafields])
          assert_equal(extension_points, config[:extension_points])
          assert_equal(name, config[:name])
          assert_equal(script_content, config[:script_content])
        end

        def test_config_passes_allowed_keys
          Features::Argo.any_instance.stubs(:config).returns({})
          Features::ArgoConfig
            .expects(:parse_yaml)
            .with(@context, [:extension_points, :metafields, :name])
            .once
            .returns({})

          @checkout_ui_extension.config(@context)
        end

        def test_graphql_identifier
          assert_equal @identifier, @checkout_ui_extension.graphql_identifier
        end

        def test_build_resource_url
          shop = stub
          product = mock(variant_id: 0)

          Tasks::GetProduct.expects(:call).with(@context, shop).returns(product)

          resource_url = @checkout_ui_extension.build_resource_url(context: @context, shop: shop)
          assert_equal "/cart/0:1", resource_url
        end

        def test_build_resource_url_nil_safety
          shop = stub
          Tasks::GetProduct.expects(:call).with(@context, shop).returns(nil)

          resource_url = @checkout_ui_extension.build_resource_url(context: @context, shop: shop)
          assert_nil resource_url
        end

        def test_l10n_files_encoded
          en_content = '{"laugh": "lol"}'
          fr_content = '{"laugh": "mdr"}'
          write("locales/fr.default.json", fr_content)
          write("locales/en.json", en_content)

          expected = {
            "localization" => {
              "translations" => {
                "fr" => Base64.strict_encode64(fr_content),
                "en" => Base64.strict_encode64(en_content),
              },
              "default_locale" => "fr"
            },
          }
          assert_equal(expected, @checkout_ui_extension.config(@context))
        end

        def test_l10n_files_at_root_are_ignored
          write("locales/fr.default.json", "{}")
          write("wut.json", "{}")
          config = @checkout_ui_extension.config(@context)
          refute_includes(config["localization"]["translations"], "wut")
        end

        def test_non_locale_files_are_ignored
          assert_nothing_raised do
            write("invalid-folder/fr.json", "{}")
            config = @checkout_ui_extension.config(@context)
            refute_includes(config, "localization")
          end
        end

        def test_l10n_multiple_defaults
          write("locales/fr.default.json", "{}")
          write("locales/en.default.json", "{}")
          assert_raises Extension::Errors::SingleDefaultLocaleError do
            @checkout_ui_extension.config(@context)
          end
        end

        def test_l10n_no_defaults
          write("locales/fr.json", "{}")
          assert_raises Extension::Errors::SingleDefaultLocaleError do
            @checkout_ui_extension.config(@context)
          end
        end



        def test_l10n_file_extension
          write("locales/fr.txt", "hello")
          assert_raises Extension::Errors::InvalidFilenameError do
            @checkout_ui_extension.config(@context)
          end
        end

        def test_l10n_max_filesize
          stub_const(CheckoutUiExtension, :L10N_FILE_SIZE_LIMIT, 50) do
            write("locales/fr.json", "1" * 1000)
            assert_raises Extension::Errors::FileTooLargeError do
              @checkout_ui_extension.config(@context)
            end
          end
        end

        def test_l10n_sum_max_filesize
          stub_const(CheckoutUiExtension, :L10N_BUNDLE_SIZE_LIMIT, 50) do
            write("locales/fr.json", "1" * 30)
            write("locales/en.default.json", "1" * 30)
            assert_raises Extension::Errors::BundleTooLargeError do
              @checkout_ui_extension.config(@context)
            end
          end
        end

        INVALID_L10N_FILENAMES.each do |filename|
          define_method("test_l10n_filename_#{filename}") do
            write("locales/fr.default.json", "{}")
            write("locales/#{filename}", "{}")
            assert_raises Extension::Errors::InvalidFilenameError do
              @checkout_ui_extension.config(@context)
            end
          end
        end

        private

        def write(filename, content, mode: "w", encoding: "utf-8")
          filename = File.join(@context.root, filename)
          FileUtils.mkdir_p(File.dirname(filename))
          File.write(filename, content, mode: mode, encoding: encoding)
        end

        def stub_const(object, name, value)
          original = object.const_get(name)
          silent_const_set(object, name, value)
          yield
        ensure
          silent_const_set(object, name, original)
        end

        def silent_const_set(object, name, value)
          old_verbose = $VERBOSE
          $VERBOSE = nil
          object.const_set(name, value)
          $VERBOSE = old_verbose
        end
      end
    end
  end
end
