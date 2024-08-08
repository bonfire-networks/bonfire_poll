defmodule Bonfire.Poll.WeightSelector do
  use Bonfire.UI.Common.Web, :stateless_component

  prop weighting, :integer, default: 3

  def render(assigns) do
    ~F"""
    <div class="flex-1">
      <!--div class="text-sm text-base-content/90">
        {l("Negative Score Weighting")}
      </div-->
      <span class="flex justify-center items-center">
        <select id="select" name="weighting" class="select select-sm select-bordered" value={@weighting}>
          {#for weight <- 1..7}
            {#if weight < 7}
              <option value={weight}>
                {l("Negative Score Weighting")} x{weight}
              </option>
            {#else}
              <option value="0">
                &infin;
              </option>
            {/if}
          {/for}
        </select>
      </span>
    </div>
    <!--weight-selector>
      <div class="collapse collapse-arrow bg-base-200">
        <input type="checkbox">
        <div class="collapse-title font-medium">
          {l("Negative Score Weighting")}
        </div>
        <div class="collapse-content prose">
          {rich(Bonfire.Poll.LiveHandler.negative_score_info())}
        </div>
      </div>
      <span class="flex justify-center items-center">
        <select id="select" name="weighting" class="select mx-2 select-bordered mt-2" value={@weighting}>
          {#for weight <- 1..7}
            {#if weight < 7}
              <option value={weight}>
                x{weight}
              </option>
            {#else}
              <option value="0">
                &infin;
              </option>
            {/if}
          {/for}
        </select>
      </span>
    </weight-selector-->
    """
  end
end

defmodule Bonfire.Poll.PhaseSelector do
  use Bonfire.UI.Common.Web, :stateless_component

  prop selected_phase, :any, default: "full"

  def render(assigns) do
    ~F"""
    <select class="select select-sm select-bordered w-full max-w-full">
      <option value="full" selected={@selected_phase === "full"}>{l("Request options before voting")}</option>
      <option value="voting" selected={@selected_phase === "voting"}>{l("Request votes on predefined options")}</option>
    </select>
    <!-- phase-selector>
      <div class="flex justify-around">
        <div class="flex items-center">
          <input
            id="full-phase"
            type="radio"
            name="phase"
            value="full"
            class="radio radio-primary"
            checked={@selected_phase === "full"}
          />
          <label for="full-phase" class="ml-2 text-sm text-base-content/70 cursor-pointer">{l("Request options before voting")}</label>
        </div>
        <div class="flex items-center">
          <input
            id="voting-phase"
            type="radio"
            name="phase"
            value="voting"
            class="radio radio-primary"
            checked={@selected_phase === "voting"}
          />
          <label for="voting-phase" class="ml-2 text-sm text-base-content/70 cursor-pointer">{l("Request votes on predefined options")}</label>
        </div>
      </div>
    </phase-selector -->
    """
  end
end

defmodule Bonfire.Poll.EditProposalLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop index, :integer, default: 0

  def render(assigns) do
    ~F"""
    <div class="pt-2">
      <div class="flex items-center flex-col">
        <div class="flex items-center gap-2 w-full">
          <button
            phx-click="delete_proposal"
            data-index={@index}
            class="delete btn btn-sm btn-circle btn-outline"
          >
            <span class="sr-only">{l("delete")}</span>
            <#Icon iconify="iwwa:delete" class="w-3 h-3" />
          </button>
          <!-- div class="font-medium text-sm">{l("Proposed choice")}</div -->
          <input
            id={"name-#{@index}"}
            name={"choices[#{@index}][name]"}
            type="text"
            placeholder={l("Proposed choice")}
            class="input input-bordered input-sm w-full"
            value={e(@proposal, :name, nil)}
          />
          <!-- label>{l("Description")}</label -->
          <!-- textarea
            class="textarea textarea-bordered w-full"
            id={"description-#{@index}"}
            name={"choices[#{@index}][description]"}
            data-index={@index}
          >{e(@proposal, :description, nil)}</textarea -->
        </div>
      </div>
      <div class="flex justify-center w-full pt-2 hidden">
        # TODO
      </div>
    </div>
    """
  end
end

defmodule Bonfire.Poll.AddProposal do
  use Bonfire.UI.Common.Web, :stateless_component

  prop event_target, :any, default: "#smart_input"

  # TODO: configurable
  def templates,
    do: [
      %{
        name: l("Status quo"),
        description: l("Keep things the way they are.")
      },
      %{
        name: l("Other choices needed"),
        description: l("Repeat the discussion and proposal process to look for other options.")
      }
    ]

  def render(assigns) do
    ~F"""
    <add-proposal class="flex items-center gap-3 mt-2 flex-wrap">
      <div
        type="botton"
        date-role="add-button"
        class="btn flex-1 w-full btn-outline btn-sm"
        phx-click="Bonfire.Poll:add_proposal"
        phx-target={@event_target}
      >
        <span class="">{l("Add a proposal")}</span>
      </div>
      <div class="dropdown flex dropdown-end dropdown-top">
        <label tabindex="0" class="btn btn-circle btn-sm btn-outline">
          <span class="sr-only">{l("Add a proposal template")}</span>
          <#Icon iconify="ic:outline-poll" class="w-4 h-4" />
        </label>
        <ul
          tabindex="0"
          class="dropdown-content mb-2 w-60 menu p-2 bg-base-100 shadow-sm border border-base-content/20 rounded-xl"
        >
          {#for option <- templates()}
            <li>
              <a
                class="flex gap-0 flex-col"
                phx-click="Bonfire.Poll:add_proposal"
                phx-target={@event_target}
                phx-value-name={option.description}
                phx-value-description={option.description}
              >
                <b class="name text-left w-full">{option.name}</b>
                <p class="description">{rich(option.description)}</p>
              </a>
            </li>
          {/for}
        </ul>
      </div>
    </add-proposal>
    """
  end
