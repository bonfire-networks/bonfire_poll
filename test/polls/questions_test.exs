defmodule Bonfire.Poll.QuestionsTest do
  use Bonfire.Poll.DataCase, async: true
  import Bonfire.Me.Fake
  import Bonfire.Poll.Fake

  describe "question creation and querying" do
    test "creates a question with defaults" do
      {:ok, question} = fake_question()
      assert question.id
      assert question.post_content[:name]
    end

    test "creates a question with choices" do
      choices = [%{name: "Yes"}, %{name: "No"}]
      {:ok, question} = fake_question_with_choices(%{}, choices)
      assert length(question.choices) == 2
    end

    test "fetches a question by id" do
      user = Bonfire.Me.Fake.fake_user!()
      {:ok, question} = fake_question(%{}, current_user: user)
      {:ok, fetched} = Bonfire.Poll.Questions.read(question.id, current_user: user)
      assert fetched.id == question.id
    end

    test "lists questions paginated" do
      user = Bonfire.Me.Fake.fake_user!()
      {:ok, _} = fake_question(%{post_content: %{name: "Q1"}}, current_user: user)
      {:ok, _} = fake_question(%{post_content: %{name: "Q2"}}, current_user: user)
      results = Bonfire.Poll.Questions.list_paginated([], current_user: user)
      assert Enum.count(results) >= 2
    end
  end

  test "voting_open?/1 and voting_ended?/1" do
    now = DateTime.utc_now()
    past = DateTime.add(now, -3600, :second)
    future = DateTime.add(now, 3600, :second)
    {:ok, question} = fake_question(%{voting_dates: [past, future]})
    assert Bonfire.Poll.Questions.voting_open?(question)
    refute Bonfire.Poll.Questions.voting_ended?(question)

    {:ok, ended_question} = fake_question(%{voting_dates: [past, past]})
    refute Bonfire.Poll.Questions.voting_open?(ended_question)
    assert Bonfire.Poll.Questions.voting_ended?(ended_question)
  end

  test "proposal_open?/1 and proposal_ended?/1" do
    now = DateTime.utc_now()
    past = DateTime.add(now, -3600, :second)
    future = DateTime.add(now, 3600, :second)
    {:ok, question} = fake_question(%{proposal_dates: [past, future]})
    assert Bonfire.Poll.Questions.proposal_open?(question)
    refute Bonfire.Poll.Questions.proposal_ended?(question)

    {:ok, ended_question} = fake_question(%{proposal_dates: [past, past]})
    refute Bonfire.Poll.Questions.proposal_open?(ended_question)
    assert Bonfire.Poll.Questions.proposal_ended?(ended_question)
  end
end
