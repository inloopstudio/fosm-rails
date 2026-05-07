# frozen_string_literal: true

require "test_helper"

# =============================================================================
# Registry Tests
# Covers: clear!, repopulate!, and development-reload correctness.
# =============================================================================

# A Fosm::* model for repopulate! to discover via ObjectSpace — defined at the
# top level so Ruby resolves Fosm::Lifecycle correctly.
unless defined?(Fosm::RegistryTestFixture)
  module Fosm
    class RegistryTestFixture < ApplicationRecord
      include ::Fosm::Lifecycle
      self.table_name = "test_invoices"
      lifecycle do
        state :open, initial: true
        state :closed, terminal: true
        event :close, from: :open, to: :closed
      end
    end
  end
end

class RegistryTest < ActiveSupport::TestCase
  # Snapshot the registry before each test and restore it after, so individual
  # tests can mutate the registry without polluting each other.
  def setup
    @snapshot = Fosm::Registry.all.dup
  end

  def teardown
    Fosm::Registry.clear!
    @snapshot.each { |slug, klass| Fosm::Registry.register(klass, slug: slug) }
  end

  # ---------------------------------------------------------------------------
  # clear!
  # ---------------------------------------------------------------------------

  test "clear! empties the registry" do
    # Seed the registry explicitly so the test is not sensitive to boot order
    Fosm::Registry.register(TestInvoice, slug: "clearable_invoice")

    assert Fosm::Registry.all.any?, "expected the registry to have entries before clear!"

    Fosm::Registry.clear!

    assert Fosm::Registry.all.empty?, "expected the registry to be empty after clear!"
  end

  test "clear! makes find return nil for previously registered slugs" do
    Fosm::Registry.register(TestInvoice, slug: "test_invoice_tmp")

    assert_equal TestInvoice, Fosm::Registry.find("test_invoice_tmp")

    Fosm::Registry.clear!

    assert_nil Fosm::Registry.find("test_invoice_tmp")
  end

  test "clear! makes all return an empty hash" do
    Fosm::Registry.clear!

    assert_equal({}, Fosm::Registry.all)
  end

  # ---------------------------------------------------------------------------
  # Re-registration after clear!
  # ---------------------------------------------------------------------------

  test "register works correctly after clear!" do
    Fosm::Registry.clear!

    Fosm::Registry.register(TestInvoice, slug: "test_invoice")

    assert_equal TestInvoice, Fosm::Registry.find("test_invoice")
    assert_equal 1, Fosm::Registry.all.size
  end

  test "re-registering a slug with a new class object reflects the new class" do
    # Simulate what happens after a Rails class reload: the constant now points
    # to a NEW class object, but the slug key stays the same.
    old_klass = TestInvoice
    Fosm::Registry.register(old_klass, slug: "refreshable")

    assert_equal old_klass, Fosm::Registry.find("refreshable")

    # Simulate reload: create a fresh anonymous class with the same lifecycle
    new_klass = Class.new(ApplicationRecord) do
      include Fosm::Lifecycle
      self.table_name = "test_invoices"
      lifecycle do
        state :draft, initial: true
        event :activate, from: :draft, to: :draft
      end
    end

    # Re-register with same slug (as to_prepare would do after a reload)
    Fosm::Registry.clear!
    Fosm::Registry.register(new_klass, slug: "refreshable")

    assert_equal new_klass, Fosm::Registry.find("refreshable"),
      "after clear! + re-register, Registry should hold the new class object"
    refute_equal old_klass, Fosm::Registry.find("refreshable"),
      "old class object must not be returned after reload"
  end

  # ---------------------------------------------------------------------------
  # repopulate!
  # A small inline Fosm::* model is created to give repopulate! something to
  # find without modifying the dummy app.
  # ---------------------------------------------------------------------------

  test "repopulate! re-registers Fosm::* models found in ObjectSpace" do
    Fosm::Registry.clear!
    assert Fosm::Registry.all.empty?

    Fosm::Registry.repopulate!

    assert Fosm::Registry.find("registry_test_fixture"),
      "expected repopulate! to register Fosm::RegistryTestFixture"
  end

  test "repopulate! is idempotent — calling it twice yields the same result" do
    Fosm::Registry.clear!
    Fosm::Registry.repopulate!
    first_slugs = Fosm::Registry.slugs.sort

    Fosm::Registry.repopulate!
    second_slugs = Fosm::Registry.slugs.sort

    assert_equal first_slugs, second_slugs,
      "repopulate! called twice should produce the same registry slugs"
  end

  test "repopulate! skips non-FOSM ActiveRecord models" do
    Fosm::Registry.clear!
    Fosm::Registry.repopulate!

    # ApplicationRecord itself must not be registered (it has no lifecycle)
    assert_nil Fosm::Registry.find("application_record")

    # Every registered model must have a lifecycle
    Fosm::Registry.all.each do |slug, klass|
      assert klass.fosm_lifecycle.present?,
        "#{klass.name} (slug: #{slug}) has no lifecycle but was registered"
    end
  end
end
