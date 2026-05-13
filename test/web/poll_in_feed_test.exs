defmodule Bonfire.Poll.Web.PollInFeedTest do
  @moduledoc """
  UI test that complements the create-side integration test in
  `polls/questions_test.exs`. Exercises the **render side**:
    - a Question with choices saved in the DB
    - feed-level preload registry (`Bonfire.Social.Feeds.LiveHandler.object_preloads/0`)
      hydrates `:choices` (and their post_content) for objects of type
      `Bonfire.Poll.Question`
    - `Bonfire.Poll.Web.Preview.QuestionLive` renders each choice as a
      `data-id="activity_choice"` row.

  If the preload chain or preview gate (`{#if not is_nil(e(@object, :choices, nil))}`
  in `question_live.sface:86`) regresses, this test catches it.
  """

  use Bonfire.Poll.ConnCase, async: System.get_env("TEST_UI_ASYNC") != "no"
  import PhoenixTest

  alias Bonfire.Me.Fake

  test "a poll with choices appears in the feed with its options rendered" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    question_text = "Should we ship the poll feature?"
    options = ["yes", "no"]

    {:ok, _question} =
      fake_question_with_choices(
        %{post_content: %{html_body: question_text}},
        Enum.map(options, &%{name: &1}),
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/feed")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=feed]", text: question_text)
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "yes")
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "no")
  end

  test "the same poll renders its options at its permalink (discussion view)" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    {:ok, question} =
      fake_question_with_choices(
        %{post_content: %{html_body: "Pick one"}},
        [%{name: "first"}, %{name: "second"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "first")
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "second")
  end

  test "a signed-in viewer sees the Vote action bar on an unvoted poll" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    {:ok, _question} =
      fake_question_with_choices(
        %{post_content: %{html_body: "Vote bar test"}},
        [%{name: "alpha"}, %{name: "beta"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/feed")
    |> wait_async()
    |> assert_has_or_open_browser("[data-role=submit-vote]")
    |> assert_has_or_open_browser("[data-role=vote-count]", text: "0 votes")
  end

  test "after the deadline a poll renders the closed-summary header" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    past = DateTime.utc_now() |> DateTime.add(-7200, :second)
    just_passed = DateTime.utc_now() |> DateTime.add(-60, :second)

    {:ok, question} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Closed poll"},
          voting_format: "single",
          voting_dates: [past, just_passed]
        },
        [%{name: "won"}, %{name: "lost"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    |> assert_has_or_open_browser("[data-role=closed-header]", text: "Closed")
    |> refute_has("[data-role=submit-vote]")
  end

  test "a proposal-phase poll renders the inline Suggest form for signed-in viewers" do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    now = DateTime.utc_now()
    proposal_end = DateTime.add(now, 3600, :second)
    voting_end = DateTime.add(proposal_end, 3600, :second)

    {:ok, question} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Proposal phase poll"},
          voting_format: "weighted_multiple",
          proposal_dates: [now, proposal_end],
          voting_dates: [proposal_end, voting_end]
        },
        [%{name: "seed-1"}, %{name: "seed-2"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    |> assert_has_or_open_browser("[data-role=propose-form]")
    |> assert_has_or_open_browser("[data-role=propose-submit]", text: "Suggest")
    |> refute_has("[data-role=submit-vote]")
  end

  test "weighted poll renders radio groups keyed by loop index, not choice id" do
    # The radio `name` attribute is the radio-group key. If two choices ever
    # share a name, the browser groups them and only one can be selected at
    # a time across the whole poll. We key by `votes[INDEX][weight]` and
    # carry `choice_id` via a hidden field, so this is structurally
    # impossible regardless of how `id(@choice)` resolves.
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)
    conn = conn(user: user, account: account)

    {:ok, question} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Weighted radio names"},
          voting_format: "weighted_multiple",
          weighting: 3
        },
        [%{name: "first"}, %{name: "second"}],
        current_user: user,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    # Each choice carries its weight via a hidden input that Alpine writes
    # to on button click, plus a hidden choice_id field. No HTML radios —
    # using buttons + Alpine state because LV's form lifecycle clobbered
    # the user's selection when the weight was carried by native radios.
    |> assert_has_or_open_browser(~s|input[type=hidden][name='votes[0][weight]']|)
    |> assert_has_or_open_browser(~s|input[type=hidden][name='votes[1][weight]']|)
    |> assert_has_or_open_browser(~s|input[type=hidden][name='votes[0][choice_id]']|)
    |> assert_has_or_open_browser(~s|input[type=hidden][name='votes[1][choice_id]']|)
    # Each face is a button with the role + data-score.
    |> assert_has_or_open_browser(~s|button[role=radio][data-score='-1']|)
    |> assert_has_or_open_browser(~s|button[role=radio][data-score='2']|)
  end

  test "submitting a suggestion adds it to the proposal-phase listing" do
    account = Fake.fake_account!()
    author = Fake.fake_user!(account)
    conn = conn(user: author, account: account)

    now = DateTime.utc_now()
    proposal_end = DateTime.add(now, 3600, :second)
    voting_end = DateTime.add(proposal_end, 3600, :second)

    {:ok, question} =
      fake_question_with_choices(
        %{
          post_content: %{html_body: "Open proposals"},
          voting_format: "weighted_multiple",
          proposal_dates: [now, proposal_end],
          voting_dates: [proposal_end, voting_end]
        },
        [%{name: "existing"}],
        current_user: author,
        boundary: "public"
      )

    conn
    |> visit("/discussion/#{question.id}")
    |> wait_async()
    |> fill_in("Your suggestion", with: "my new idea")
    |> click_button("[data-role=propose-submit]", "Suggest")
    |> wait_async()
    |> assert_has_or_open_browser("[data-id=activity_choice]", text: "my new idea")
  end
end
