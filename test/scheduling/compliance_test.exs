defmodule Scheduling.ComplianceTest do
  @moduledoc """
  The non-HTTP branches of `Scheduling.Compliance.verify/1` — every case where
  there is nothing to ask intake about. The HTTP paths live in
  `Scheduling.ComplianceHttpTest`.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Compliance
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry

  @patient_uuid "22222222-2222-2222-2222-222222222222"

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

  defp patient_fixture(attrs) do
    attrs = Map.merge(%{name: "Compliance Test"}, Map.new(attrs))
    Repo.insert!(Patient.changeset(%Patient{}, attrs))
  end

  defp entry(patient, compliance_ref) do
    %QueueEntry{
      id: 1,
      patient_id: patient.id,
      patient: patient,
      compliance_ref: compliance_ref,
      required_capabilities: []
    }
  end

  describe "verify/1 skips the gate when there is nothing to ask" do
    test "no API key configured" do
      put_api_key(nil)
      patient = patient_fixture(%{intake_patient_id: @patient_uuid})

      assert Compliance.verify(entry(patient, "enc_1")) == :not_configured
    end

    test "no compliance reference on the entry" do
      # The expected state until ac-checkin starts supplying references. Fails
      # open by design — same posture as an unconfigured intake.
      put_api_key("ik_test_dummy")
      patient = patient_fixture(%{intake_patient_id: @patient_uuid})

      assert Compliance.verify(entry(patient, nil)) == :not_configured
    end

    test "an empty-string reference is treated as no reference" do
      put_api_key("ik_test_dummy")
      patient = patient_fixture(%{intake_patient_id: @patient_uuid})

      assert Compliance.verify(entry(patient, "")) == :not_configured
    end

    test "no intake_patient_id to correlate against" do
      put_api_key("ik_test_dummy")
      patient = patient_fixture(%{intake_patient_id: nil})

      assert Compliance.verify(entry(patient, "enc_1")) == :not_configured
    end
  end
end
