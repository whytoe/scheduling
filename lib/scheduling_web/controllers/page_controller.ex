defmodule SchedulingWeb.PageController do
  use SchedulingWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/board")
  end
end
