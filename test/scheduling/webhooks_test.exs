defmodule Scheduling.WebhooksTest do
  use Scheduling.DataCase, async: false

  alias Scheduling.Webhooks

  describe "CRUD" do
    test "create_subscription auto-generates a secret when not supplied" do
      {:ok, sub} = Webhooks.create_subscription(%{url: "https://example.test/hook"})
      assert is_binary(sub.secret)
      assert byte_size(sub.secret) >= 16
      assert sub.event_types == []
      assert sub.active == true
    end

    test "rejects a non-http URL" do
      {:error, changeset} = Webhooks.create_subscription(%{url: "ftp://example.test"})
      assert "must be a valid http(s) URL" in errors_on(changeset).url
    end

    test "rejects a missing URL" do
      {:error, changeset} = Webhooks.create_subscription(%{})
      assert "can't be blank" in errors_on(changeset).url
    end

    test "rejects a too-short caller-supplied secret" do
      {:error, changeset} =
        Webhooks.create_subscription(%{url: "https://example.test/h", secret: "tooshort"})

      assert "should be at least 16 character(s)" in errors_on(changeset).secret
    end

    test "list_matching/1 returns subscriptions whose event_types include the type" do
      {:ok, a} =
        Webhooks.create_subscription(%{
          url: "https://example.test/a",
          event_types: ["visit.created", "visit.ended"]
        })

      {:ok, _b} =
        Webhooks.create_subscription(%{
          url: "https://example.test/b",
          event_types: ["queue_entry.completed"]
        })

      {:ok, c_all} =
        Webhooks.create_subscription(%{url: "https://example.test/c"})

      ids = Webhooks.list_matching("visit.created") |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([a.id, c_all.id])
    end

    test "inactive subscriptions are not matched" do
      {:ok, sub} =
        Webhooks.create_subscription(%{
          url: "https://example.test/inactive",
          event_types: ["visit.created"],
          active: false
        })

      assert sub.id not in (Webhooks.list_matching("visit.created") |> Enum.map(& &1.id))
    end
  end

  describe "sign/3 and verify_signature/5" do
    test "sign produces stable lowercase hex HMAC-SHA256 of '<ts>.<body>'" do
      secret = "this-is-a-test-secret-1234567890"
      timestamp = 1_700_000_000
      body = ~s({"type":"visit.created"})

      sig = Webhooks.sign(secret, timestamp, body)

      assert byte_size(sig) == 64
      assert sig == String.downcase(sig)
      assert sig == Webhooks.sign(secret, timestamp, body)
    end

    test "verify_signature accepts a valid signature within the freshness window" do
      secret = "verify-secret-1234567890abcdef"
      ts = DateTime.utc_now() |> DateTime.to_unix()
      body = ~s({"hello":"world"})
      sig = "t=#{ts},v1=#{Webhooks.sign(secret, ts, body)}"

      assert :ok = Webhooks.verify_signature(sig, Integer.to_string(ts), body, secret)
    end

    test "rejects a signature where the body has been tampered with" do
      secret = "tamper-secret-1234567890abcdef"
      ts = DateTime.utc_now() |> DateTime.to_unix()
      good_body = ~s({"hello":"world"})
      bad_body = ~s({"hello":"evil"})
      sig = "t=#{ts},v1=#{Webhooks.sign(secret, ts, good_body)}"

      assert {:error, :bad_signature} =
               Webhooks.verify_signature(sig, Integer.to_string(ts), bad_body, secret)
    end

    test "rejects a stale timestamp" do
      secret = "stale-secret-1234567890abcdef"
      old_ts = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(3_600)
      body = ~s({"x":1})
      sig = "t=#{old_ts},v1=#{Webhooks.sign(secret, old_ts, body)}"

      assert {:error, :stale_timestamp} =
               Webhooks.verify_signature(sig, Integer.to_string(old_ts), body, secret, 60)
    end

    test "rejects an absent v1 part" do
      secret = "secret-1234567890abcdef"
      ts = DateTime.utc_now() |> DateTime.to_unix()
      body = ~s({"x":1})

      assert {:error, :no_signature} =
               Webhooks.verify_signature("t=#{ts}", Integer.to_string(ts), body, secret)
    end
  end
end
