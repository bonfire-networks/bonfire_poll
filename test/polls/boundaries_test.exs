defmodule Bonfire.Poll.BoundariesTest do
  @moduledoc """
  Pins boundary enforcement on poll Questions. Two surfaces:

  1. Standard verbs (`:read`, `:see`, `:like`, `:boost`, `:reply`) — checked
     via `Bonfire.Boundaries.can?/3` against the Question itself, exactly
     like any other activity object.
  2. Poll-specific `:vote` verb — the registry has it, and
     `Bonfire.Poll.Votes.vote/3` enforces it via `Questions.read(id,
     verbs: [:vote])` when the question is passed as a binary id (the
     path the LiveHandler uses).
  """

  use Bonfire.Poll.DataCase, async: true

  import Bonfire.Me.Fake
  import Bonfire.Poll.Fake

  alias Bonfire.Boundaries
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Poll.Questions
  alias Bonfire.Poll.Votes

  describe ":vote verb registry" do
    test ":vote is a registered verb" do
      assert %{} = verb = Verbs.get(:vote)
      assert verb[:id] == "7V0TEMEANSC0NSENT0RREFVSA1"
      assert verb[:verb] == "Vote"
    end

    test ":vote slug is among Verbs.slugs/0" do
      assert :vote in Verbs.slugs()
    end
  end

  describe "standard verbs on a public poll" do
    test "creator has all relevant verbs on their own poll" do
      author = fake_user!()
      {:ok, poll} = fake_question(%{}, current_user: author, boundary: "public")

      for verb <- [:read, :see, :like, :boost, :reply, :vote] do
        assert Boundaries.can?(author, verb, poll),
               "creator should be able to #{verb} their own poll"
      end
    end

    test "other users can read/see/like/boost/reply a public poll" do
      author = fake_user!()
      other = fake_user!()
      {:ok, poll} = fake_question(%{}, current_user: author, boundary: "public")

      for verb <- [:read, :see, :like, :boost, :reply] do
        assert Boundaries.can?(other, verb, poll),
               "any user should be able to #{verb} a public poll"
      end
    end

    test "other users can :vote on a public poll" do
      author = fake_user!()
      other = fake_user!()
      {:ok, poll} = fake_question(%{}, current_user: author, boundary: "public")
      assert Boundaries.can?(other, :vote, poll)
    end
  end

  describe "mentions boundary restricts non-mentioned users" do
    test "an unmentioned user cannot :read or :see a mentions-only poll" do
      author = fake_user!()
      outsider = fake_user!()

      {:ok, poll} =
        fake_question(
          %{post_content: %{html_body: "secret huddle"}},
          current_user: author,
          boundary: "mentions"
        )

      refute Boundaries.can?(outsider, :read, poll),
             "outsider should not :read a mentions-only poll"

      refute Boundaries.can?(outsider, :see, poll),
             "outsider should not :see a mentions-only poll"
    end

    test "Questions.read/2 returns {:error, _} when the user lacks :read" do
      author = fake_user!()
      outsider = fake_user!()

      {:ok, poll} =
        fake_question(%{}, current_user: author, boundary: "mentions")

      assert {:error, _} = Questions.read(poll.id, current_user: outsider)
    end
  end

  describe ":vote verb is enforced by Votes.vote/3 on the id path" do
    test "creator can vote on their own poll (creator has :vote)" do
      author = fake_user!()

      {:ok, poll} =
        fake_question_with_choices(
          %{},
          [%{name: "yes"}, %{name: "no"}],
          current_user: author,
          boundary: "public"
        )

      [choice | _] = poll.choices

      assert {:ok, _} =
               Votes.vote(author, poll.id, [%{choice_id: choice.id, weight: 1}])
    end

    test "a non-creator can vote on a public poll via the id path" do
      author = fake_user!()
      voter = fake_user!()

      {:ok, poll} =
        fake_question_with_choices(
          %{},
          [%{name: "yes"}, %{name: "no"}],
          current_user: author,
          boundary: "public"
        )

      [choice | _] = poll.choices

      assert {:ok, _} =
               Votes.vote(voter, poll.id, [%{choice_id: choice.id, weight: 1}])
    end

    test "a user without :vote on the poll is refused by the id path" do
      # The `mentions` preset doesn't grant `:vote` (or `:read`) to outsiders,
      # so the read+verb gate inside `Votes.vote/4` short-circuits.
      author = fake_user!()
      outsider = fake_user!()

      {:ok, poll} =
        fake_question_with_choices(
          %{},
          [%{name: "yes"}, %{name: "no"}],
          current_user: author,
          boundary: "mentions"
        )

      [choice | _] = poll.choices

      result = Votes.vote(outsider, poll.id, [%{choice_id: choice.id, weight: 1}])
      assert match?({:error, _}, result) or is_nil(result) or result == :error,
             "expected an error result, got: #{inspect(result)}"
    end
  end

  describe "scoped audience: grant :vote to a specific circle only" do
    # End-to-end pin of the UI workflow: an author creates a poll, grants the
    # `:interact` role (which includes `:vote`) to a circle of insiders, and
    # outsiders are blocked from voting. This is exactly the "set boundary
    # in Advanced Permissions → only one circle can vote" scenario.

    test "circle members can :vote, outsiders cannot" do
      account = Bonfire.Me.Fake.fake_account!()
      author = Bonfire.Me.Fake.fake_user!(account)
      insider = Bonfire.Me.Fake.fake_user!(account)
      outsider = Bonfire.Me.Fake.fake_user!(account)

      {:ok, voters_circle} =
        Bonfire.Boundaries.Circles.create(author, %{named: %{name: "voters"}})

      {:ok, _} = Bonfire.Boundaries.Circles.add_to_circles(insider, voters_circle)

      {:ok, poll} =
        fake_question_with_choices(
          %{},
          [%{name: "yes"}, %{name: "no"}],
          current_user: author,
          boundary: "private",
          to_circles: [{voters_circle.id, :interact}]
        )

      [choice | _] = poll.choices

      # Insider has :vote (via the `:interact` role on their circle).
      assert Boundaries.can?(insider, :vote, poll)

      assert {:ok, _} =
               Votes.vote(insider, poll.id, [%{choice_id: choice.id, weight: 1}])

      # Outsider has no grant on this poll.
      refute Boundaries.can?(outsider, :vote, poll)

      result = Votes.vote(outsider, poll.id, [%{choice_id: choice.id, weight: 1}])
      assert match?({:error, _}, result) or is_nil(result) or result == :error,
             "outsider should be refused, got: #{inspect(result)}"
    end
  end
end
