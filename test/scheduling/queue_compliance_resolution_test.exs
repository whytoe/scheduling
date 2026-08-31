defmodule Scheduling.QueueComplianceResolutionTest do
  @moduledoc """
  A queue entry's compliance references are resolved **at creation**, the same
  way its capabilities are, and for the same reason.

  The gate runs at accept time, often long after creation, and by then the
  entry no longer knows which encounter produced it — `queue_entries.
  diagnosis_id` was dropped deliberately so a named patient is not linked to a
  diagnosis. So whatever the encounter required has to be captured while the
  template is still in hand.

  This is also what stops the gate being a bridge-only control. An entry raised
  from a booking screen inherits its requirements from the catalog exactly as a
  bridge-created one does, rather than sailing through because nobody sent a
  reference. See `docs/intake-compliance-reply.md`.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  @ref_a "cref_7f3a91c4e2b8"
  @ref_b "cref_0b2e5d9a1c74"

  defp patient_fixture do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: "Compliance Resolution"}))
  end

  defp diagnosis_fixture(refs) do
    {:ok, dx} =
      Catalog.create_diagnosis(%{
        "name" => "Pathway #{System.unique_integer([:positive])}",
        "code" => "svc_#{System.unique_integer([:positive])}",
        "required_compliance_refs" => refs
      })

    dx
  end

  describe "resolution from a catalog template" do
    test "a service_code expands to the catalog's references" do
      dx = diagnosis_fixture([@ref_a, @ref_b])

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "service_code" => dx.code
        })

      assert entry.required_compliance_refs == [@ref_a, @ref_b]
    end

    test "a diagnosis_id expands to the catalog's references" do
      dx = diagnosis_fixture([@ref_a])

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "diagnosis_id" => dx.id
        })

      assert entry.required_compliance_refs == [@ref_a]
    end

    test "the diagnosis itself is not stored — only what it implied" do
      dx = diagnosis_fixture([@ref_a])

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "service_code" => dx.code
        })

      refute Map.has_key?(entry, :diagnosis_id)
      refute Map.has_key?(entry, :service_code)
      assert entry.required_compliance_refs == [@ref_a]
    end

    test "a template requiring nothing produces an entry requiring nothing" do
      dx = diagnosis_fixture([])

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "service_code" => dx.code
        })

      assert entry.required_compliance_refs == []
    end
  end

  describe "an explicit list from the caller" do
    test "is used as given" do
      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "required_compliance_refs" => [@ref_a]
        })

      assert entry.required_compliance_refs == [@ref_a]
    end

    # The intake bridge knows the encounter's actual requirements; the catalog
    # holds a default for a pathway. When both are present the caller's is the
    # more specific answer and must not be silently replaced.
    test "overrides the catalog default rather than being overwritten by it" do
      dx = diagnosis_fixture([@ref_a])

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "service_code" => dx.code,
          "required_compliance_refs" => [@ref_b]
        })

      assert entry.required_compliance_refs == [@ref_b]
    end

    test "an explicit empty list overrides the catalog, and means nothing is required" do
      dx = diagnosis_fixture([@ref_a])

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "service_code" => dx.code,
          "required_compliance_refs" => []
        })

      assert entry.required_compliance_refs == []
    end
  end

  describe "entries with no template at all" do
    test "require nothing, and therefore pass the gate" do
      {:ok, entry} = Queue.create_entry(%{"patient_id" => patient_fixture().id})

      # What this means for the gate — that an entry requiring nothing passes
      # even when intake IS configured — is asserted in Scheduling.ComplianceTest,
      # where the api_key can be set. Asserting it here would pass vacuously:
      # this module never configures one.
      assert entry.required_compliance_refs == []
    end
  end
end
