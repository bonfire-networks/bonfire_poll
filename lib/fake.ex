defmodule Bonfire.Poll.Fake do
  def fake_question(attrs \\ %{}, opts \\ []) do
    default = %{
      post_content: %{name: Faker.Lorem.sentence()},
      voting_format: "single",
      proposal_dates: [DateTime.utc_now()],
      voting_dates: [DateTime.utc_now() |> DateTime.add(3600, :second)]
    }

    opts =
      Keyword.merge(
        [
          question_attrs: Map.merge(default, attrs),
          current_user: opts[:current_user] || Bonfire.Me.Fake.fake_user!()
        ],
        opts
      )

    Bonfire.Poll.Questions.create(opts)
  end

  def fake_choice(for_question, attrs \\ %{}) do
    Bonfire.Poll.Choices.simple_create_and_put(
      nil,
      Map.merge(fake_choice_attrs(), attrs),
      for_question,
      []
    )
  end

  def fake_choice_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        name: Faker.Lorem.word(),
        summary: Faker.Lorem.sentence(),
        html_body: Faker.Lorem.paragraph()
      },
      attrs
    )
  end

  def fake_question_with_choices(question_attrs \\ %{}, choices_attrs_list \\ nil, opts \\ []) do
    question_attrs =
      Map.merge(question_attrs, %{
        choices: choices_attrs_list || [fake_choice_attrs(), fake_choice_attrs()]
      })

    fake_question(question_attrs, opts)
  end
end