end

# defmodule Bonfire.Poll.QuestionInfoLive do
#   use Bonfire.UI.Common.Web, :stateless_component

#   def render(assigns) do
#     ~F"""
#     <div class="flex flex-col pb-3">
#       <h1>{ @name }</h1>
#       <p class="topic-description">{ @description }</p>
#       <div class="flex justify-end items-center">
#         { l("question.weighting") }
#         { @weight }&nbsp;
#         <div id="weightingInfo">
#           <h3>{ l("Negative Score Weighting") }</h3>
#           {rich Bonfire.Poll.LiveHandler.negative_score_info()}
#         </div>
#       </div>
#       <div>
#         {#if @proposal_dates && hd(@proposal_dates) > 0  }
#           <Bonfire.Poll.QuestionTimeLabelLive phase={"proposal"}, dates={@proposal_dates} />
#           <br/>
#         {/if}
#         {#if @voting_dates}
#           <Bonfire.Poll.QuestionTimeLabelLive phase="voting" dates={@voting_dates} />
#           <br/>
#         {/if}
#       </div>
#       {#if @shareable }
#         <div class="w-full pr-2">
#           <p>{ l("question.shareableUrl") }</p>
#           <div class="flex items-center">
#             <input id="shareableUrl" type="text" class="input w-full" readonly value={ @url }/>
#             <button class="btn btn-sm btn-ghost btn-circle share-button">
#               <#Icon iconify="share"/>
#             </button>
#           </div>
#         </div>
#       {/if}
#     </div>
#     """
#   end
# end

defmodule Bonfire.Poll.QuestionTimeLabelLive do
  use Bonfire.UI.Common.Web, :stateless_component

  def phases do
    %{
      "proposal" => l("Proposal Phase"),
      "voting" => l("Voting Phase")
    }
  end

  def render(assigns) do
    ~F"""
    <question-time-label data-start={@start_date}>
      <span>{phases()[@phase]}:&nbsp;</span>

      {#if @current_time < @start_date}
        <br>
        <span>{l("Starts")}:&nbsp;</span>
        <span id="start-date" class="link-success" />
        <br>
        <span>{l("Lasts for")}:&nbsp;</span>
        <div class="badge badge-success">{@dates}</div>
      {#elseif @current_time < List.first(@dates)}
        <div class="badge badge-danger">{@dates}</div>
        <span>&nbsp;({l("remainingTime")})</span>
      {#else}
        <span class="text-info">{l("done")}</span>
      {/if}
      <br>
    </question-time-label>
    """
  end
end

defmodule Bonfire.Poll.VotingCSSLive do
  use Bonfire.UI.Common.Web, :stateless_component

  def render(assigns) do
    ~F"""
    <div class="outline outline-success outline-warning outline-error">
    </div>
    """
  end
end

defmodule Bonfire.Poll.VotingLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop choice, :any, default: nil
  prop selected, :any, default: 0
  prop readonly, :boolean, default: false
  prop scores, :list, default: nil

  def render(assigns) do
    ~F"""
    <!--        <span class='flex justify-end'>
          <span>{ l("Voters") }:&nbsp;</span>
          <span class='no-voters'>{ length(@question.voters || []) }</span>
        </span> -->
    <div class="proposal-list">
      <div
        class="proposal card outline outline-1 shadow-xl py-2 px-4 my-4"
        style={"outline-color: oklch(var(--#{cond do
          is_number(@selected) and @selected > 0 -> "su"
          @selected < 0 -> "wa"
          @selected == "∞" -> "er"
          true -> "n"
        end}));"}
      >
        <div class="flex justify-between">
          {#for {i, name, icon, description} <- @scores || Bonfire.Poll.Votes.scores()}
            <div class={"flex", "text-success": is_number(i) and i > 0, "text-warning": i < 0, "text-error": i == "∞"}>
              <div class="tooltip" data-tip={"#{description} (#{i})"}>
                {#if @readonly}
                  <div class="flex flex-row">
                    <Iconify.iconify class={"h-8 w-8", "opacity-30": i != @selected} icon={icon} />
                    <div class="text-xs">{name}</div>
                  </div>
                {#else}
                  <label class="swap">
                    <!-- this hidden checkbox controls the state -->
                    <input name={"vote[#{id(@choice)}]"} value={i} type="radio" checked={i == @selected}>

                    <div class="flex flex-row swap-on opacity-100">
                      <Iconify.iconify class="h-8 w-8" icon={icon} />
                      <div class="text-xs">{name}</div>
                    </div>

                    <div class="flex flex-row swap-off">
                      <Iconify.iconify class="h-8 w-8 opacity-30" icon={icon} />
                      <div class="text-xs">{name}</div>
                    </div>
                  </label>
                {/if}
              </div>
            </div>
          {/for}
        </div>
      </div>
    </div>
    """
  end
end
