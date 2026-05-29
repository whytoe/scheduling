defmodule SchedulingWeb.PageController do
  use SchedulingWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
