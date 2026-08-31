defmodule Scheduling.ComplianceTest do
  @moduledoc """
  The non-HTTP branches of `Scheduling.Compliance.verify/1` — every case where
  there is nothing to ask intake about. The HTTP paths live in
  `Scheduling.ComplianceHttpTest`.

  Every test here asserts `:not_configured`, which the accept flow treats as a
  pass, so each one needs to fail for the *stated* reason and not merely
  because some other precondition was also missing. That is why the api_key is
  set explicitly in all but the first case, and why there is no Bypass server:
  if a test here ever reaches HTTP it will error rather than quietly succeed.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Compliance
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry

  @patient_uuid "22222222-2222-2222-2222-222222222222"
  @ref "cref_7f3a91c4e2b8"

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

  defp entry(patient, refs) do
    %QueueEntry{
      id: 1,
      patient_id: patient.id,
      patient: patient,
      required_compliance_refs: refs,
      required_capabilities: []
    }
  end

  describe "verify/1 skips the gate when there is nothing to ask" do
    test "no API key configured" do
      put_api_key(nil)
      patient = patient_fixture(%{intake_patient_id: @patient_uuid})

      assert Compliance.verify(entry(patient, [@ref])) == :not_configured
    end

    test "the entry requires nothing" do
      # An entry created without a template and without an explicit list. Fails
      # open by design — the same posture as an unconfigured intake, and as an
      # encounter whose pathway genuinely required no forms.
      put_api_key("ik_test_dummy")
      patient = patient_fixture(%{intake_patient_id: @patient_uuid})

      assert Compliance.verify(entry(patient, [])) == :not_configured
    end

    test "blank references are treated as no references" do
      # An empty string is not a reference. Sending one would earn a 400 that
      # reads as a stale-config fault when the truth is that nothing was
      # required.
      put_api_key("ik_test_dummy")
      patient = patient_fixture(%{intake_patient_id: @patient_uuid})

      assert Compliance.verify(entry(patient, ["", "   "])) == :not_configured
    end

    test "a nil reference list is treated as no references" do
      put_api_key("ik_test_dummy")
      patient = patient_fixture(%{intake_patient_id: @patient_uuid})

      assert Compliance.verify(entry(patient, nil)) == :not_configured
    end

    test "no intake_patient_id to correlate against" do
      put_api_key("ik_test_dummy")
      patient = patient_fixture(%{intake_patient_id: nil})

      assert Compliance.verify(entry(patient, [@ref])) == :not_configured
    end
  end
end
