defmodule SchedulingWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests
  that no controller handled (e.g. an unmatched route or an unexpected 500).

  These responses go through the same unified error envelope as the rest of
  the API (see `SchedulingWeb.ErrorEnvelope`): the status message becomes the
  human-readable `message` and a snake_cased form of it becomes the `code`.

  See config/config.exs.
  """

  alias SchedulingWeb.ErrorEnvelope

  # By default, Phoenix returns the status message from the template name.
  # For example, "404.json" becomes "Not Found".
  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)
    ErrorEnvelope.error_envelope(code_from_message(message), message)
  end

  defp code_from_message(message) do
    message
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
