defmodule Bonfire.Poll.ChoicesTest do
  use Bonfire.Poll.DataCase, async: true
  use Bonfire.Common.Repo
  import Bonfire.Me.Fake
  import Bonfire.Poll.Fake

  describe "choice creation, linking, and querying" do
    test "creates choices and links to question" do
      choices = [%{name: "Option 1"}, %{name: "Option 2"}]
      {:ok, question} = fake_question_with_choices(%{}, choices)
      assert Enum.all?(question.choices, & &1.id)
      assert Enum.map(question.choices, & &1.post_content.name) == ["Option 1", "Option 2"]
    end

    test "adds choices to an existing question" do
      user = Bonfire.Me.Fake.fake_user!()
      {:ok, question} = fake_question(%{post_content: %{name: "Q"}}, current_user: user)
      {:ok, choice_id1} = fake_choice(question, %{name: "Extra 1"})
      {:ok, choice_id2} = fake_choice(question, %{name: "Extra 2"})
      # Reload question to get updated choices
      {:ok, reloaded} = Bonfire.Poll.Questions.read(question.id, current_user: user)
      names = Enum.map(reloaded.choices, & &1.post_content.name)
      assert "Extra 1" in names
      # FIXME
      assert "Extra 2" in names
    end

    test "lists choices for a question" do
      choices = [%{name: "A"}, %{name: "B"}]
      {:ok, question} = fake_question_with_choices(%{}, choices)
      assert length(question.choices) == 2
    end

    test "removes a choice from a question" do
      user = Bonfire.Me.Fake.fake_user!()
      choices = [%{name: "ToRemove"}, %{name: "ToKeep"}]
      {:ok, question} = fake_question_with_choices(%{}, choices, current_user: user)
      choice_to_remove = Enum.find(question.choices, &(&1.post_content.name == "ToRemove"))
      Bonfire.Poll.Choices.remove_choice(choice_to_remove.id, question.id)
      {:ok, reloaded} = Bonfire.Poll.Questions.read(question.id, current_user: user)
      names = Enum.map(reloaded.choices, & &1.post_content.name)
      refute "ToRemove" in names
      assert "ToKeep" in names
    end
  end

  describe "Bonfire.Poll.Choices.simple_create_and_put/4" do
    test "creates and associates choices with a question" do
      user = Bonfire.Me.Fake.fake_user!()

      question =
        Bonfire.Poll.Questions.create(
          current_user: user,
          question_attrs: %{post_content: %{html_body: "Test question"}}
        )
        |> elem(1)

      choices_attrs = [
        %{name: "Option 1"},
        %{name: "Option 2"},
        %{name: "Option 3"}
      ]

      assert result =
               Bonfire.Poll.Choices.simple_create_and_put(nil, choices_attrs, question,
                 current_user: user
               )

      assert is_list(result)
      assert length(result) == 3
      # Check that each choice is associated with the question
      for {:ok, choice_id} <- result do
        assoc =
          Bonfire.Data.Assort.Ranked |> repo().get_by(item_id: choice_id, scope_id: question.id)

        assert assoc
      end
    end
  end

  describe "Bonfire.Poll.Choices.put_choice/3" do
    test "associates an existing choice with a question and sets position" do
      user = Bonfire.Me.Fake.fake_user!()

      question =
        Bonfire.Poll.Questions.create(
          current_user: user,
          question_attrs: %{post_content: %{html_body: "Test question"}}
        )
        |> elem(1)

      choice_attrs = %{post_content: %{name: "Standalone Option"}}

      cs =
        Bonfire.Social.PostContents.cast(%Bonfire.Poll.Choice{}, choice_attrs, user, "public", [])

      {:ok, choice} = repo().insert(cs)
      {:ok, assoc} = Bonfire.Poll.Choices.put_choice(choice.id, question.id, 5)
      assert assoc.rank_set == 5
      assert assoc.scope_id == question.id
      assert assoc.item_id == choice.id
    end
  end
end
