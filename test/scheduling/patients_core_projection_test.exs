defmodule Scheduling.PatientsCoreProjectionTest do
  @moduledoc """
  Patients as a projection of ac-core's registry, against a Bypass server
  playing ac-core.

  Two behaviours carry most of the weight here. `resolve_from_core/1` must not
  call the registry when it already has the row — it runs on the arrival path,
  where a patient is waiting — so there is a test that fails if it ever starts.
  And a registry that is *down* has to be distinguishable from a patient the
  registry does not *have*, because a caller should retry one and refuse the
  other.

  `async: false` — these mutate application env.
  """
  use Scheduling.DataCase, async: false

  alias Scheduling.Patients
  alias Scheduling.Patients.Patient

  @core_id "3f2b8c1d-7a45-4e29-b0c6-4d8e1f9a2b73"
  @token "svc_access_token"

  setup do
    bypass = Bypass.open()

    original_core = Application.get_env(:scheduling, Scheduling.Core)
    original_auth = Application.get_env(:scheduling, Scheduling.Auth)

    Application.put_env(:scheduling, Scheduling.Core,
      base_url: "http://localhost:#{bypass.port}",
      client_id: "scheduling-svc",
      client_secret: "shh",
      http_timeout_ms: 500
    )

    # Core.enabled?/0 also requires Auth.enabled?/0 — the token exchange runs
    # through the shared provider worker.
    Application.put_env(:scheduling, Scheduling.Auth,
      issuer: "http://localhost:#{bypass.port}",
      client_id: "scheduling",
      client_secret: "shh"
    )

    start_supervised!({__MODULE__.TokenStub, {:ok, @token}})

    on_exit(fn ->
      Application.put_env(:scheduling, Scheduling.Core, original_core)
      Application.put_env(:scheduling, Scheduling.Auth, original_auth)
    end)

    %{bypass: bypass}
  end

  # Stands in for the ServiceToken GenServer so these tests exercise the
  # projection, not the token cache. ServiceToken has its own test.
  defmodule TokenStub do
    @moduledoc false
    use GenServer

    def start_link(reply),
      do: GenServer.start_link(__MODULE__, reply, name: Scheduling.Auth.ServiceToken)

    @impl GenServer
    def init(reply), do: {:ok, reply}

    @impl GenServer
    def handle_call(:fetch, _from, reply), do: {:reply, reply, reply}

    @impl GenServer
    def handle_cast(:invalidate, reply), do: {:noreply, reply}
  end

  defp stub_patient(bypass, body, status \\ 200) do
    Bypass.stub(bypass, "GET", "/v1/patients/#{@core_id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  defp core_patient(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => @core_id,
        "practiceId" => "practice-1",
        "firstName" => "Jane",
        "lastName" => "Doe"
      },
      overrides
    )
  end

  describe "resolve_from_core/1 when we already hold the row" do
    test "returns it without calling ac-core", %{bypass: bypass} do
      # No stub registered at all: if resolve reaches out, Bypass answers 500
      # and the name would not match. This is the assertion that keeps an HTTP
      # round-trip off the arrival path.
      Bypass.down(bypass)

      {:ok, existing} =
        Patients.create_patient(%{"name" => "Jane Doe", "core_patient_id" => @core_id})

      assert {:ok, found} = Patients.resolve_from_core(@core_id)
      assert found.id == existing.id
      assert found.name == "Jane Doe"
    end

    test "does not notice a stale name — that is refresh's job", %{bypass: bypass} do
      stub_patient(bypass, core_patient(%{"lastName" => "Married"}))
      {:ok, _} = Patients.create_patient(%{"name" => "Jane Doe", "core_patient_id" => @core_id})

      assert {:ok, found} = Patients.resolve_from_core(@core_id)
      assert found.name == "Jane Doe"
    end
  end

  describe "resolve_from_core/1 when the row is new" do
    test "creates it from the registry", %{bypass: bypass} do
      stub_patient(bypass, core_patient())

      assert {:ok, patient} = Patients.resolve_from_core(@core_id)
      assert patient.name == "Jane Doe"
      assert patient.core_patient_id == @core_id
      assert Repo.get(Patient, patient.id)
    end

    test "still generates a client_id, so existing consumers keep working", %{bypass: bypass} do
      stub_patient(bypass, core_patient())

      assert {:ok, patient} = Patients.resolve_from_core(@core_id)
      assert is_binary(patient.client_id)
    end

    test "holds no PII beyond the name and ids", %{bypass: bypass} do
      # ac-core also returns mrn, dateOfBirth, phone and email. The client
      # drops them at the boundary; assert none reached the schema either.
      stub_patient(
        bypass,
        core_patient(%{
          "mrn" => "MRN-00042",
          "dateOfBirth" => "1980-04-01",
          "phone" => "+1-555-0100",
          "email" => "jane@example.org"
        })
      )

      assert {:ok, patient} = Patients.resolve_from_core(@core_id)

      fields = Patient.__schema__(:fields)
      refute :mrn in fields
      refute :date_of_birth in fields
      refute :phone in fields
      refute :email in fields
      refute patient |> Map.from_struct() |> Map.values() |> Enum.member?("MRN-00042")
    end
  end

  describe "resolve_from_core/1 name composition" do
    test "joins given and family names" do
      assert_name(%{"firstName" => "Jane", "lastName" => "Doe"}, "Jane Doe")
    end

    test "a missing surname leaves no trailing space" do
      assert_name(%{"firstName" => "Jane", "lastName" => nil}, "Jane")
    end

    test "a missing given name leaves no leading space" do
      assert_name(%{"firstName" => nil, "lastName" => "Doe"}, "Doe")
    end

    test "empty strings are treated as missing, not joined" do
      assert_name(%{"firstName" => "", "lastName" => "Doe"}, "Doe")
    end

    test "no name at all falls back to the core id, never the string \"nil\"" do
      # Honest rather than invented: a placeholder name would read as real, and
      # refusing outright would block a patient at the desk over a registry gap.
      assert_name(%{"firstName" => nil, "lastName" => nil}, @core_id)
    end

    defp assert_name(overrides, expected) do
      bypass = Bypass.open()

      Application.put_env(
        :scheduling,
        Scheduling.Core,
        Application.get_env(:scheduling, Scheduling.Core)
        |> Keyword.put(:base_url, "http://localhost:#{bypass.port}")
      )

      stub_patient(bypass, core_patient(overrides))

      assert {:ok, patient} = Patients.resolve_from_core(@core_id)
      assert patient.name == expected
    end
  end

  describe "resolve_from_core/1 failure modes are distinguishable" do
    test "a patient ac-core does not have is :not_found", %{bypass: bypass} do
      stub_patient(bypass, %{"error" => "not_found"}, 404)

      assert {:error, :not_found} = Patients.resolve_from_core(@core_id)
    end

    test "an unreachable registry is :core_unavailable, not :not_found", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:core_unavailable, _reason}} = Patients.resolve_from_core(@core_id)
    end

    test "a registry error is :core_unavailable", %{bypass: bypass} do
      stub_patient(bypass, %{"error" => "boom"}, 500)

      assert {:error, {:core_unavailable, {:http_status, 500, _}}} =
               Patients.resolve_from_core(@core_id)
    end

    test "neither failure creates a half-formed row", %{bypass: bypass} do
      stub_patient(bypass, %{"error" => "not_found"}, 404)

      assert {:error, :not_found} = Patients.resolve_from_core(@core_id)
      assert Patients.get_by_core_patient_id(@core_id) == nil
    end
  end

  describe "refresh_from_core/1" do
    test "updates a stale cached name", %{bypass: bypass} do
      stub_patient(bypass, core_patient(%{"lastName" => "Married"}))

      {:ok, patient} =
        Patients.create_patient(%{"name" => "Jane Doe", "core_patient_id" => @core_id})

      assert {:ok, refreshed} = Patients.refresh_from_core(patient)
      assert refreshed.name == "Jane Married"
      assert refreshed.id == patient.id
    end

    test "leaves an unchanged name alone", %{bypass: bypass} do
      stub_patient(bypass, core_patient())

      {:ok, patient} =
        Patients.create_patient(%{"name" => "Jane Doe", "core_patient_id" => @core_id})

      assert {:ok, refreshed} = Patients.refresh_from_core(patient)
      assert refreshed.name == "Jane Doe"
      assert refreshed.updated_at == patient.updated_at
    end

    test "a patient with no core id has nothing to refresh from" do
      {:ok, patient} = Patients.create_patient(%{"name" => "Walk In"})

      assert {:error, :not_found} = Patients.refresh_from_core(patient)
    end

    test "surfaces an unavailable registry rather than clearing the name", %{bypass: bypass} do
      {:ok, patient} =
        Patients.create_patient(%{"name" => "Jane Doe", "core_patient_id" => @core_id})

      Bypass.down(bypass)

      assert {:error, {:core_unavailable, _}} = Patients.refresh_from_core(patient)
      assert Repo.get(Patient, patient.id).name == "Jane Doe"
    end
  end

  describe "the unique index" do
    test "rejects a second row projecting the same core patient" do
      {:ok, _} = Patients.create_patient(%{"name" => "Jane Doe", "core_patient_id" => @core_id})

      assert {:error, changeset} =
               Patients.create_patient(%{"name" => "Impostor", "core_patient_id" => @core_id})

      assert "has already been taken" in errors_on(changeset).core_patient_id
    end

    test "allows many rows without one" do
      assert {:ok, _} = Patients.create_patient(%{"name" => "Walk In A"})
      assert {:ok, _} = Patients.create_patient(%{"name" => "Walk In B"})
    end
  end

  describe "the core_patient_id filter" do
    test "returns the matching row" do
      {:ok, wanted} =
        Patients.create_patient(%{"name" => "Jane Doe", "core_patient_id" => @core_id})

      {:ok, _other} = Patients.create_patient(%{"name" => "Someone Else"})

      assert [found] = Patients.list_patients(%{core_patient_id: @core_id})
      assert found.id == wanted.id
    end

    test "composes with the other id filters via AND" do
      {:ok, wanted} =
        Patients.create_patient(%{
          "name" => "Jane Doe",
          "core_patient_id" => @core_id,
          "external_id" => "checkin-7a3f"
        })

      assert [found] =
               Patients.list_patients(%{
                 core_patient_id: @core_id,
                 external_id: "checkin-7a3f"
               })

      assert found.id == wanted.id

      # A mismatched pair matches nothing, rather than either half winning.
      assert Patients.list_patients(%{
               core_patient_id: @core_id,
               external_id: "checkin-nope"
             }) == []
    end

    test "an unknown id matches nothing" do
      assert Patients.list_patients(%{core_patient_id: Ecto.UUID.generate()}) == []
    end
  end
end
