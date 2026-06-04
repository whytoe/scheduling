defmodule Scheduling.ComplianceTest do
  use Scheduling.DataCase, async: false

  alias Scheduling.Catalog.Diagnosis
  alias Scheduling.Compliance
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry

  setup do
    # Capture and restore Compliance config around each test so we can flip
    # the api_key on/off without leaking between tests.
    original = Application.get_env(:scheduling, Compliance)
    on_exit(fn -> Application.put_env(:scheduling, Compliance, original) end)
    %{original_config: original}
  end

  defp put_api_key(key) do
    cfg = (Application.get_env(:scheduling, Compliance) || []) |> Keyword.put(:api_key, key)
    Application.put_env(:scheduling, Compliance, cfg)
  end

  defp clear_api_key do
    cfg = (Application.get_env(:scheduling, Compliance) || []) |> Keyword.put(:api_key, nil)
    Application.put_env(:scheduling, Compliance, cfg)
  end

  defp patient_fixture(attrs \\ %{}) do
    attrs = Map.merge(%{name: "Compliance Test"}, Map.new(attrs))
    Repo.insert!(Patient.changeset(%Patient{}, attrs))
  end

  defp diagnosis_fixture(attrs) do
    attrs = Map.merge(%{name: "Compliance Dx", code: "DX-COMP"}, Map.new(attrs))
    Repo.insert!(Diagnosis.changeset(%Diagnosis{}, attrs))
  end

  defp entry(patient, diagnosis) do
    %QueueEntry{
      id: 1,
      patient_id: patient.id,
      patient: patient,
      diagnosis_id: diagnosis && diagnosis.id,
      diagnosis: diagnosis,
      required_capabilities: []
    }
  end

  describe "verify/1 with no API key configured" do
    test "returns :not_configured regardless of required_form_types" do
      clear_api_key()
      patient = patient_fixture()
      dx = diagnosis_fixture(%{required_form_types: ["stroke-consent"]})

      assert Compliance.verify(entry(patient, dx)) == :not_configured
    end
  end

  describe "verify/1 with API key configured" do
    setup do
      put_api_key("ik_test_dummy")
      :ok
    end

    test "returns :ok when diagnosis has no required forms" do
      patient = patient_fixture(%{intake_patient_id: "11111111-1111-1111-1111-111111111111"})
      dx = diagnosis_fixture(%{required_form_types: []})

      assert Compliance.verify(entry(patient, dx)) == :ok
    end

    test "returns :ok when entry has no diagnosis" do
      patient = patient_fixture(%{intake_patient_id: "11111111-1111-1111-1111-111111111111"})

      # No diagnosis associated -> nothing required -> :ok
      assert Compliance.verify(entry(patient, nil)) == :ok
    end

    test "blocks with the required types when patient has no intake_patient_id" do
      patient = patient_fixture(%{intake_patient_id: nil})
      dx = diagnosis_fixture(%{required_form_types: ["stroke-consent", "imaging-consent"]})

      assert {:missing, missing} = Compliance.verify(entry(patient, dx))
      assert Enum.sort(missing) == ["imaging-consent", "stroke-consent"]
    end
  end
end
