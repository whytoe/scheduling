defmodule Scheduling.QueueCapabilityResolutionTest do
  @moduledoc """
  `create_entry/2` accepts a `diagnosis_id` as a convenience and expands it to
  that diagnosis's default capabilities — then throws the reference away.

  This is what lets the caller say "this pathway" without scheduling storing
  the clinical reason: the entry ends up holding the equipment requirement
  only. See `docs/data-boundary.md`.
  """
  use Scheduling.DataCase, async: true

  alias Scheduling.Catalog
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue

  defp patient_fixture do
    Repo.insert!(Patient.changeset(%Patient{}, %{name: "Resolution Test"}))
  end

  defp capability_fixture(name) do
    {:ok, cap} =
      Catalog.create_capability(%{"name" => "#{name}-#{System.unique_integer([:positive])}"})

    cap
  end

  defp diagnosis_fixture(capability_ids) do
    {:ok, dx} =
      Catalog.create_diagnosis(%{
        "name" => "Pathway #{System.unique_integer([:positive])}",
        "capability_ids" => capability_ids
      })

    dx
  end

  test "a diagnosis id expands to its default capabilities" do
    ct = capability_fixture("CT scanner")
    lab = capability_fixture("Lab")
    dx = diagnosis_fixture([ct.id, lab.id])

    {:ok, entry} =
      Queue.create_entry(%{"patient_id" => patient_fixture().id, "diagnosis_id" => dx.id})

    names = entry.required_capabilities |> Enum.map(& &1.name) |> Enum.sort()
    assert names == Enum.sort([ct.name, lab.name])
  end

  test "the diagnosis reference itself is not stored" do
    ct = capability_fixture("CT scanner")
    dx = diagnosis_fixture([ct.id])

    {:ok, entry} =
      Queue.create_entry(%{"patient_id" => patient_fixture().id, "diagnosis_id" => dx.id})

    refute Map.has_key?(entry, :diagnosis_id)
    refute Map.has_key?(entry, :diagnosis)
  end

  test "an explicit capability list wins over the diagnosis default" do
    ct = capability_fixture("CT scanner")
    xray = capability_fixture("XRay")
    dx = diagnosis_fixture([ct.id])

    {:ok, entry} =
      Queue.create_entry(%{
        "patient_id" => patient_fixture().id,
        "diagnosis_id" => dx.id,
        "required_capability_ids" => [xray.id]
      })

    assert Enum.map(entry.required_capabilities, & &1.name) == [xray.name]
  end

  test "a diagnosis with no default capabilities yields none" do
    dx = diagnosis_fixture([])

    {:ok, entry} =
      Queue.create_entry(%{"patient_id" => patient_fixture().id, "diagnosis_id" => dx.id})

    assert entry.required_capabilities == []
  end

  test "an unknown diagnosis id is a validation error, not a crash" do
    assert {:error, changeset} =
             Queue.create_entry(%{
               "patient_id" => patient_fixture().id,
               "diagnosis_id" => 999_999
             })

    assert "does not exist" in errors_on(changeset).diagnosis_id
  end

  test "a non-numeric diagnosis id is a validation error" do
    assert {:error, changeset} =
             Queue.create_entry(%{"patient_id" => patient_fixture().id, "diagnosis_id" => "abc"})

    assert "does not exist" in errors_on(changeset).diagnosis_id
  end

  test "omitting both leaves the entry with no requirements" do
    {:ok, entry} = Queue.create_entry(%{"patient_id" => patient_fixture().id})

    assert entry.required_capabilities == []
  end

  describe "service_code — the external contract key" do
    test "resolves to the catalog entry's default capabilities" do
      ct = capability_fixture("CT scanner")

      {:ok, dx} =
        Catalog.create_diagnosis(%{
          "name" => "Imaging",
          "code" => "svc_7a2f",
          "capability_ids" => [ct.id]
        })

      {:ok, entry} =
        Queue.create_entry(%{"patient_id" => patient_fixture().id, "service_code" => dx.code})

      assert Enum.map(entry.required_capabilities, & &1.name) == [ct.name]
    end

    test "the code itself is not stored — only the equipment it implied" do
      ct = capability_fixture("CT scanner")

      {:ok, dx} =
        Catalog.create_diagnosis(%{
          "name" => "Imaging",
          "code" => "svc_b3e1",
          "capability_ids" => [ct.id]
        })

      {:ok, entry} =
        Queue.create_entry(%{"patient_id" => patient_fixture().id, "service_code" => dx.code})

      refute Map.has_key?(entry, :service_code)
      refute Map.has_key?(entry, :diagnosis_id)
    end

    test "an unknown code is a validation error, not a crash" do
      assert {:error, changeset} =
               Queue.create_entry(%{
                 "patient_id" => patient_fixture().id,
                 "service_code" => "svc_nope"
               })

      assert "does not exist" in errors_on(changeset).service_code
    end

    test "an explicit capability list still wins" do
      ct = capability_fixture("CT scanner")
      xray = capability_fixture("XRay")

      {:ok, dx} =
        Catalog.create_diagnosis(%{
          "name" => "Imaging",
          "code" => "svc_c4d2",
          "capability_ids" => [ct.id]
        })

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "service_code" => dx.code,
          "required_capability_ids" => [xray.id]
        })

      assert Enum.map(entry.required_capabilities, & &1.name) == [xray.name]
    end

    test "service_code takes precedence over diagnosis_id" do
      ct = capability_fixture("CT scanner")
      xray = capability_fixture("XRay")

      {:ok, by_code} =
        Catalog.create_diagnosis(%{
          "name" => "ByCode",
          "code" => "svc_e5f3",
          "capability_ids" => [ct.id]
        })

      {:ok, by_id} = Catalog.create_diagnosis(%{"name" => "ById", "capability_ids" => [xray.id]})

      {:ok, entry} =
        Queue.create_entry(%{
          "patient_id" => patient_fixture().id,
          "service_code" => by_code.code,
          "diagnosis_id" => by_id.id
        })

      assert Enum.map(entry.required_capabilities, & &1.name) == [ct.name]
    end
  end

  test "compliance_ref round-trips onto the entry" do
    {:ok, entry} =
      Queue.create_entry(%{
        "patient_id" => patient_fixture().id,
        "compliance_ref" => "enc_01HV3K7Q"
      })

    assert entry.compliance_ref == "enc_01HV3K7Q"
  end
end
