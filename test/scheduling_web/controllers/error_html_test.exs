defmodule SchedulingWeb.ErrorHTMLTest do
  use SchedulingWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    html = render_to_string(SchedulingWeb.ErrorHTML, "404", "html", [])
    assert html =~ "Error 404"
    assert html =~ "Page not found"
    assert html =~ "Back to board"
  end

  test "renders 500.html" do
    html = render_to_string(SchedulingWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Error 500"
    assert html =~ "Something went wrong"
    assert html =~ "your data is safe"
    assert html =~ "Back to board"
  end
end
