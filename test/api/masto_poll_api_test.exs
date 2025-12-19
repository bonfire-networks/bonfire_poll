# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Poll.Web.MastoPollApiTest do
    @moduledoc """
    Tests for Mastodon-compatible Polls API endpoints.

    Run with: just test extensions/bonfire_poll/test/api/masto_poll_api_test.exs
    """

    use Bonfire.Poll.ConnCase, async: false

    alias Bonfire.Me.Fake
    import Bonfire.Poll.Fake

    @moduletag :masto_api

    setup do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:current_user_id, user.id)
        |> Plug.Conn.put_session(:current_account_id, account.id)
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")

      {:ok, conn: conn, user: user, account: account}
    end

    defp unauthenticated_conn do
      Phoenix.ConnTest.build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
    end

    defp create_test_poll(user) do
      fake_question_with_choices(
        %{voting_dates: [DateTime.utc_now()]},
        [%{name: "Red"}, %{name: "Blue"}, %{name: "Green"}],
        current_user: user
      )
    end

    defp create_expired_poll(user) do
      past_end = DateTime.add(DateTime.utc_now(), -3600, :second)

      fake_question_with_choices(
        %{voting_dates: [nil, past_end]},
        [%{name: "Option A"}, %{name: "Option B"}],
        current_user: user
      )
    end

    defp create_multiple_choice_poll(user) do
      fake_question_with_choices(
        %{voting_format: "multiple", voting_dates: [DateTime.utc_now()]},
        [%{name: "Pizza"}, %{name: "Pasta"}, %{name: "Salad"}],
        current_user: user
      )
    end

    describe "GET /api/v1/polls/:id" do
      test "returns poll with Mastodon-compatible format", %{conn: conn, user: user} do
        {:ok, poll} = create_test_poll(user)

        response =
          conn
          |> get("/api/v1/polls/#{poll.id}")
          |> json_response(200)

        assert response["id"] == to_string(poll.id)
        assert is_list(response["options"])
        assert length(response["options"]) >= 2

        # Check option structure
        first_option = hd(response["options"])
        assert Map.has_key?(first_option, "title")
        assert Map.has_key?(first_option, "votes_count")

        # Check poll metadata
        assert Map.has_key?(response, "expired")
        assert Map.has_key?(response, "multiple")
        assert Map.has_key?(response, "votes_count")
        assert Map.has_key?(response, "voted")
        assert Map.has_key?(response, "own_votes")
        assert Map.has_key?(response, "emojis")
      end

      test "returns correct expired status for active poll", %{conn: conn, user: user} do
        {:ok, poll} = create_test_poll(user)

        response =
          conn
          |> get("/api/v1/polls/#{poll.id}")
          |> json_response(200)

        assert response["expired"] == false
      end

      test "returns correct expired status for expired poll", %{conn: conn, user: user} do
        {:ok, poll} = create_expired_poll(user)

        response =
          conn
          |> get("/api/v1/polls/#{poll.id}")
          |> json_response(200)

        assert response["expired"] == true
      end

      test "returns correct multiple flag for single-choice poll", %{conn: conn, user: user} do
        {:ok, poll} = create_test_poll(user)

        response =
          conn
          |> get("/api/v1/polls/#{poll.id}")
          |> json_response(200)

        assert response["multiple"] == false
      end

      test "returns correct multiple flag for multiple-choice poll", %{conn: conn, user: user} do
        {:ok, poll} = create_multiple_choice_poll(user)

        response =
          conn
          |> get("/api/v1/polls/#{poll.id}")
          |> json_response(200)

        assert response["multiple"] == true
      end

      test "returns 404 for non-existent poll", %{conn: conn} do
        response =
          conn
          |> get("/api/v1/polls/nonexistent_#{System.unique_integer([:positive])}")
          |> json_response(404)

        assert response["error"] == "Not found"
      end

      test "shows voted=false before voting", %{conn: conn, user: user} do
        {:ok, poll} = create_test_poll(user)

        response =
          conn
          |> get("/api/v1/polls/#{poll.id}")
          |> json_response(200)

        assert response["voted"] == false
        assert response["own_votes"] == []
      end
    end

    describe "POST /api/v1/polls/:id/votes" do
      test "records vote and returns updated poll", %{conn: conn, user: user} do
        {:ok, poll} = create_test_poll(user)

        response =
          conn
          |> post("/api/v1/polls/#{poll.id}/votes", %{"choices" => [0]})
          |> json_response(200)

        assert response["id"] == to_string(poll.id)
        assert response["voted"] == true
        assert 0 in response["own_votes"]
      end

      test "supports multiple choice voting", %{conn: conn, user: user} do
        {:ok, poll} = create_multiple_choice_poll(user)

        response =
          conn
          |> post("/api/v1/polls/#{poll.id}/votes", %{"choices" => [0, 2]})
          |> json_response(200)

        assert response["voted"] == true
        assert 0 in response["own_votes"]
        assert 2 in response["own_votes"]
      end

      test "accepts string indices", %{conn: conn, user: user} do
        {:ok, poll} = create_test_poll(user)

        response =
          conn
          |> post("/api/v1/polls/#{poll.id}/votes", %{"choices" => ["1"]})
          |> json_response(200)

        assert response["voted"] == true
        assert 1 in response["own_votes"]
      end

      test "returns 422 for expired poll", %{conn: conn, user: user} do
        {:ok, poll} = create_expired_poll(user)

        response =
          conn
          |> post("/api/v1/polls/#{poll.id}/votes", %{"choices" => [0]})
          |> json_response(422)

        assert response["error"] =~ "ended"
      end

      test "returns 400 when no choices provided", %{conn: conn, user: user} do
        {:ok, poll} = create_test_poll(user)

        response =
          conn
          |> post("/api/v1/polls/#{poll.id}/votes", %{})
          |> json_response(400)

        assert response["error"] =~ "required"
      end

      test "returns 400 for invalid choice index", %{conn: conn, user: user} do
        {:ok, poll} = create_test_poll(user)

        response =
          conn
          |> post("/api/v1/polls/#{poll.id}/votes", %{"choices" => [99]})
          |> json_response(400)

        assert response["error"] =~ "Invalid"
      end

      test "returns 404 for non-existent poll", %{conn: conn} do
        response =
          conn
          |> post("/api/v1/polls/nonexistent_#{System.unique_integer([:positive])}/votes", %{
            "choices" => [0]
          })
          |> json_response(404)

        assert response["error"] == "Not found"
      end

      test "requires authentication", _context do
        response =
          unauthenticated_conn()
          |> post("/api/v1/polls/any/votes", %{"choices" => [0]})
          |> json_response(401)

        assert response["error"] == "Unauthorized"
      end
    end
  end
end
