defmodule Scheduling.Core.Client do
  @moduledoc """
  Thin HTTP client wrapping the Avenue D Core API (ac-core), the platform's
  system of record for patients, practices and locations.
  `docs/ac-core-swagger.json` describes it.

  Uses the **`/v1/*` endpoints only**. ac-core also exposes an unversioned and
  an `/admin/*` surface, but those are for first-party UIs authenticating with
  a staff session cookie; `/v1` is the integrator surface and the one our
  client-credentials token is scoped for.

  Configuration lives under `config :scheduling, Scheduling.Core` — see that
  module. Bearer tokens come from `Scheduling.Auth.ServiceToken`.

  ## Every response is projected through an allowlist

  This is a data-boundary control, not tidiness. Every object in the ac-core
  spec is declared `additionalProperties: true`, so the live API may return
  fields the spec does not document, and may start returning more at any time
  without a spec change. A patient record already carries `mrn`,
  `dateOfBirth`, `phone` and `email`.

  Scheduling carries PII but not health data, and only the PII it actually
  needs (`docs/data-boundary.md`). So each response is **projected field by
  field into a map we construct**, and the original is discarded here at the
  boundary. Nothing downstream ever sees the raw response, which means a new
  field appearing upstream cannot silently propagate into our database, our
  audit log, or an outbound webhook.

  Concretely, from a patient we keep `id`, `practiceId`, `firstName` and
  `lastName` — enough to correlate the record and call the right person — and
  drop everything else, including the identifiers we could store but have no
  use for.

  Keys are returned as snake_case atoms. That is idiomatic, and it also means
  a projection cannot be produced by merging a decoded response: the keys have
  to be written out.

  ## Error reasons describe a body, they never carry one

  The projection above is only half the boundary. A failed request used to put
  ac-core's response body straight into its error reason, and the body of a
  failing `/v1/patients` call is a patient record — `firstName`, `lastName`,
  and whatever else ac-core has started returning, since the spec declares
  every object `additionalProperties: true`. So the reason re-admitted exactly
  what the projection exists to keep out, on the one path where nobody was
  looking at it.

  That is **not** currently a boundary breach. Every sink for these reasons is
  a log or an operator's terminal — `Locations.sync_from_core/1` and
  `Practices.sync_from_core/1` log `inspect(reason)`, `Scheduling.Release`
  prints it — and `docs/data-boundary.md` allows patient names in logs. The
  problem is that the client offers a hazard the next caller inherits: nothing
  about `{:error, {:http_status, 500, body}}` says "do not write this down",
  and the caller that writes it into an append-only row will not be the one
  that reads this moduledoc. `sc-87w` is what that looks like when it happens.

  So `shape/1` returns the type and size of a body and nothing else. Shape is
  what a diagnosis needs — "ac-core answered 500 with a map" is the useful
  fact and the whole useful fact. Keys are deliberately excluded as well,
  because an envelope keyed by identifier would make them data.

  The `{:http_status, status, shape}` arity is kept rather than shortened to a
  pair: `Scheduling.Patients.classify/1` matches the three-element form to tell
  a 404 from anything else, `get_patient/1` documents it, and a shape in that
  slot costs nothing while carrying nothing.

  ## Pagination

  The list functions return the page envelope as
  `%{data: [...], page: n, page_size: n, total: n}` and do **not** follow pages
  themselves. Callers decide how much to pull — a sync job wants every page, a
  lookup wants the first. Pass `:page` and `:page_size` to walk them.
  """

  alias Scheduling.Auth.ServiceToken
  alias Scheduling.Core

  @typedoc "A patient, reduced to the fields scheduling is allowed to hold."
  @type patient :: %{
          id: String.t(),
          practice_id: String.t() | nil,
          first_name: String.t() | nil,
          last_name: String.t() | nil
        }

  @typedoc "A physical site. Scheduling offices belong to one of these."
  @type location :: %{
          id: String.t(),
          practice_id: String.t() | nil,
          name: String.t() | nil,
          address: String.t() | nil,
          timezone: String.t() | nil,
          active: boolean() | nil
        }

  @typedoc "A practice — ac-core's data-scoping unit, holding many locations."
  @type practice :: %{
          id: String.t(),
          name: String.t() | nil,
          slug: String.t() | nil,
          organization_id: String.t() | nil
        }

  @typedoc "A page of results. `data` is already projected."
  @type page(item) :: %{data: [item], page: integer(), page_size: integer(), total: integer()}

  @doc """
  `GET /v1/patients/{id}`. Requires the `core:patients:read` scope.

  Returns `{:error, {:http_status, 404, _}}` when ac-core does not have the
  patient, or when it belongs to a practice this token cannot see — ac-core
  scopes reads to the caller's practices, so "not visible" and "not there"
  are deliberately indistinguishable to us.
  """
  @spec get_patient(String.t()) :: {:ok, patient()} | {:error, term()}
  def get_patient(id) when is_binary(id) do
    case request(:get, "/v1/patients/" <> encode_segment(id), []) do
      {:ok, body} -> {:ok, project_patient(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `GET /v1/patients`. Free-text search across the caller's practices.

  Opts: `:q`, `:page`, `:page_size`.
  """
  @spec search_patients(String.t() | nil, keyword()) ::
          {:ok, page(patient())} | {:error, term()}
  def search_patients(query \\ nil, opts \\ []) do
    params = paging_params(opts) ++ if(is_binary(query) and query != "", do: [q: query], else: [])

    case request(:get, "/v1/patients", params) do
      {:ok, body} -> {:ok, project_page(body, &project_patient/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `GET /v1/locations`. Requires the `core:organizations:read` scope.

  Opts: `:practice_id` (ac-core's `practiceId` filter), `:page`, `:page_size`.
  Without a filter, ac-core returns every location the token's practices cover.
  """
  @spec list_locations(keyword()) :: {:ok, page(location())} | {:error, term()}
  def list_locations(opts \\ []) do
    params =
      paging_params(opts) ++
        case Keyword.get(opts, :practice_id) do
          id when is_binary(id) and id != "" -> [practiceId: id]
          _ -> []
        end

    case request(:get, "/v1/locations", params) do
      {:ok, body} -> {:ok, project_page(body, &project_location/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `GET /v1/practices`. Requires the `core:organizations:read` scope.

  Opts: `:page`, `:page_size`.
  """
  @spec list_practices(keyword()) :: {:ok, page(practice())} | {:error, term()}
  def list_practices(opts \\ []) do
    case request(:get, "/v1/practices", paging_params(opts)) do
      {:ok, body} -> {:ok, project_page(body, &project_practice/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- projection (the allowlist; see the moduledoc) ---

  defp project_patient(raw) when is_map(raw) do
    %{
      id: get(raw, "id"),
      practice_id: get(raw, "practiceId"),
      first_name: get(raw, "firstName"),
      last_name: get(raw, "lastName")
    }
  end

  defp project_location(raw) when is_map(raw) do
    %{
      id: get(raw, "id"),
      practice_id: get(raw, "practiceId"),
      name: get(raw, "name"),
      address: get(raw, "address"),
      timezone: get(raw, "timezone"),
      active: get(raw, "active")
    }
  end

  defp project_practice(raw) when is_map(raw) do
    %{
      id: get(raw, "id"),
      name: get(raw, "name"),
      slug: get(raw, "slug"),
      organization_id: get(raw, "organizationId")
    }
  end

  defp project_page(body, projector) when is_map(body) do
    %{
      data: body |> Map.get("data", []) |> List.wrap() |> Enum.map(projector),
      page: get(body, "page"),
      page_size: get(body, "pageSize"),
      total: get(body, "total")
    }
  end

  # JSON null decodes to nil already; this exists so a projection reads the
  # same way for every field and cannot accidentally become a Map.take/2.
  defp get(map, key), do: Map.get(map, key)

  # --- transport ---

  defp paging_params(opts) do
    []
    |> put_param(:page, Keyword.get(opts, :page))
    |> put_param(:pageSize, Keyword.get(opts, :page_size))
  end

  # ac-core declares page/pageSize as strings; accept integers and stringify so
  # callers write the natural thing.
  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value) when is_integer(value), do: params ++ [{key, value}]
  defp put_param(params, key, value) when is_binary(value), do: params ++ [{key, value}]
  defp put_param(params, _key, _value), do: params

  defp request(method, path, params) do
    with {:ok, base_url} <- base_url(),
         {:ok, token} <- ServiceToken.fetch() do
      Req.new(
        method: method,
        url: base_url <> path,
        params: params,
        headers: [{"authorization", "Bearer " <> token}, {"accept", "application/json"}],
        receive_timeout: Core.http_timeout_ms()
      )
      |> Req.request()
      |> handle_response()
    end
  end

  # `URI.encode/1` keeps reserved characters, so it leaves `/` alone — which
  # would let an id containing one escape its path segment. Ids are opaque to
  # us, so encode everything outside the unreserved set.
  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp base_url do
    case Core.base_url() do
      url when is_binary(url) and url != "" -> {:ok, String.trim_trailing(url, "/")}
      _ -> {:error, :not_configured}
    end
  end

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    if is_map(body), do: {:ok, body}, else: {:error, {:unexpected_body, shape(body)}}
  end

  defp handle_response({:ok, %{status: 401, body: body}}) do
    # Our token was rejected. Drop it so the next call re-fetches rather than
    # replaying a credential ac-core has stopped honouring.
    ServiceToken.invalidate()
    {:error, {:http_status, 401, shape(body)}}
  end

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_status, status, shape(body)}}

  defp handle_response({:error, exception}), do: {:error, exception}

  # Describes a body without carrying any of it. See the moduledoc.
  #
  # Unlike `Scheduling.Compliance.Client.shape/1`, which this mirrors, there is
  # a list clause. That client reads its rows through `rows/1`, so a bare list
  # never reaches its shape function; here a top-level array is a body ac-core
  # could plausibly answer with, and `{:list, 25}` is the fact worth having.
  defp shape(body) when is_map(body), do: {:map, map_size(body)}
  defp shape(body) when is_list(body), do: {:list, length(body)}
  defp shape(body) when is_binary(body), do: {:string, byte_size(body)}
  defp shape(nil), do: :nil_body
  defp shape(_other), do: :unrecognised
end
